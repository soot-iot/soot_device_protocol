defmodule SootDeviceProtocol.Telemetry.Pipeline do
  @moduledoc """
  Local-first telemetry pipeline.

  Devices write rows here through `write/3`; the pipeline persists
  them in a local buffer (default ETS, swappable to Dux/DuckDB) and a
  background flush loop uploads them to the backend's
  `POST /ingest/<stream>` endpoint.

  The pipeline owns the **monotonic per-stream sequence number** and
  persists it across reboots through the storage abstraction. Every
  appended row gets the next sequence; uploads include
  `x-sequence-start` / `x-sequence-end` so the backend can reject
  regressions.

  ## Lifecycle

    * `init/1` — load the persisted sequence high-water for every
      stream the operator pre-registered, then schedule the first
      flush tick.

    * `write/3` — append one row to the buffer; if the buffer crosses
      the configured `:retention_rows` / `:retention_bytes` budget,
      drop the oldest entries.

    * `flush/1` — synchronously walk every registered stream, encode
      a batch, POST it. On HTTP success drop those rows. On 409
      (`fingerprint_mismatch`) or 410 (`stream_unavailable`) drop the
      rows AND invoke `:on_contract_refresh`. On any other failure,
      keep the rows and back off.

  ## Stream registration

  Each stream is registered with:

      configure_stream(pipeline, "vibration", %{
        fingerprint: "<sha256>",
        ingest_endpoint: "/ingest/vibration",
        descriptor: %{...}
      })

  Streams that aren't registered when `write/3` is called are rejected
  with `{:error, :unknown_stream}` to keep us from buffering rows we
  can't ever upload.

  ## Backoff

  Failed uploads enter capped exponential backoff per stream
  (`:initial_backoff_ms` doubling up to `:max_backoff_ms`). A
  `flush/1` call resets the backoff so an operator can force a retry.
  """

  use GenServer
  require Logger

  alias SootDeviceProtocol.{Events, HTTPClient, Storage}
  alias SootDeviceProtocol.Telemetry.{Buffer, Encoder}

  @default_retention_rows 1_000_000
  @default_retention_bytes 64 * 1024 * 1024
  @default_flush_interval_ms 5_000
  @default_initial_backoff_ms 1_000
  @default_max_backoff_ms 5 * 60_000
  @default_max_batch_rows 1_000

  defmodule Stream do
    @moduledoc false
    defstruct [
      :name,
      :fingerprint,
      :ingest_endpoint,
      :descriptor,
      sequence: 0,
      backoff_ms: nil,
      retry_after: nil
    ]
  end

  defmodule State do
    @moduledoc false
    defstruct [
      :buffer_mod,
      :buffer,
      :encoder,
      :base_url,
      :storage,
      :http_client,
      :http_opts,
      :cert_pem,
      :key_pem,
      :trust_pems,
      :retention_rows,
      :retention_bytes,
      :flush_interval_ms,
      :initial_backoff_ms,
      :max_backoff_ms,
      :max_batch_rows,
      :on_contract_refresh,
      :flush_timer,
      streams: %{}
    ]
  end

  # ─── client API ──────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register or replace a stream's metadata at runtime. Returns the
  current sequence high-water for the stream.
  """
  @spec configure_stream(GenServer.server(), atom() | String.t(), map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def configure_stream(server \\ __MODULE__, name, config) do
    GenServer.call(server, {:configure_stream, name, config})
  end

  @doc "Append a row for `stream`. Returns the assigned sequence number."
  @spec write(GenServer.server(), atom() | String.t(), map(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def write(server \\ __MODULE__, stream, row, opts \\ []) when is_map(row) do
    GenServer.call(server, {:write, stream, row, opts})
  end

  @doc "Force a flush attempt across every registered stream."
  @spec flush(GenServer.server()) :: %{required(atom() | String.t()) => term()}
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush, 30_000)

  @doc "Buffer + per-stream stats."
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  # ─── GenServer ──────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    storage = Keyword.fetch!(opts, :storage)

    {buffer_mod, buffer} = init_buffer(opts)

    state = %State{
      buffer_mod: buffer_mod,
      buffer: buffer,
      encoder: Keyword.get(opts, :encoder, Encoder.JSONLines),
      base_url: Keyword.fetch!(opts, :base_url),
      storage: storage,
      http_client: Keyword.get(opts, :http_client, HTTPClient.HTTPC),
      http_opts: Keyword.get(opts, :http_opts, []),
      cert_pem: Keyword.get(opts, :cert_pem),
      key_pem: Keyword.get(opts, :key_pem),
      trust_pems: Keyword.get(opts, :trust_pems, []),
      retention_rows: Keyword.get(opts, :retention_rows, @default_retention_rows),
      retention_bytes: Keyword.get(opts, :retention_bytes, @default_retention_bytes),
      flush_interval_ms: Keyword.get(opts, :flush_interval_ms, @default_flush_interval_ms),
      initial_backoff_ms: Keyword.get(opts, :initial_backoff_ms, @default_initial_backoff_ms),
      max_backoff_ms: Keyword.get(opts, :max_backoff_ms, @default_max_backoff_ms),
      max_batch_rows: Keyword.get(opts, :max_batch_rows, @default_max_batch_rows),
      on_contract_refresh: Keyword.get(opts, :on_contract_refresh)
    }

    streams =
      opts
      |> Keyword.get(:streams, [])
      |> Enum.reduce(%{}, fn {name, config}, acc ->
        Map.put(acc, normalize_stream(name), build_stream(state.storage, name, config))
      end)

    state = %{state | streams: streams}

    state =
      if Keyword.get(opts, :auto_flush?, true) do
        schedule_flush(state)
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:configure_stream, name, config}, _from, state) do
    name = normalize_stream(name)
    stream = build_stream(state.storage, name, config)
    streams = Map.put(state.streams, name, stream)
    {:reply, {:ok, stream.sequence}, %{state | streams: streams}}
  end

  def handle_call({:write, name, row, _opts}, _from, state) do
    name = normalize_stream(name)

    case Map.get(state.streams, name) do
      nil ->
        {:reply, {:error, :unknown_stream}, state}

      %Stream{} = stream ->
        seq = stream.sequence + 1
        bytes = approx_size(row)

        :ok = state.buffer_mod.append(state.buffer, name, seq, row, bytes)

        _dropped =
          state.buffer_mod.prune(state.buffer, state.retention_rows, state.retention_bytes)

        stream = %{stream | sequence: seq}
        :ok = persist_sequence(state.storage, name, seq)

        Events.emit(
          [:soot_device, :pipeline, :write],
          %{bytes: bytes},
          %{stream: name, seq: seq}
        )

        {:reply, {:ok, seq}, %{state | streams: Map.put(state.streams, name, stream)}}
    end
  end

  def handle_call(:flush, _from, state) do
    {results, state} = do_flush_all(state)
    {:reply, results, schedule_flush(state)}
  end

  def handle_call(:stats, _from, state) do
    {:reply, state.buffer_mod.stats(state.buffer), state}
  end

  @impl true
  def handle_info(:flush_tick, state) do
    {_results, state} = do_flush_all(state)
    {:noreply, schedule_flush(state)}
  end

  # ─── flush flow ─────────────────────────────────────────────────────

  defp do_flush_all(%State{streams: streams} = state) do
    now = System.monotonic_time(:millisecond)

    Enum.reduce(streams, {%{}, state}, fn {name, stream}, {results, st} ->
      {result, st} = flush_stream(st, name, stream, now)
      {Map.put(results, name, result), st}
    end)
  end

  defp flush_stream(state, name, %Stream{retry_after: ra} = stream, now)
       when is_integer(ra) and ra > now do
    {:backoff, %{state | streams: Map.put(state.streams, name, stream)}}
  end

  defp flush_stream(state, name, %Stream{} = stream, _now) do
    case state.buffer_mod.take(state.buffer, name, state.max_batch_rows) do
      [] ->
        {:empty, state}

      entries ->
        rows = Enum.map(entries, & &1.row)
        seq_start = entries |> List.first() |> Map.fetch!(:seq)
        seq_end = entries |> List.last() |> Map.fetch!(:seq)

        Events.span(
          [:soot_device, :pipeline, :flush],
          %{stream: name, rows: length(entries)},
          fn -> do_flush_stream(state, name, stream, entries, rows, seq_start, seq_end) end
        )
    end
  end

  defp do_flush_stream(state, name, stream, entries, rows, seq_start, seq_end) do
    _ = rows

    case encode_and_post(state, stream, rows, seq_start, seq_end) do
      :ok ->
        :ok = state.buffer_mod.drop(state.buffer, name, seq_end)
        stream = %{stream | backoff_ms: nil, retry_after: nil}
        {{:ok, length(entries), seq_end}, %{state | streams: Map.put(state.streams, name, stream)}}

      {:drop_and_refresh, reason} ->
        :ok = state.buffer_mod.drop(state.buffer, name, seq_end)
        invoke_refresh(state)
        stream = %{stream | backoff_ms: nil, retry_after: nil}
        {{:dropped, reason}, %{state | streams: Map.put(state.streams, name, stream)}}

      {:keep_with_backoff, reason} ->
        stream = bump_backoff(stream, state)
        {{:retry, reason}, %{state | streams: Map.put(state.streams, name, stream)}}
    end
  end

  defp encode_and_post(state, %Stream{} = stream, rows, seq_start, seq_end) do
    case state.encoder.encode(stream.descriptor || %{}, rows) do
      {:ok, %{body: body, content_type: content_type}} ->
        post_batch(state, stream, body, content_type, seq_start, seq_end)

      {:error, reason} ->
        {:keep_with_backoff, {:encoder_error, reason}}
    end
  end

  defp post_batch(state, %Stream{} = stream, body, content_type, seq_start, seq_end) do
    url = state.base_url <> stream.ingest_endpoint

    headers = [
      {"x-stream", to_string(stream.name)},
      {"x-schema-fingerprint", stream.fingerprint},
      {"x-sequence-start", Integer.to_string(seq_start)},
      {"x-sequence-end", Integer.to_string(seq_end)},
      {"content-type", content_type}
    ]

    opts =
      Keyword.merge(state.http_opts,
        cert_pem: state.cert_pem,
        key_pem: state.key_pem,
        trust_pems: state.trust_pems,
        client: state.http_client
      )

    case HTTPClient.request(:post, url, headers, body, opts) do
      {:ok, {status, _headers, _body}} when status in 200..204 ->
        :ok

      {:ok, {409, _headers, _body}} ->
        {:drop_and_refresh, :fingerprint_mismatch}

      {:ok, {410, _headers, _body}} ->
        {:drop_and_refresh, :stream_retired}

      {:ok, {status, _headers, body}} ->
        {:keep_with_backoff, {:http_error, status, decode_error_body(body)}}

      {:error, reason} ->
        {:keep_with_backoff, {:transport_error, reason}}
    end
  end

  defp decode_error_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  defp invoke_refresh(%State{on_contract_refresh: nil}), do: :ok

  defp invoke_refresh(%State{on_contract_refresh: fun}) when is_function(fun, 0) do
    try do
      fun.()
    rescue
      e -> Logger.warning("on_contract_refresh raised: #{inspect(e)}")
    end

    :ok
  end

  defp bump_backoff(%Stream{backoff_ms: nil} = stream, state) do
    base = state.initial_backoff_ms
    apply_backoff(stream, base, base)
  end

  defp bump_backoff(%Stream{backoff_ms: ms} = stream, state) do
    base = min(ms * 2, state.max_backoff_ms)
    apply_backoff(stream, base, base)
  end

  # Full-jitter exponential: uniformly random in `[0, base]` so a
  # synchronized fleet doesn't retry in lockstep.
  defp apply_backoff(stream, base, ceiling) when is_integer(base) and base >= 0 do
    delay = if base == 0, do: 0, else: :rand.uniform(base + 1) - 1

    %{
      stream
      | backoff_ms: ceiling,
        retry_after: System.monotonic_time(:millisecond) + delay
    }
  end

  # ─── helpers ────────────────────────────────────────────────────────

  defp init_buffer(opts) do
    case Keyword.get(opts, :buffer) do
      nil ->
        {Buffer.Memory, Buffer.Memory.open!()}

      {mod, handle} ->
        {mod, handle}
    end
  end

  defp build_stream(storage, name, config) do
    name = normalize_stream(name)
    persisted = load_sequence(storage, name)

    %Stream{
      name: name,
      fingerprint: Map.fetch!(config, :fingerprint),
      ingest_endpoint: Map.get(config, :ingest_endpoint, "/ingest/#{name}"),
      descriptor: Map.get(config, :descriptor, %{}),
      sequence: max(persisted, Map.get(config, :sequence, 0))
    }
  end

  defp persist_sequence(storage, name, seq) do
    Storage.put(storage, sequence_key(name), seq)
  end

  defp load_sequence(storage, name) do
    case Storage.get(storage, sequence_key(name)) do
      {:ok, seq} when is_integer(seq) -> seq
      _ -> 0
    end
  end

  defp sequence_key(name), do: {:telemetry_sequence, normalize_stream(name)}

  defp normalize_stream(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_stream(name) when is_binary(name), do: name

  defp approx_size(row) when is_map(row) do
    row
    |> :erlang.term_to_binary()
    |> byte_size()
  end

  defp schedule_flush(%State{flush_interval_ms: ms} = state) do
    cancel_timer(state.flush_timer)
    timer = Process.send_after(self(), :flush_tick, ms)
    %{state | flush_timer: timer}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref) when is_reference(ref), do: Process.cancel_timer(ref)
end
