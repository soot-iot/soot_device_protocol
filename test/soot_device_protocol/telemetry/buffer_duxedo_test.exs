if Code.ensure_loaded?(Duxedo.Streams) do
defmodule SootDeviceProtocol.Telemetry.Buffer.DuxedoTest do
  use ExUnit.Case, async: false

  alias SootDeviceProtocol.Telemetry.Buffer.Duxedo, as: Buffer

  setup ctx do
    instance =
      :"buf_dux_#{ctx.test |> Atom.to_string() |> String.replace(~r/[^a-zA-Z0-9]/, "_") |> String.slice(0, 50)}"

    tmp = System.tmp_dir!() |> Path.join("dux_buf_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    start_supervised!(
      {Duxedo,
       [
         instance: instance,
         persistence_dir: tmp,
         memory_limit: "32MB",
         flush_interval: 3600,
         collect_interval: 3600,
         metrics: [],
         events: []
       ]}
    )

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, handle} = Buffer.open(instance: instance)
    %{instance: instance, handle: handle}
  end

  test "define/3 creates a typed table", %{handle: handle} do
    assert :ok =
             Buffer.define(handle, "vibration", [
               {:seq, :s64},
               {:ts, :s64},
               {:x, :f64}
             ])
  end

  test "append/5 + take/3 round-trips rows oldest-first", %{handle: handle} do
    Buffer.define(handle, :vibration, [{:seq, :s64}, {:ts, :s64}, {:x, :f64}])

    Buffer.append(handle, :vibration, 1, %{ts: 1000, x: 0.1}, 0)
    Buffer.append(handle, :vibration, 2, %{ts: 1010, x: 0.2}, 0)

    [first, second] = Buffer.take(handle, :vibration, 10)
    assert first.seq == 1
    assert first.row == %{ts: 1000, x: 0.1}
    assert second.seq == 2
  end

  test "drop/3 removes rows up to and including seq", %{handle: handle} do
    Buffer.define(handle, :s, [{:seq, :s64}, {:v, :s64}])

    Enum.each(1..5, fn n ->
      Buffer.append(handle, :s, n, %{v: n}, 0)
    end)

    Buffer.drop(handle, :s, 3)

    remaining = Buffer.take(handle, :s, 10)
    assert Enum.map(remaining, & &1.seq) == [4, 5]
  end

  test "stats/1 aggregates rows across registered streams", %{handle: handle} do
    Buffer.define(handle, :a, [{:seq, :s64}, {:v, :s64}])
    Buffer.define(handle, :b, [{:seq, :s64}, {:v, :s64}])

    Buffer.append(handle, :a, 1, %{v: 1}, 0)
    Buffer.append(handle, :a, 2, %{v: 2}, 0)
    Buffer.append(handle, :b, 1, %{v: 1}, 0)

    %{rows: rows, streams: streams} = Buffer.stats(handle)
    assert rows == 3
    assert streams[:a].rows == 2
    assert streams[:b].rows == 1
  end

  test "snapshot_for_upload/3 returns Arrow IPC + seq range", %{handle: handle} do
    Buffer.define(handle, :v, [{:seq, :s64}, {:x, :f64}])
    Buffer.append(handle, :v, 1, %{x: 0.1}, 0)
    Buffer.append(handle, :v, 2, %{x: 0.2}, 0)

    {:ok, %{body: body, content_type: ct, min_seq: 1, max_seq: 2, rows: 2}} =
      Buffer.snapshot_for_upload(handle, :v, 10)

    assert is_binary(body)
    assert ct == "application/vnd.apache.arrow.stream"

    {:ok, %Adbc.Result{data: [batch]}} = Adbc.Result.from_ipc_stream(body)
    cols = Enum.map(batch, &Adbc.Column.materialize/1)
    seq_col = Enum.find(cols, &(&1.field.name == "seq"))
    assert Adbc.Column.to_list(seq_col) == [1, 2]
  end

  test "snapshot_for_upload/3 returns :empty when no buffered rows", %{handle: handle} do
    Buffer.define(handle, :empty, [{:seq, :s64}])
    assert :empty = Buffer.snapshot_for_upload(handle, :empty, 10)
  end

  test "take/3 on undefined stream returns []", %{handle: handle} do
    assert [] = Buffer.take(handle, :nope, 10)
  end
end
end
