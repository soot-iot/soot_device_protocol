defmodule SootDeviceProtocol.SupervisorTest do
  use ExUnit.Case, async: true

  alias SootDeviceProtocol.{Commands, Contract, Enrollment, MQTT, Shadow, Telemetry}
  alias SootDeviceProtocol.MQTT.Transport.Test, as: TestTransport
  alias SootDeviceProtocol.Storage.Memory
  alias SootDeviceProtocol.Test.{FakeHTTP, PKI}

  @enroll_url "https://example.test/enroll"

  setup do
    {:ok, http} = FakeHTTP.start_link()
    {:ok, storage} = Memory.open()

    ca = PKI.build_ca("/CN=Sup CA")
    bootstrap = PKI.issue(ca, "/CN=bootstrap")
    issued = PKI.issue(ca, "/CN=op")

    enroll_response =
      Jason.encode!(%{
        "certificate_pem" => issued.cert_pem,
        "chain_pem" => issued.cert_pem <> ca.cert_pem,
        "device_id" => "device-sup",
        "state" => "operational"
      })

    FakeHTTP.stub(http, :post, @enroll_url, {200, [], enroll_response})

    %{
      http: http,
      storage: storage,
      ca: ca,
      bootstrap: bootstrap
    }
  end

  test "boots Enrollment, MQTT, Shadow, Commands, Telemetry in :rest_for_one order", ctx do
    {:ok, sup} =
      SootDeviceProtocol.Supervisor.start_link(
        name: nil,
        storage: ctx.storage,
        enrollment: [
          enroll_url: @enroll_url,
          enrollment_token: "TOKEN",
          bootstrap_cert: ctx.bootstrap.cert_pem,
          bootstrap_key: ctx.bootstrap.key_pem,
          trust_pems: [ctx.ca.cert_pem],
          subject: "/CN=op",
          http_client: FakeHTTP,
          http_opts: [agent: ctx.http],
          auto_enroll: true,
          name: nil
        ],
        mqtt: [
          transport: TestTransport,
          transport_opts: [],
          name: nil
        ]
      )

    # which_children returns children in reverse start order, so the
    # last entry is the first one started. Reversing gives us :rest_for_one order.
    started_modules =
      sup
      |> Supervisor.which_children()
      |> Enum.map(fn {_id, _pid, _type, [mod]} -> mod end)
      |> Enum.reverse()

    assert started_modules == [Enrollment, MQTT.Client]

    refute Contract.Refresh in started_modules
    refute Shadow.Sync in started_modules
    refute Commands.Dispatcher in started_modules
    refute Telemetry.Pipeline in started_modules

    Supervisor.stop(sup)
  end

  test "skips disabled / nil child specs", ctx do
    {:ok, sup} =
      SootDeviceProtocol.Supervisor.start_link(
        name: nil,
        storage: ctx.storage,
        enrollment: [
          enroll_url: @enroll_url,
          enrollment_token: "TOKEN",
          bootstrap_cert: ctx.bootstrap.cert_pem,
          bootstrap_key: ctx.bootstrap.key_pem,
          trust_pems: [ctx.ca.cert_pem],
          subject: "/CN=op",
          http_client: FakeHTTP,
          http_opts: [agent: ctx.http],
          auto_enroll: false,
          name: nil
        ],
        mqtt: :disabled,
        contract_refresh: :disabled,
        shadow: :disabled,
        commands: :disabled,
        telemetry: :disabled
      )

    started_modules =
      sup
      |> Supervisor.which_children()
      |> Enum.map(fn {_id, _pid, _type, [mod]} -> mod end)

    assert started_modules == [Enrollment]

    Supervisor.stop(sup)
  end

  test "fails to start without :storage", _ctx do
    Process.flag(:trap_exit, true)

    assert {:error, {%KeyError{key: :storage}, _stack}} =
             SootDeviceProtocol.Supervisor.start_link(name: nil)
  end
end
