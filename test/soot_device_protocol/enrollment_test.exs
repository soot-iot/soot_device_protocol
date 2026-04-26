defmodule SootDeviceProtocol.EnrollmentTest do
  use ExUnit.Case, async: true

  alias SootDeviceProtocol.{Enrollment, Storage}
  alias SootDeviceProtocol.Storage.Memory
  alias SootDeviceProtocol.Test.{FakeHTTP, PKI}

  @url "https://example.test/enroll"

  setup do
    {:ok, http} = FakeHTTP.start_link()
    {:ok, storage} = Memory.open()

    ca = PKI.build_ca("/CN=Enrollment CA")
    bootstrap = PKI.issue(ca, "/CN=bootstrap")

    %{
      http: http,
      storage: storage,
      ca: ca,
      bootstrap: bootstrap
    }
  end

  test "enrolls and persists operational identity", ctx do
    issued = PKI.issue(ctx.ca, "/CN=op")

    response = %{
      "certificate_pem" => issued.cert_pem,
      "chain_pem" => issued.cert_pem <> ctx.ca.cert_pem,
      "device_id" => "device-001",
      "state" => "operational"
    }

    FakeHTTP.stub(ctx.http, :post, @url, {200, [], Jason.encode!(response)})

    {:ok, pid} =
      Enrollment.start_link(
        storage: ctx.storage,
        enroll_url: @url,
        enrollment_token: "TOKEN",
        bootstrap_cert: ctx.bootstrap.cert_pem,
        bootstrap_key: ctx.bootstrap.key_pem,
        trust_pems: [ctx.ca.cert_pem],
        subject: "/CN=op",
        http_client: FakeHTTP,
        http_opts: [agent: ctx.http],
        auto_enroll: false,
        name: nil
      )

    refute Enrollment.enrolled?(pid)
    assert {:ok, :enrolled} = Enrollment.ensure_enrolled(pid)
    assert Enrollment.enrolled?(pid)

    assert {:ok, identity} = Enrollment.operational_identity(pid)
    assert identity.cert_pem == issued.cert_pem
    assert identity.device_id == "device-001"
    refute identity.key_pem == nil

    [request] = FakeHTTP.requests(ctx.http)
    assert request.method == :post
    assert request.url == @url
    body = Jason.decode!(request.body)
    assert body["token"] == "TOKEN"
    assert body["csr_pem"] =~ "CERTIFICATE REQUEST"
  end

  test "boots into :enrolled when storage already has identity", ctx do
    issued = PKI.issue(ctx.ca, "/CN=op")
    Storage.put(ctx.storage, :operational_cert_pem, issued.cert_pem)
    Storage.put(ctx.storage, :operational_chain_pem, issued.cert_pem)
    Storage.put(ctx.storage, :operational_key_pem, issued.key_pem)
    Storage.put(ctx.storage, :device_id, "device-existing")

    {:ok, pid} =
      Enrollment.start_link(
        storage: ctx.storage,
        enroll_url: @url,
        http_client: FakeHTTP,
        http_opts: [agent: ctx.http],
        auto_enroll: false,
        name: nil
      )

    assert Enrollment.enrolled?(pid)
    assert {:ok, _} = Enrollment.operational_identity(pid)
    assert FakeHTTP.requests(ctx.http) == []
  end

  test "fails on backend HTTP error", ctx do
    FakeHTTP.stub(ctx.http, :post, @url, {403, [], Jason.encode!(%{error: "invalid_token"})})

    {:ok, pid} =
      Enrollment.start_link(
        storage: ctx.storage,
        enroll_url: @url,
        enrollment_token: "BAD",
        bootstrap_cert: ctx.bootstrap.cert_pem,
        bootstrap_key: ctx.bootstrap.key_pem,
        trust_pems: [ctx.ca.cert_pem],
        http_client: FakeHTTP,
        http_opts: [agent: ctx.http],
        auto_enroll: false,
        name: nil
      )

    assert {:error, {:enroll_http_error, 403, _}} = Enrollment.ensure_enrolled(pid)
    refute Enrollment.enrolled?(pid)
  end

  test "fails when required inputs are missing", ctx do
    {:ok, pid} =
      Enrollment.start_link(
        storage: ctx.storage,
        enroll_url: @url,
        http_client: FakeHTTP,
        http_opts: [agent: ctx.http],
        auto_enroll: false,
        name: nil
      )

    assert {:error, :missing_enrollment_token} = Enrollment.ensure_enrolled(pid)
  end

  test "auto-enrolls on start when storage is empty", ctx do
    issued = PKI.issue(ctx.ca, "/CN=op")

    response = %{
      "certificate_pem" => issued.cert_pem,
      "chain_pem" => issued.cert_pem <> ctx.ca.cert_pem,
      "device_id" => "device-auto",
      "state" => "operational"
    }

    FakeHTTP.stub(ctx.http, :post, @url, {200, [], Jason.encode!(response)})

    {:ok, pid} =
      Enrollment.start_link(
        storage: ctx.storage,
        enroll_url: @url,
        enrollment_token: "TOK",
        bootstrap_cert: ctx.bootstrap.cert_pem,
        bootstrap_key: ctx.bootstrap.key_pem,
        trust_pems: [ctx.ca.cert_pem],
        http_client: FakeHTTP,
        http_opts: [agent: ctx.http],
        name: nil
      )

    # The continue runs synchronously after init, so by the time enrolled?/1
    # returns we should already be enrolled.
    Process.sleep(20)
    assert Enrollment.enrolled?(pid)
  end
end
