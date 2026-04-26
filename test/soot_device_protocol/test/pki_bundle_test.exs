defmodule SootDeviceProtocol.Test.PKIBundleTest do
  use ExUnit.Case, async: true

  alias SootDeviceProtocol.Contract.Bundle
  alias SootDeviceProtocol.Test.PKI

  test "build_bundle/2 produces a manifest the device's verifier accepts" do
    ca = PKI.build_ca("/CN=Factory CA")

    fixture =
      PKI.build_bundle(ca,
        topics: [%{pattern: "tenants/+/devices/+/shadow/desired"}],
        streams: [%{name: "vibration", fingerprint: "fp", schema: %{}}]
      )

    {:ok, bundle} = Bundle.parse_manifest(fixture.manifest_json)

    bundle =
      Enum.reduce(fixture.assets, bundle, fn {path, body}, acc ->
        Bundle.attach_asset(acc, path, body)
      end)

    assert :ok = Bundle.verify(bundle, [ca.cert_pem])
  end

  test "fingerprint changes with the asset bytes" do
    ca = PKI.build_ca()
    a = PKI.build_bundle(ca, topics: [%{pattern: "a"}])
    b = PKI.build_bundle(ca, topics: [%{pattern: "b"}])
    refute a.fingerprint == b.fingerprint
  end
end
