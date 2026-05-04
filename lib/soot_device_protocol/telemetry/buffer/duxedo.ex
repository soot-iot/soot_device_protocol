if Code.ensure_loaded?(Duxedo.Streams) do
  defmodule SootDeviceProtocol.Telemetry.Buffer.Duxedo do
    @moduledoc """
    `Duxedo`-backed buffer adapter for the telemetry pipeline.

    Each soot telemetry stream becomes a typed `Duxedo.Streams` table.
    Writes are bulk-inserts; uploads pull Arrow IPC straight back out of
    DuckDB without the rows being materialized to Elixir terms.

    This is the production buffer when the operator opts in to
    `:duxedo`. The default `Buffer.Memory` is fine for host-VM tests
    and for devices that can't afford the DuckDB NIF, but it can't
    produce Arrow IPC natively, so production deployments that talk to
    `SootTelemetry.Plug.Ingest` use this adapter.

    ## Per-stream schema

    Each stream's column shape is declared up-front with `define/3` —
    typically called from `Pipeline.configure_stream/3` when the
    contract bundle hands the device its `streams/<name>.arrow_schema`.
    Re-defining a stream with the same shape is a no-op; with a
    different shape it raises.

    ## Optional callbacks

    In addition to the `SootDeviceProtocol.Telemetry.Buffer` behavior,
    this module exposes:

      * `define/3` — declare a stream's typed schema.
      * `snapshot_for_upload/3` — pull the next batch as Arrow IPC + the
        sequence range, in a single pass without materializing rows. The
        pipeline uses this to skip the row-by-row encoder when the
        buffer is Duxedo-backed.
    """

    @behaviour SootDeviceProtocol.Telemetry.Buffer

    alias Duxedo.Streams

    defstruct [:instance]

    @type t :: %__MODULE__{instance: atom()}

    @spec open(keyword()) :: {:ok, t()}
    def open(opts \\ []) do
      {:ok, %__MODULE__{instance: Keyword.get(opts, :instance, :duxedo)}}
    end

    @spec open!(keyword()) :: t()
    def open!(opts \\ []) do
      {:ok, handle} = open(opts)
      handle
    end

    @doc """
    Declare a stream's column schema. Called from
    `Pipeline.configure_stream/3` when the contract bundle hands over a
    schema.
    """
    @impl true
    def define(%__MODULE__{instance: instance} = handle, stream, columns) do
      # define/3 is the only entry point that creates a stream atom.
      # Once defined, the atom is in the table and the runtime
      # callbacks below resolve via String.to_existing_atom/1.
      case Streams.define(define_atom(stream), columns, instance: instance) do
        :ok ->
          __register_stream__(handle, stream)
          :ok

        err ->
          err
      end
    end

    # ─── Buffer callbacks ───────────────────────────────────────────────

    @impl true
    def append(%__MODULE__{instance: instance}, stream, seq, row, _bytes) when is_map(row) do
      row = Map.put(row, :seq, seq)
      Streams.append(to_atom(stream), row, instance: instance)
    end

    @impl true
    def take(%__MODULE__{instance: instance}, stream, max_rows) do
      case Streams.take_oldest(to_atom(stream), max_rows, instance: instance) do
        {:ok, rows} ->
          Enum.map(rows, fn row ->
            %{
              seq: Map.fetch!(row, :seq),
              row: Map.delete(row, :seq),
              bytes: approx_size(row),
              inserted_at: 0
            }
          end)

        :error ->
          []
      end
    end

    @impl true
    def drop(%__MODULE__{instance: instance}, stream, up_to_seq) do
      case Streams.drop_through(to_atom(stream), up_to_seq, instance: instance) do
        :ok -> :ok
        :error -> :ok
      end
    end

    @impl true
    def stats(%__MODULE__{instance: instance} = handle) do
      streams = known_streams(handle)

      {rows, per_stream} =
        Enum.reduce(streams, {0, %{}}, fn name, {total, acc} ->
          case Streams.stats(name, instance: instance) do
            {:ok, %{rows: r, min_seq: min_seq, max_seq: max_seq}} ->
              {total + r,
               Map.put(acc, name, %{
                 rows: r,
                 bytes: 0,
                 min_seq: min_seq,
                 max_seq: max_seq
               })}

            :error ->
              {total, acc}
          end
        end)

      %{rows: rows, bytes: 0, streams: per_stream}
    end

    @impl true
    def prune(%__MODULE__{}, _max_rows, _max_bytes) do
      # Duxedo prunes per-stream on append using its own retention
      # budget; nothing to do at the cross-stream level.
      0
    end

    # ─── extension ──────────────────────────────────────────────────────

    @doc """
    Pull the next `max_rows` oldest entries as Arrow IPC bytes plus the
    sequence range. Returns `{:ok, snapshot}` or `:empty`.

    Used by `Telemetry.Pipeline` to bypass the row-by-row encoder when
    the buffer can produce a server-shaped batch natively.
    """
    @impl true
    def snapshot_for_upload(%__MODULE__{instance: instance}, stream, max_rows) do
      case Streams.to_arrow_ipc(to_atom(stream), instance: instance, max_rows: max_rows) do
        {:ok, %{ipc: ipc, min_seq: min_seq, max_seq: max_seq, rows: rows}} ->
          {:ok,
           %{
             body: ipc,
             content_type: "application/vnd.apache.arrow.stream",
             min_seq: min_seq,
             max_seq: max_seq,
             rows: rows
           }}

        {:error, :empty} ->
          :empty
      end
    end

    # ─── helpers ────────────────────────────────────────────────────────

    # Runtime path: streams must already be defined, so the atom is
    # in the table. String.to_existing_atom/1 raises on a typo, which
    # is what we want — silent atom growth from bundle data is the
    # bigger risk.
    defp to_atom(name) when is_atom(name), do: name
    defp to_atom(name) when is_binary(name), do: String.to_existing_atom(name)

    # define/3 path: this is the one place we accept a never-seen
    # stream name and pull it into the atom table. Bounded by the
    # operator's contract bundle (and validated upstream).
    defp define_atom(name) when is_atom(name), do: name
    defp define_atom(name) when is_binary(name), do: String.to_atom(name)

    defp approx_size(row) do
      row
      |> :erlang.term_to_binary()
      |> byte_size()
    end

    # Each register call also tracks the stream name in :persistent_term
    # under our own key so `stats/1` can iterate every defined stream.
    defp known_streams(%__MODULE__{instance: instance}) do
      case :persistent_term.get({__MODULE__, instance, :streams}, MapSet.new()) do
        %MapSet{} = set -> MapSet.to_list(set)
        _ -> []
      end
    end

    @doc false
    def __register_stream__(%__MODULE__{instance: instance}, stream) do
      name = to_atom(stream)
      set = :persistent_term.get({__MODULE__, instance, :streams}, MapSet.new())
      :persistent_term.put({__MODULE__, instance, :streams}, MapSet.put(set, name))
      :ok
    end
  end
end
