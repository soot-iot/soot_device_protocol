defmodule SootDeviceProtocol.Telemetry.Buffer.Memory do
  @moduledoc """
  ETS-backed implementation of `SootDeviceProtocol.Telemetry.Buffer`.

  An ordered_set table keyed by `{stream, seq}` so `:ets.first/1` /
  `:ets.next/2` walks every stream's queue in sequence order. Rows are
  stored verbatim so the encoder layer is free to project them into
  whatever shape it needs (JSON lines, Arrow IPC, etc.).
  """

  @behaviour SootDeviceProtocol.Telemetry.Buffer

  defstruct [:table]

  @type t :: %__MODULE__{table: :ets.tid()}

  @spec open() :: {:ok, t()}
  def open do
    table =
      :ets.new(:soot_telemetry_buffer, [
        :ordered_set,
        :public,
        write_concurrency: true,
        read_concurrency: true
      ])

    {:ok, %__MODULE__{table: table}}
  end

  @spec open!() :: t()
  def open! do
    {:ok, t} = open()
    t
  end

  @impl true
  def append(%__MODULE__{table: table}, stream, seq, row, bytes) do
    inserted_at = System.monotonic_time(:millisecond)
    true = :ets.insert(table, {{stream, seq}, row, bytes, inserted_at})
    :ok
  end

  @impl true
  def take(%__MODULE__{table: table}, stream, max_rows) do
    table
    |> :ets.select([
      {{{stream, :"$1"}, :"$2", :"$3", :"$4"}, [],
       [%{seq: :"$1", row: :"$2", bytes: :"$3", inserted_at: :"$4"}]}
    ])
    |> Enum.sort_by(& &1.seq)
    |> Enum.take(max_rows)
  end

  @impl true
  def drop(%__MODULE__{table: table}, stream, up_to_seq) do
    :ets.select_delete(table, [
      {{{stream, :"$1"}, :_, :_, :_}, [{:"=<", :"$1", up_to_seq}], [true]}
    ])

    :ok
  end

  @impl true
  def stats(%__MODULE__{table: table}) do
    {rows, bytes, per_stream} =
      :ets.foldl(
        fn {{stream, seq}, _row, b, inserted_at}, {n, total_b, acc} ->
          stream_stats =
            Map.update(
              acc,
              stream,
              %{rows: 1, bytes: b, oldest_seq: seq, oldest_at: inserted_at},
              fn s ->
                %{
                  rows: s.rows + 1,
                  bytes: s.bytes + b,
                  oldest_seq: min(s.oldest_seq, seq),
                  oldest_at: min(s.oldest_at, inserted_at)
                }
              end
            )

          {n + 1, total_b + b, stream_stats}
        end,
        {0, 0, %{}},
        table
      )

    %{rows: rows, bytes: bytes, streams: per_stream}
  end

  @impl true
  def prune(%__MODULE__{table: table} = handle, max_rows, max_bytes) do
    %{rows: rows, bytes: bytes} = stats(handle)
    excess_rows = max(0, rows - max_rows)
    excess_bytes = max(0, bytes - max_bytes)

    if excess_rows == 0 and excess_bytes == 0 do
      0
    else
      do_prune(table, excess_rows, excess_bytes)
    end
  end

  defp do_prune(table, target_rows, target_bytes) do
    table
    |> :ets.tab2list()
    |> Enum.sort_by(fn {_key, _row, _bytes, inserted_at} -> inserted_at end)
    |> Enum.reduce_while({0, 0}, fn {key, _row, b, _ts}, {drops, dropped_bytes} ->
      cond do
        drops >= target_rows and dropped_bytes >= target_bytes ->
          {:halt, {drops, dropped_bytes}}

        true ->
          :ets.delete(table, key)
          {:cont, {drops + 1, dropped_bytes + b}}
      end
    end)
    |> elem(0)
  end
end
