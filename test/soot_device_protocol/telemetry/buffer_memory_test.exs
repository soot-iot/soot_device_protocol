defmodule SootDeviceProtocol.Telemetry.Buffer.MemoryTest do
  use ExUnit.Case, async: true

  alias SootDeviceProtocol.Telemetry.Buffer.Memory

  setup do
    {:ok, buffer} = Memory.open()
    %{buffer: buffer}
  end

  test "appends and takes oldest-first", %{buffer: buffer} do
    Memory.append(buffer, "vibration", 1, %{x: 1}, 12)
    Memory.append(buffer, "vibration", 2, %{x: 2}, 12)
    Memory.append(buffer, "vibration", 3, %{x: 3}, 12)

    [a, b] = Memory.take(buffer, "vibration", 2)
    assert a.seq == 1
    assert b.seq == 2
  end

  test "drops up to a sequence", %{buffer: buffer} do
    Enum.each(1..5, fn n -> Memory.append(buffer, "v", n, %{n: n}, 4) end)
    :ok = Memory.drop(buffer, "v", 3)

    remaining = Memory.take(buffer, "v", 10)
    assert Enum.map(remaining, & &1.seq) == [4, 5]
  end

  test "stats summarize total rows / bytes per stream", %{buffer: buffer} do
    Memory.append(buffer, "a", 1, %{}, 10)
    Memory.append(buffer, "a", 2, %{}, 10)
    Memory.append(buffer, "b", 1, %{}, 4)

    %{rows: rows, bytes: bytes, streams: streams} = Memory.stats(buffer)
    assert rows == 3
    assert bytes == 24
    assert streams["a"].rows == 2
    assert streams["b"].rows == 1
  end

  test "prune drops the oldest entries when over budget", %{buffer: buffer} do
    Enum.each(1..10, fn n -> Memory.append(buffer, "v", n, %{n: n}, 100) end)

    dropped = Memory.prune(buffer, _max_rows = 5, _max_bytes = 1_000_000)
    assert dropped == 5

    remaining = Memory.take(buffer, "v", 100)
    assert Enum.map(remaining, & &1.seq) == [6, 7, 8, 9, 10]
  end

  test "prune is a no-op when within budget", %{buffer: buffer} do
    Memory.append(buffer, "v", 1, %{}, 1)
    assert Memory.prune(buffer, 100, 1_000_000) == 0
  end
end
