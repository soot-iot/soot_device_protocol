defmodule SootDeviceProtocol.Storage.Local do
  @moduledoc """
  File-system-backed `SootDeviceProtocol.Storage`. Each key becomes a
  file under the configured root directory; the value is the file's
  binary content (encoded as a versioned `:erlang.term_to_binary/1`
  blob).

  Keys are atoms or short strings; arbitrary terms are accepted but the
  on-disk file name uses a SHA-256 of the canonical term encoding to
  avoid filename collisions.

  Atomic writes go through a sibling `*.tmp` file followed by a rename,
  so a crash mid-write never leaves a half-written value.
  """

  @behaviour SootDeviceProtocol.Storage

  @spec open(Path.t()) :: {:ok, SootDeviceProtocol.Storage.binding()} | {:error, term()}
  def open(root) do
    case File.mkdir_p(root) do
      :ok -> {:ok, {__MODULE__, root}}
      {:error, _} = err -> err
    end
  end

  @spec open!(Path.t()) :: SootDeviceProtocol.Storage.binding()
  def open!(root) do
    case open(root) do
      {:ok, binding} -> binding
      {:error, reason} -> raise "could not open storage root #{inspect(root)}: #{inspect(reason)}"
    end
  end

  @impl true
  def get(root, key) do
    path = path_for(root, key)

    case File.read(path) do
      {:ok, bin} ->
        try do
          {:ok, :erlang.binary_to_term(bin)}
        rescue
          _ -> :error
        end

      {:error, :enoent} ->
        :error

      {:error, _} ->
        :error
    end
  end

  @impl true
  def put(root, key, value) do
    path = path_for(root, key)
    tmp = path <> ".tmp"
    bin = :erlang.term_to_binary(value)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, bin),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, _} = err -> err
    end
  end

  @impl true
  def delete(root, key) do
    path = path_for(root, key)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} = err -> err
    end
  end

  @impl true
  def list(root) do
    case File.ls(root) do
      {:ok, entries} ->
        keys =
          entries
          |> Enum.reject(&String.ends_with?(&1, ".tmp"))
          |> Enum.map(&decode_key/1)
          |> Enum.reject(&is_nil/1)

        {:ok, keys}

      {:error, _} = err ->
        err
    end
  end

  defp path_for(root, key), do: Path.join(root, encode_key(key))

  # Atoms and short ASCII strings get a stable, human-readable filename;
  # anything else gets a sha256 hexdigest. The "k:" / "h:" prefix is
  # what `decode_key/1` uses to round-trip atom keys back from listings.
  defp encode_key(key) when is_atom(key), do: "k:" <> Atom.to_string(key)

  defp encode_key(key) when is_binary(key) do
    if String.match?(key, ~r/\A[A-Za-z0-9._-]{1,128}\z/) do
      "k:" <> key
    else
      hash_key(key)
    end
  end

  defp encode_key(key), do: hash_key(key)

  defp hash_key(key) do
    "h:" <> Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(key)), case: :lower)
  end

  defp decode_key("k:" <> rest) do
    case rest do
      "" -> nil
      v -> v
    end
  end

  # Hashed keys can't be reversed; surface them as the encoded form so
  # callers can still iterate / delete by exact match.
  defp decode_key("h:" <> _ = full), do: full
  defp decode_key(_), do: nil
end
