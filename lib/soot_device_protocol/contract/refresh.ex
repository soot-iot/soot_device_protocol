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

  alias SootDeviceProtocol.{Backoff, Events, HTTPClient, Storage}
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
      :current_bundle,
      :failure_backoff,
      :jitter_fraction
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
      current_bundle: bundle,
      jitter_fraction: Keyword.get(opts, :jitter_fraction, 0.2),
      failure_backoff:
        Backoff.new(
          initial: Keyword.get(opts, :initial_backoff_ms, 1_000),
          max: Keyword.get(opts, :max_backoff_ms, Keyword.get(opts, :interval_ms, @default_interval_ms))
        )
    }

    if Keyword.get(opts, :auto_refresh, true) do
      send(self(), :refresh_tick)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    {result, state} = do_refresh(state)
    state = reschedule(state, result)
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
    {result, state} = do_refresh(state)
    {:noreply, reschedule(state, result)}
  end

  @impl true
  def handle_info(:refresh_tick, state) do
    {result, state} = do_refresh(state)
    {:noreply, reschedule(state, result)}
  end

  # ─── refresh flow ───────────────────────────────────────────────────

  defp do_refresh(%State{} = state) do
    outcome =
      Events.span([:soot_device, :contract, :refresh], %{url: state.url}, fn ->
        attempt_refresh(state)
      end)

    apply_outcome(outcome, state)
  end

  defp attempt_refresh(%State{} = state) do
    with {:ok, manifest_json} <- fetch_manifest(state),
         {:ok, %Bundle{} = bundle} <- Bundle.parse_manifest(manifest_json) do
      if bundle.fingerprint == state.current_fingerprint do
        {:ok, :unchanged}
      else
        attempt_apply_bundle(state, bundle)
      end
    else
      {:error, _} = err ->
        log_failure(:fetch_or_parse, err)
        err
    end
  end

  defp attempt_apply_bundle(state, %Bundle{} = bundle) do
    case fetch_assets(state, bundle) do
      {:ok, bundle} ->
        case Bundle.verify(bundle, state.trust_pems) do
          :ok -> {:ok, :updated, bundle}
          {:error, _} = err ->
            log_failure(:verify, err)
            err
        end

      {:error, _} = err ->
        log_failure(:asset_fetch, err)
        err
    end
  end

  defp apply_outcome({:ok, :unchanged}, state) do
    {{:ok, :unchanged}, %{state | failure_backoff: Backoff.reset(state.failure_backoff)}}
  end

  defp apply_outcome({:ok, :updated, %Bundle{} = bundle}, state) do
    persist(state.storage, bundle)
    invoke_on_change(state.on_change, bundle)

    {{:ok, :updated},
     %{
       state
       | current_fingerprint: bundle.fingerprint,
         current_bundle: bundle,
         failure_backoff: Backoff.reset(state.failure_backoff)
     }}
  end

  defp apply_outcome({:error, _} = err, state), do: {err, state}

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
    fun.(bundle)
  rescue
    error ->
      Logger.error("soot_device_protocol on_change callback raised: #{inspect(error)}")
      :ok
  end

  defp reschedule(%State{} = state, result) do
    cancel_timer(state.timer)

    {delay, state} =
      case result do
        {:error, _} ->
          {ms, backoff} = Backoff.next(state.failure_backoff)
          {ms, %{state | failure_backoff: backoff}}

        _ ->
          {jittered(state.interval_ms, state.jitter_fraction), state}
      end

    timer = Process.send_after(self(), :refresh_tick, delay)
    %{state | timer: timer}
  end

  # Add full-jitter ±fraction to the configured interval. e.g. with
  # jitter_fraction = 0.2, the next tick is in [interval * 0.8, interval * 1.2).
  defp jittered(interval_ms, fraction) when fraction >= 0 and fraction < 1 do
    spread = trunc(interval_ms * fraction)
    floor_ms = interval_ms - spread
    rand_extra = if spread == 0, do: 0, else: :rand.uniform(spread * 2 + 1) - 1
    max(0, floor_ms + rand_extra)
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref) when is_reference(ref), do: Process.cancel_timer(ref)

  defp log_failure(stage, {:error, reason}) do
    Logger.warning("soot_device_protocol contract refresh failed at #{stage}: #{inspect(reason)}")
    :ok
  end
end
