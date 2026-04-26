defmodule SootDeviceProtocol.Contract.Refresh do
  @moduledoc """
  Periodically polls `/.well-known/soot/contract`, verifies the manifest
  against the trust chain, and notifies a callback on every change.

  ## Lifecycle

    * On `start_link/1` the GenServer reads any cached bundle from
      storage and immediately schedules a refresh.
    * Every `:interval_ms` (default 5 min) it fetches the manifest. If
      the manifest's fingerprint matches the cached fingerprint, no
      assets are pulled.
    * On a fingerprint change the process pulls every asset listed in
      `manifest.assets`, verifies the assembled bundle against the
      configured trust PEMs, persists it, and invokes `:on_change`.

  Verification failures (signature mismatch, asset hash mismatch,
  network errors) keep the cached bundle in place; the next refresh
  retries.

  ## Options

    * `:url` — base URL of the manifest endpoint (no trailing slash);
      e.g. `"https://soot.example.com/.well-known/soot/contract"`.
    * `:storage` — `t:SootDeviceProtocol.Storage.binding/0` for cache.
    * `:trust_pems` — list of PEMs that any of which must verify the
      bundle's signature.
    * `:on_change` — `(SootDeviceProtocol.Contract.Bundle.t() -> any())`
      callback, invoked synchronously on the GenServer process.
    * `:interval_ms` — refresh cadence (default `300_000`, 5 min).
    * `:cert_pem` / `:key_pem` — operational mTLS material.
    * `:http_client` / `:http_opts` — pluggable HTTP adapter.

  ## Programmatic refresh

  `force_refresh/1` is the hook the telemetry pipeline calls when it
  receives a 409 fingerprint-mismatch from the ingest endpoint: it
  forces a fetch on the next loop iteration.
  """

  use GenServer
  require Logger

  alias SootDeviceProtocol.{HTTPClient, Storage}
  alias SootDeviceProtocol.Contract.Bundle

  @default_interval_ms 300_000

  defmodule State do
    @moduledoc false
    defstruct [
      :url,
      :storage,
      :trust_pems,
      :on_change,
      :interval_ms,
      :cert_pem,
      :key_pem,
      :http_client,
      :http_opts,
      :timer,
      :current_fingerprint,
      :current_bundle
    ]
  end

  # ─── client API ──────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Fetch + verify on the next event-loop iteration. Returns when the
  refresh has completed.
  """
  @spec refresh(GenServer.server()) :: {:ok, :unchanged | :updated} | {:error, term()}
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh, 30_000)

  @doc "Schedule a refresh asynchronously (used from contention-prone callers)."
  @spec force_refresh(GenServer.server()) :: :ok
  def force_refresh(server \\ __MODULE__), do: GenServer.cast(server, :refresh)

  @doc "Read the current cached bundle, if any."
  @spec current(GenServer.server()) :: {:ok, Bundle.t()} | :error
  def current(server \\ __MODULE__), do: GenServer.call(server, :current)

  # ─── GenServer ──────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    storage = Keyword.fetch!(opts, :storage)
    url = Keyword.fetch!(opts, :url)

    {fingerprint, bundle} = load_cached(storage)

    state = %State{
      url: url,
      storage: storage,
      trust_pems: Keyword.get(opts, :trust_pems, []),
      on_change: Keyword.get(opts, :on_change),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      cert_pem: Keyword.get(opts, :cert_pem),
      key_pem: Keyword.get(opts, :key_pem),
      http_client: Keyword.get(opts, :http_client, HTTPClient.HTTPC),
      http_opts: Keyword.get(opts, :http_opts, []),
      current_fingerprint: fingerprint,
      current_bundle: bundle
    }

    if Keyword.get(opts, :auto_refresh, true) do
      send(self(), :refresh_tick)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    {result, state} = do_refresh(state)
    state = reschedule(state)
    {:reply, result, state}
  end

  def handle_call(:current, _from, %State{current_bundle: nil} = state) do
    {:reply, :error, state}
  end

  def handle_call(:current, _from, %State{current_bundle: bundle} = state) do
    {:reply, {:ok, bundle}, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    {_result, state} = do_refresh(state)
    {:noreply, reschedule(state)}
  end

  @impl true
  def handle_info(:refresh_tick, state) do
    {_result, state} = do_refresh(state)
    {:noreply, reschedule(state)}
  end

  # ─── refresh flow ───────────────────────────────────────────────────

  defp do_refresh(%State{} = state) do
    case fetch_manifest(state) do
      {:ok, manifest_json} ->
        case Bundle.parse_manifest(manifest_json) do
          {:ok, %Bundle{fingerprint: fp}} when fp == state.current_fingerprint ->
            {{:ok, :unchanged}, state}

          {:ok, %Bundle{} = bundle} ->
            apply_bundle(state, bundle)

          {:error, _} = err ->
            log_failure(:parse, err)
            {err, state}
        end

      {:error, _} = err ->
        log_failure(:manifest_fetch, err)
        {err, state}
    end
  end

  defp apply_bundle(state, %Bundle{} = bundle) do
    case fetch_assets(state, bundle) do
      {:ok, bundle} ->
        case Bundle.verify(bundle, state.trust_pems) do
          :ok ->
            persist(state.storage, bundle)
            invoke_on_change(state.on_change, bundle)

            {{:ok, :updated},
             %{state | current_fingerprint: bundle.fingerprint, current_bundle: bundle}}

          {:error, _} = err ->
            log_failure(:verify, err)
            {err, state}
        end

      {:error, _} = err ->
        log_failure(:asset_fetch, err)
        {err, state}
    end
  end

  defp fetch_manifest(state) do
    case http_get(state, state.url) do
      {:ok, {200, _headers, body}} -> {:ok, body}
      {:ok, {status, _, _}} -> {:error, {:manifest_http_error, status}}
      {:error, _} = err -> err
    end
  end

  defp fetch_assets(state, %Bundle{manifest: manifest, fingerprint: fp} = bundle) do
    asset_paths = manifest |> Map.fetch!("assets") |> Map.keys()

    Enum.reduce_while(asset_paths, {:ok, bundle}, fn path, {:ok, acc} ->
      url = state.url <> "/" <> fp <> "/" <> path

      case http_get(state, url) do
        {:ok, {200, _headers, body}} ->
          {:cont, {:ok, Bundle.attach_asset(acc, path, body)}}

        {:ok, {status, _headers, _body}} ->
          {:halt, {:error, {:asset_http_error, path, status}}}

        {:error, reason} ->
          {:halt, {:error, {:asset_fetch_error, path, reason}}}
      end
    end)
  end

  defp http_get(state, url) do
    opts =
      Keyword.merge(state.http_opts,
        cert_pem: state.cert_pem,
        key_pem: state.key_pem,
        trust_pems: state.trust_pems,
        client: state.http_client
      )

    HTTPClient.request(:get, url, [{"accept", "application/json"}], <<>>, opts)
  end

  defp persist(storage, %Bundle{} = bundle) do
    Storage.put(storage, :contract_fingerprint, bundle.fingerprint)
    Storage.put(storage, :contract_bundle, bundle)
    :ok
  end

  defp load_cached(storage) do
    fp =
      case Storage.get(storage, :contract_fingerprint) do
        {:ok, value} -> value
        :error -> nil
      end

    bundle =
      case Storage.get(storage, :contract_bundle) do
        {:ok, %Bundle{} = b} -> b
        _ -> nil
      end

    {fp, bundle}
  end

  defp invoke_on_change(nil, _bundle), do: :ok

  defp invoke_on_change(fun, bundle) when is_function(fun, 1) do
    try do
      fun.(bundle)
    rescue
      error ->
        Logger.error("soot_device_protocol on_change callback raised: #{inspect(error)}")
        :ok
    end
  end

  defp reschedule(%State{interval_ms: ms} = state) do
    cancel_timer(state.timer)
    timer = Process.send_after(self(), :refresh_tick, ms)
    %{state | timer: timer}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref) when is_reference(ref), do: Process.cancel_timer(ref)

  defp log_failure(stage, {:error, reason}) do
    Logger.warning("soot_device_protocol contract refresh failed at #{stage}: #{inspect(reason)}")
    :ok
  end
end
