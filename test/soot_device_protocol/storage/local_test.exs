defmodule SootDeviceProtocol.Storage.LocalTest do
  use ExUnit.Case, async: true

  alias SootDeviceProtocol.Storage
  alias SootDeviceProtocol.Storage.Local

  setup do
    root = Path.join(System.tmp_dir!(), "soot-storage-test-#{:erlang.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, binding} = Local.open(root)
    %{root: root, binding: binding}
  end

  test "round-trips a value via put/get", %{binding: binding} do
    assert :ok = Storage.put(binding, :hello, "world")
    assert {:ok, "world"} = Storage.get(binding, :hello)
  end

  test "missing keys return :error", %{binding: binding} do
    assert :error = Storage.get(binding, :nope)
  end

  test "delete removes the key", %{binding: binding} do
    Storage.put(binding, :temp, 42)
    assert :ok = Storage.delete(binding, :temp)
    assert :error = Storage.get(binding, :temp)
  end

  test "list returns the atom keys that have been written", %{binding: binding} do
    Storage.put(binding, :a, 1)
    Storage.put(binding, :b, 2)
    {:ok, keys} = Storage.list(binding)
    assert MapSet.new(keys) == MapSet.new(["a", "b"])
  end

  test "atomic write hides the .tmp file", %{root: root, binding: binding} do
    Storage.put(binding, :persisted, %{nested: "term"})
    assert {:ok, %{nested: "term"}} = Storage.get(binding, :persisted)
    refute File.exists?(Path.join(root, "k:persisted.tmp"))
  end

  test "binary keys with weird bytes hash to a stable filename", %{root: root, binding: binding} do
    weird = <<0, 1, 2, 3>>
    Storage.put(binding, weird, "ok")
    assert {:ok, "ok"} = Storage.get(binding, weird)
    {:ok, listing} = Storage.list(binding)
    assert Enum.any?(listing, &String.starts_with?(&1, "h:"))
    refute File.exists?(Path.join(root, "k:" <> weird))
  end

  test "open is idempotent for an existing directory", %{root: root} do
    assert {:ok, _} = Local.open(root)
    assert {:ok, _} = Local.open(root)
  end
end
