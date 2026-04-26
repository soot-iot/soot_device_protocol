defmodule SootDeviceProtocol.Storage.Memory do
  @moduledoc """
  ETS-backed `SootDeviceProtocol.Storage`. The default for tests and
  host-VM development. Values disappear on process exit by design — if
  you want them to persist across reboots, use
  `SootDeviceProtocol.Storage.Local`.

  Backed by a public ETS table created at `open/0`. The owning process
  holds the table; if it dies, the table goes with it.
  """

  @behaviour SootDeviceProtocol.Storage

  @spec open() :: {:ok, SootDeviceProtocol.Storage.binding()}
  def open do
    table = :ets.new(:soot_device_storage_memory, [:set, :public])
    {:ok, {__MODULE__, table}}
  end

  @spec open!() :: SootDeviceProtocol.Storage.binding()
  def open! do
    {:ok, binding} = open()
    binding
  end

  @impl true
  def get(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :error
    end
  end

  @impl true
  def put(table, key, value) do
    true = :ets.insert(table, {key, value})
    :ok
  end

  @impl true
  def delete(table, key) do
    true = :ets.delete(table, key)
    :ok
  end

  @impl true
  def list(table) do
    keys = :ets.foldl(fn {k, _}, acc -> [k | acc] end, [], table)
    {:ok, keys}
  end
end
