defmodule SootDeviceProtocol.Test.PKI do
  @moduledoc """
  Lightweight CA + cert helpers for tests. Generates an ephemeral CA,
  issues client certs, and signs canonical-JSON manifests the way the
  backend's `soot_contracts` would.

  Two bundle builders are provided:

    * `build_signed_bundle/2` — raw `%{path => bytes}` assets in.
    * `build_bundle/2`        — descriptor-style: takes lists of
      topics / commands / streams and produces the corresponding
      asset files itself. The structurally-identical output to what
      `soot_contracts` would emit, signed by the supplied CA.
  """

  alias SootDeviceProtocol.Contract.CanonicalJSON

  @spec build_ca(String.t()) :: %{cert_pem: String.t(), private: term(), cert: term()}
  def build_ca(subject \\ "/CN=Test CA") do
    private = X509.PrivateKey.new_ec(:secp256r1)
    cert = X509.Certificate.self_signed(private, subject, template: :root_ca)

    %{
      cert_pem: X509.Certificate.to_pem(cert),
      private: private,
      cert: cert
    }
  end

  @spec issue(map(), String.t()) :: %{cert_pem: String.t(), key_pem: String.t()}
  def issue(ca, subject) do
    private = X509.PrivateKey.new_ec(:secp256r1)
    csr = X509.CSR.new(private, subject)
    public = X509.CSR.public_key(csr)

    cert = X509.Certificate.new(public, subject, ca.cert, ca.private, template: :server)

    %{
      cert_pem: X509.Certificate.to_pem(cert),
      key_pem: X509.PrivateKey.to_pem(private)
    }
  end

  @doc """
  Build a signed contract bundle from a raw asset map. Lower-level
  than `build_bundle/2`; useful when a test wants exact control over
  the asset bytes.
  """
  @spec build_signed_bundle(map(), %{required(String.t()) => binary()}) :: %{
          manifest: map(),
          manifest_json: binary(),
          assets: %{required(String.t()) => binary()},
          fingerprint: String.t()
        }
  def build_signed_bundle(ca, assets \\ default_assets()) do
    sign_assets(ca, assets, "test-ca")
  end

  @doc """
  Build a signed contract bundle from descriptor-style inputs.

      build_bundle(ca,
        topics:   [%{pattern: "tenants/+/devices/+/shadow/desired"}],
        commands: [],
        shadows:  %{},
        streams:  [%{name: "vibration", fingerprint: "fp", schema: %{}}],
        trust_pem: ca.cert_pem
      )

  Returns `%{ca:, manifest:, manifest_json:, assets:, fingerprint:}`.
  """
  @spec build_bundle(map(), keyword()) :: map()
  def build_bundle(ca, opts \\ []) do
    topics = Keyword.get(opts, :topics, [])
    commands = Keyword.get(opts, :commands, [])
    shadows = Keyword.get(opts, :shadows, %{})
    streams = Keyword.get(opts, :streams, [])
    trust_pem = Keyword.get(opts, :trust_pem, ca.cert_pem)

    stream_assets =
      Enum.flat_map(streams, fn %{name: name} = s ->
        descriptor =
          s
          |> Map.put_new(:tenant_scope, :shared)
          |> Map.put_new(:retention, %{})
          |> Map.put_new(:ingest_endpoint, "/ingest/#{name}")
          |> Map.put_new(:sequence_field, nil)
          |> Map.put_new(:schema_fingerprint, Map.get(s, :fingerprint, ""))
          |> Map.put_new(:schema, %{})

        [
          {"streams/#{name}.json", encode_pretty(Map.drop(descriptor, [:schema]))},
          {"streams/#{name}.arrow_schema", encode_pretty(descriptor.schema)}
        ]
      end)

    pki_assets = [
      {"pki/trust_chain.pem", trust_pem},
      {"pki/fingerprints.json", encode_pretty(%{"fingerprints" => []})}
    ]

    base_assets = [
      {"topics.json", encode_pretty(%{"topics" => topics})},
      {"commands.json", encode_pretty(%{"commands" => commands})},
      {"shadow.json", encode_pretty(shadows)}
    ]

    assets = Map.new(base_assets ++ stream_assets ++ pki_assets)

    ca
    |> sign_assets(assets, ca_fingerprint(ca))
    |> Map.put(:ca, ca)
  end

  # ─── helpers ────────────────────────────────────────────────────────

  defp sign_assets(ca, assets, signed_by) do
    asset_index = build_asset_index(assets)

    fingerprint =
      asset_index
      |> CanonicalJSON.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    manifest_unsigned = %{
      "version" => 1,
      "generated_at" => "2026-04-26T12:00:00Z",
      "fingerprint" => fingerprint,
      "assets" => asset_index
    }

    body = CanonicalJSON.encode!(manifest_unsigned)
    signature = :public_key.sign(body, :sha256, ca.private) |> Base.encode64()

    manifest =
      manifest_unsigned
      |> Map.put("signed_by", signed_by)
      |> Map.put("signature", signature)

    %{
      manifest: manifest,
      manifest_json: CanonicalJSON.encode!(manifest),
      assets: assets,
      fingerprint: fingerprint
    }
  end

  defp build_asset_index(assets) do
    Map.new(assets, fn {path, body} ->
      {path,
       %{
         "sha256" => :crypto.hash(:sha256, body) |> Base.encode16(case: :lower),
         "size" => byte_size(body)
       }}
    end)
  end

  defp encode_pretty(value), do: CanonicalJSON.encode!(value) <> "\n"

  defp ca_fingerprint(%{cert_pem: pem}),
    do: :crypto.hash(:sha256, pem) |> Base.encode16(case: :lower)

  defp default_assets do
    %{
      "topics.json" => ~s({"topics":[]}\n),
      "commands.json" => ~s({"commands":[]}\n),
      "shadow.json" => ~s({"shadow":{}}\n)
    }
  end
end
