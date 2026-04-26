defmodule SootDeviceProtocol.Storage.MemoryTest do
  use ExUnit.Case, async: true

  alias SootDeviceProtocol.Storage
  alias SootDeviceProtocol.Storage.Memory

  setup do
    {:ok, binding} = Memory.open()
    %{binding: binding}
  end

  test "round-trips a term", %{binding: binding} do
    assert :ok = Storage.put(binding, :map, %{a: 1})
    assert {:ok, %{a: 1}} = Storage.get(binding, :map)
  end

  test "lists every key that was put", %{binding: binding} do
    Storage.put(binding, :a, 1)
    Storage.put(binding, :b, 2)
    assert {:ok, keys} = Storage.list(binding)
    assert Enum.sort(keys) == [:a, :b]
  end

  test "delete removes a key", %{binding: binding} do
    Storage.put(binding, :tmp, "x")
    Storage.delete(binding, :tmp)
    assert :error = Storage.get(binding, :tmp)
  end
end
