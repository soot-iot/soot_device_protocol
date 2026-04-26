defmodule SootDeviceProtocol.Contract.BundleTest do
  use ExUnit.Case, async: true

  alias SootDeviceProtocol.Contract.Bundle
  alias SootDeviceProtocol.Test.PKI

  setup do
    ca = PKI.build_ca("/CN=Bundle CA")
    fixture = PKI.build_signed_bundle(ca)
    %{ca: ca, fixture: fixture}
  end

  test "parses a manifest into a Bundle", %{fixture: fixture} do
    {:ok, %Bundle{} = bundle} = Bundle.parse_manifest(fixture.manifest_json)
    assert bundle.fingerprint == fixture.fingerprint
    assert bundle.assets == %{}
  end

  test "rejects malformed manifest JSON" do
    assert {:error, {:invalid_manifest_json, _}} = Bundle.parse_manifest("not json")
  end

  test "rejects manifest missing assets/fingerprint" do
    assert {:error, :invalid_manifest_shape} = Bundle.parse_manifest(~s({"version":1}))
  end

  test "verifies a fully-attached bundle", %{ca: ca, fixture: fixture} do
    {:ok, bundle} = Bundle.parse_manifest(fixture.manifest_json)

    bundle =
      Enum.reduce(fixture.assets, bundle, fn {path, body}, acc ->
        Bundle.attach_asset(acc, path, body)
      end)

    assert :ok = Bundle.verify(bundle, [ca.cert_pem])
  end

  test "rejects a bundle whose asset bytes do not match the manifest", %{ca: ca, fixture: fixture} do
    {:ok, bundle} = Bundle.parse_manifest(fixture.manifest_json)
    [{path, _} | _] = Map.to_list(fixture.assets)

    bundle = Bundle.attach_asset(bundle, path, "tampered")

    bundle =
      Enum.reduce(fixture.assets, bundle, fn {p, body}, acc ->
        if p == path, do: acc, else: Bundle.attach_asset(acc, p, body)
      end)

    assert {:error, {:asset_mismatch, ^path}} = Bundle.verify(bundle, [ca.cert_pem])
  end

  test "rejects a bundle missing assets", %{ca: ca, fixture: fixture} do
    {:ok, bundle} = Bundle.parse_manifest(fixture.manifest_json)

    [_skipped | rest] = Enum.to_list(fixture.assets)

    bundle =
      Enum.reduce(rest, bundle, fn {path, body}, acc -> Bundle.attach_asset(acc, path, body) end)

    assert {:error, {:missing_asset, _}} = Bundle.verify(bundle, [ca.cert_pem])
  end

  test "rejects a bundle when no trust pem verifies the signature", %{fixture: fixture} do
    other_ca = PKI.build_ca("/CN=Different CA")
    {:ok, bundle} = Bundle.parse_manifest(fixture.manifest_json)

    bundle =
      Enum.reduce(fixture.assets, bundle, fn {path, body}, acc ->
        Bundle.attach_asset(acc, path, body)
      end)

    assert {:error, :signature_verification_failed} =
             Bundle.verify(bundle, [other_ca.cert_pem])
  end

  test "rejects a bundle whose declared fingerprint does not match its asset index", %{
    ca: ca,
    fixture: fixture
  } do
    tampered =
      fixture.manifest
      |> Map.put("fingerprint", String.duplicate("0", 64))

    bundle = Bundle.from_manifest(tampered, fixture.assets)
    assert {:error, {:fingerprint_mismatch, _}} = Bundle.verify(bundle, [ca.cert_pem])
  end
end
