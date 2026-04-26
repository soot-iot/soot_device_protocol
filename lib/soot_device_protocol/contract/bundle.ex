defmodule SootDeviceProtocol.Contract.Bundle do
  @moduledoc """
  Device-side parser + verifier for contract bundles produced by
  `soot_contracts`. Mirrors the verification side of
  `SootContracts.Bundle` — `assemble`/`sign` belong to the backend; the
  device only ever consumes.

  A parsed bundle has the shape:

      %SootDeviceProtocol.Contract.Bundle{
        manifest:    %{...string-keyed manifest...},
        fingerprint: "<sha256 hex>",
        assets:      %{ "<path>" => binary }
      }

  `verify/2` requires every asset listed in the manifest to be present
  in `assets`, the SHA-256 of each asset's bytes to match, and the
  manifest signature to verify against one of the CA public keys
  derived from a list of PEM-encoded trust certs.
  """

  alias SootDeviceProtocol.Contract.CanonicalJSON

  defstruct [:manifest, :fingerprint, :assets]

  @type t :: %__MODULE__{
          manifest: map(),
          fingerprint: String.t(),
          assets: %{required(String.t()) => binary()}
        }

  @doc """
  Parse the manifest JSON returned by `GET /.well-known/soot/contract`
  into a `Bundle` with no assets attached yet.

  `attach_asset/3` is the natural follow-up: fetch each path under
  `manifest.assets`, attach its bytes, then call `verify/2`.
  """
  @spec parse_manifest(binary()) :: {:ok, t()} | {:error, term()}
  def parse_manifest(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"fingerprint" => fp, "assets" => assets} = manifest}
      when is_binary(fp) and is_map(assets) ->
        {:ok, %__MODULE__{manifest: manifest, fingerprint: fp, assets: %{}}}

      {:ok, _} ->
        {:error, :invalid_manifest_shape}

      {:error, reason} ->
        {:error, {:invalid_manifest_json, reason}}
    end
  end

  @doc "Attach `bytes` as the asset stored under `path` in the bundle."
  @spec attach_asset(t(), String.t(), binary()) :: t()
  def attach_asset(%__MODULE__{assets: assets} = bundle, path, bytes)
      when is_binary(path) and is_binary(bytes) do
    %{bundle | assets: Map.put(assets, path, bytes)}
  end

  @doc """
  Verify that:

    1. Every asset in `manifest.assets` is attached and its SHA-256
       matches the manifest's declared digest.
    2. The manifest fingerprint equals the SHA-256 of the canonical
       JSON of the asset index (so a tampered manifest body is
       caught even before the signature step).
    3. The manifest signature verifies against one of `trust_pems`'s
       public keys.

  `trust_pems` is a list of PEM strings containing CA certificates;
  in production this comes from the previous bundle's
  `pki/trust_chain.pem` asset (or, on first boot, from a trust file
  burned into the firmware image).
  """
  @spec verify(t(), [String.t()]) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = bundle, trust_pems) when is_list(trust_pems) do
    with :ok <- verify_assets(bundle),
         :ok <- verify_fingerprint(bundle),
         :ok <- verify_signature(bundle, trust_pems) do
      :ok
    end
  end

  @doc """
  Convenience for callers that have the asset bytes already (e.g. from
  the `soot_device_test` fixture): build a fully-attached bundle from
  a manifest map and an `%{path => bytes}` map.
  """
  @spec from_manifest(map(), %{required(String.t()) => binary()}) :: t()
  def from_manifest(manifest, assets) when is_map(manifest) and is_map(assets) do
    %__MODULE__{
      manifest: manifest,
      fingerprint: Map.fetch!(manifest, "fingerprint"),
      assets: assets
    }
  end

  # ─── verification steps ──────────────────────────────────────────────

  defp verify_assets(%__MODULE__{manifest: %{"assets" => index}, assets: blobs}) do
    paths = Map.keys(index)

    Enum.find_value(paths, :ok, fn path ->
      expected = Map.fetch!(index, path)
      bytes = Map.get(blobs, path)

      cond do
        is_nil(bytes) ->
          {:error, {:missing_asset, path}}

        actual_sha256(bytes) != Map.fetch!(expected, "sha256") ->
          {:error, {:asset_mismatch, path}}

        Map.fetch!(expected, "size") != byte_size(bytes) ->
          {:error, {:asset_size_mismatch, path}}

        true ->
          nil
      end
    end)
  end

  defp verify_fingerprint(%__MODULE__{manifest: manifest, fingerprint: fp}) do
    asset_index = Map.fetch!(manifest, "assets")
    derived = CanonicalJSON.encode!(asset_index) |> sha256_hex()

    if derived == fp do
      :ok
    else
      {:error, {:fingerprint_mismatch, %{declared: fp, derived: derived}}}
    end
  end

  defp verify_signature(%__MODULE__{manifest: manifest}, trust_pems) do
    with {:ok, signature} <- decode_signature(Map.get(manifest, "signature")),
         body <- signing_body(manifest),
         {:ok, _key} <- find_verifying_key(body, signature, trust_pems) do
      :ok
    end
  end

  defp signing_body(manifest) do
    manifest
    |> Map.drop(["signature", "signed_by"])
    |> CanonicalJSON.encode!()
  end

  defp decode_signature(nil), do: {:error, :unsigned_bundle}

  defp decode_signature(b64) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :invalid_signature_encoding}
    end
  end

  defp find_verifying_key(body, signature, trust_pems) do
    keys =
      trust_pems
      |> Enum.flat_map(&public_keys_for_pem/1)

    case Enum.find(keys, &:public_key.verify(body, :sha256, signature, &1)) do
      nil -> {:error, :signature_verification_failed}
      key -> {:ok, key}
    end
  end

  defp public_keys_for_pem(pem) when is_binary(pem) do
    pem
    |> X509.from_pem()
    |> Enum.flat_map(fn
      {:Certificate, _, _} = entry ->
        [entry |> :public_key.pkix_decode_cert(:otp) |> X509.Certificate.public_key()]

      cert when is_tuple(cert) and elem(cert, 0) in [:OTPCertificate, :Certificate] ->
        [X509.Certificate.public_key(cert)]

      _ ->
        []
    end)
  rescue
    _ -> fallback_public_keys(pem)
  end

  defp fallback_public_keys(pem) do
    pem
    |> :public_key.pem_decode()
    |> Enum.flat_map(fn
      {:Certificate, der, :not_encrypted} ->
        cert = :public_key.pkix_decode_cert(der, :otp)
        [X509.Certificate.public_key(cert)]

      _ ->
        []
    end)
  end

  defp actual_sha256(bytes), do: bytes |> sha256() |> Base.encode16(case: :lower)
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes)
  defp sha256_hex(bin), do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)
end
