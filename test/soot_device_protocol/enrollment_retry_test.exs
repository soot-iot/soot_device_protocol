defmodule SootDeviceProtocol.EnrollmentRetryTest do
  use ExUnit.Case, async: true

  alias SootDeviceProtocol.{Enrollment, Storage}
  alias SootDeviceProtocol.Storage.Memory
  alias SootDeviceProtocol.Test.{FakeHTTP, PKI}

  @url "https://example.test/enroll"

  setup do
    {:ok, http} = FakeHTTP.start_link()
    {:ok, storage} = Memory.open()

    ca = PKI.build_ca("/CN=Retry CA")
    bootstrap = PKI.issue(ca, "/CN=bootstrap")

    %{http: http, storage: storage, ca: ca, bootstrap: bootstrap}
  end

  test "transient failure does not crash the GenServer; retry eventually succeeds", ctx do
    issued = PKI.issue(ctx.ca, "/CN=op")

    # First attempt fails with 503; once we replace the stub, it succeeds.
    FakeHTTP.stub(ctx.http, :post, @url, {503, [], "service_unavailable"})

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
        initial_backoff_ms: 50,
        max_backoff_ms: 100,
        name: nil
      )

    Process.sleep(80)
    refute Enrollment.enrolled?(pid)
    assert Process.alive?(pid)

    response = %{
      "certificate_pem" => issued.cert_pem,
      "chain_pem" => issued.cert_pem,
      "device_id" => "device-retry",
      "state" => "operational"
    }

    FakeHTTP.stub(ctx.http, :post, @url, {200, [], Jason.encode!(response)})

    # Wait for the retry timer to fire and complete enrollment.
    wait_until(fn -> Enrollment.enrolled?(pid) end, 2_000)

    assert Enrollment.enrolled?(pid)
    assert {:ok, _} = Enrollment.operational_identity(pid)
  end

  test "missing inputs do not crash; the GenServer keeps retrying with backoff", ctx do
    {:ok, pid} =
      Enrollment.start_link(
        storage: ctx.storage,
        enroll_url: @url,
        # No enrollment_token, no bootstrap_cert, no bootstrap_key.
        http_client: FakeHTTP,
        http_opts: [agent: ctx.http],
        initial_backoff_ms: 50,
        max_backoff_ms: 100,
        name: nil
      )

    Process.sleep(150)
    refute Enrollment.enrolled?(pid)
    assert Process.alive?(pid)
  end

  defp wait_until(check, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(check)
    |> Stream.take_while(fn ok ->
      cond do
        ok ->
          false

        System.monotonic_time(:millisecond) >= deadline ->
          flunk("wait_until timed out after #{timeout_ms}ms")

        true ->
          Process.sleep(10)
          true
      end
    end)
    |> Enum.to_list()
  end
end
