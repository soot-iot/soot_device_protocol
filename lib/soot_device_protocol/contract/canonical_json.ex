defmodule SootDeviceProtocol.Contract.CanonicalJSON do
  @moduledoc """
  Same canonical-JSON shape as `SootContracts.CanonicalJSON` on the
  backend: maps are encoded with keys sorted lexicographically as
  strings; atoms are stringified; `DateTime` / `Date` are encoded as
  ISO8601 strings. Lists are recursed in place.

  Devices use this to hash and signature-verify a manifest after
  fetching it from `/.well-known/soot/contract`. The bytes a device
  produces here must match byte-for-byte what the backend produced when
  it signed the bundle, so this implementation deliberately mirrors the
  backend's.
  """

  @doc "JSON-encode `value` with sorted keys at every level."
  @spec encode!(term()) :: String.t()
  def encode!(value) do
    value
    |> sort_keys()
    |> Jason.encode!()
  end

  defp sort_keys(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.map(fn {k, v} -> {to_string(k), sort_keys(v)} end)
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Jason.OrderedObject.new()
  end

  defp sort_keys(value) when is_list(value), do: Enum.map(value, &sort_keys/1)
  defp sort_keys(%DateTime{} = v), do: DateTime.to_iso8601(v)
  defp sort_keys(%Date{} = v), do: Date.to_iso8601(v)

  defp sort_keys(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp sort_keys(value), do: value
end
