defmodule SootDeviceProtocol.Telemetry.Buffer do
  @moduledoc """
  Behavior for the local row buffer that backs the telemetry pipeline.

  Two implementations ship in-tree:

    * `SootDeviceProtocol.Telemetry.Buffer.Memory` — ETS-backed; the
      default for tests and host-VM development.
    * `SootDeviceProtocol.Telemetry.Buffer.Dux` (deferred) — DuckDB
      via Dux when the operator opts in. Requires the optional `:dux`
      dep on the target.

  Buffers store rows tagged by stream name and a monotonic sequence
  number per stream. Sequence numbers are generated *outside* the
  buffer (the pipeline owns them) so the buffer doesn't need to know
  about persistence — sequences live in
  `SootDeviceProtocol.Storage`.
  """

  @type handle :: term()
  @type stream :: atom() | String.t()
  @type sequence :: non_neg_integer()
  @type row :: term()
  @type entry :: %{seq: sequence(), row: row(), bytes: non_neg_integer(), inserted_at: integer()}

  @doc "Append `row` to `stream`'s queue under `seq`."
  @callback append(handle(), stream(), sequence(), row(), bytes :: non_neg_integer()) ::
              :ok | {:error, term()}

  @doc "Return the next batch (oldest first) up to `max_rows` entries for `stream`."
  @callback take(handle(), stream(), max_rows :: pos_integer()) :: [entry()]

  @doc "Drop everything in `stream` whose sequence is `<= up_to_seq`."
  @callback drop(handle(), stream(), up_to_seq :: sequence()) :: :ok

  @doc "Snapshot of pipeline-wide row / byte / oldest-row stats."
  @callback stats(handle()) :: %{
              required(:rows) => non_neg_integer(),
              required(:bytes) => non_neg_integer(),
              required(:streams) => %{required(stream()) => map()}
            }

  @doc """
  Drop the oldest entries across every stream until either `target_rows`
  or `target_bytes` is below the configured budget. Returns the number
  of rows dropped.
  """
  @callback prune(handle(), max_rows :: non_neg_integer(), max_bytes :: non_neg_integer()) ::
              non_neg_integer()
end
