defmodule SootDeviceProtocol.Storage do
  @moduledoc """
  Behavior for the small key/value store every component reaches for to
  persist itself across reboots.

  The contract is intentionally minimal: a *handle* is opaque to
  callers and threaded into the `get`/`put`/`delete`/`list` calls. Each
  implementation defines what the handle looks like.

  Two implementations ship in-tree:

    * `SootDeviceProtocol.Storage.Local` — file-system backed; the
      default for Nerves and any persistent target.
    * `SootDeviceProtocol.Storage.Memory` — ETS-backed; the default for
      tests and host-VM development.

  Operators that target a constrained device with a different
  persistence story (a ramfs sensor, a key-value flash partition) can
  implement this behavior without changing any consumer.

  ### Keys and values

  Keys are arbitrary `t:term/0` values; values are arbitrary terms.
  Implementations are expected to round-trip both losslessly via
  `:erlang.term_to_binary/1` (or equivalent) when persisting.
  """

  @type handle :: term()
  @type key :: term()
  @type value :: term()

  @callback get(handle(), key()) :: {:ok, value()} | :error
  @callback put(handle(), key(), value()) :: :ok | {:error, term()}
  @callback delete(handle(), key()) :: :ok | {:error, term()}
  @callback list(handle()) :: {:ok, [key()]} | {:error, term()}

  @typedoc """
  A storage *binding* — a `{module, handle}` pair — is what most
  consumers carry around so they can call into the implementation
  generically.
  """
  @type binding :: {module(), handle()}

  @doc "Look up `key` through `binding`."
  @spec get(binding(), key()) :: {:ok, value()} | :error
  def get({mod, handle}, key), do: mod.get(handle, key)

  @doc "Store `value` under `key` through `binding`."
  @spec put(binding(), key(), value()) :: :ok | {:error, term()}
  def put({mod, handle}, key, value), do: mod.put(handle, key, value)

  @doc "Remove `key` through `binding`."
  @spec delete(binding(), key()) :: :ok | {:error, term()}
  def delete({mod, handle}, key), do: mod.delete(handle, key)

  @doc "List every key through `binding`."
  @spec list(binding()) :: {:ok, [key()]} | {:error, term()}
  def list({mod, handle}), do: mod.list(handle)
end
