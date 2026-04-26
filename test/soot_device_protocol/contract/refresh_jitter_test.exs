defmodule SootDeviceProtocol.Contract.RefreshJitterTest do
  use ExUnit.Case, async: true

  alias SootDeviceProtocol.Contract.Refresh
  alias SootDeviceProtocol.Storage.Memory
  alias SootDeviceProtocol.Test.{FakeHTTP, PKI}

  @url "https://example.test/.well-known/soot/contract"

  setup do
    {:ok, http} = FakeHTTP.start_link()
    {:ok, storage} = Memory.open()

    ca = PKI.build_ca("/CN=Refresh Jitter CA")
    fixture = PKI.build_signed_bundle(ca)

    FakeHTTP.stub(http, :get, @url,
      {200, [{"content-type", "application/json"}], fixture.manifest_json})

    Enum.each(fixture.assets, fn {path, body} ->
      url = @url <> "/" <> fixture.fingerprint <> "/" <> path
      FakeHTTP.stub(http, :get, url, {200, [], body})
    end)

    %{http: http, storage: storage, ca: ca, fixture: fixture}
  end

  test "refresh + stop pair fires :refresh.{:start,:stop} events", ctx do
    handler_id = make_ref()
    me = self()

    :telemetry.attach_many(
      handler_id,
      [
        [:soot_device, :contract, :refresh, :start],
        [:soot_device, :contract, :refresh, :stop]
      ],
      fn name, m, meta, _ -> send(me, {:event, name, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, pid} =
      Refresh.start_link(
        url: @url,
        storage: ctx.storage,
        trust_pems: [ctx.ca.cert_pem],
        interval_ms: 60_000,
        http_client: FakeHTTP,
        http_opts: [agent: ctx.http],
        auto_refresh: false,
        name: nil
      )

    assert {:ok, :updated} = Refresh.refresh(pid)

    assert_receive {:event, [:soot_device, :contract, :refresh, :start], _, %{url: @url}}

    assert_receive {:event, [:soot_device, :contract, :refresh, :stop], stop_meas, stop_meta}

    assert is_integer(stop_meas.duration_ms)
    # span passes through whatever the inner closure returned. attempt_refresh
    # returns {:ok, :updated, %Bundle{}} so handlers can attach to the bundle.
    assert match?({:ok, :updated, _bundle}, stop_meta.result)
  end

  test "failed refresh enters Backoff and retries on a shorter cadence than interval_ms", ctx do
    other = PKI.build_ca("/CN=Wrong CA")

    {:ok, pid} =
      Refresh.start_link(
        url: @url,
        storage: ctx.storage,
        trust_pems: [other.cert_pem],
        interval_ms: 60_000,
        initial_backoff_ms: 50,
        max_backoff_ms: 100,
        http_client: FakeHTTP,
        http_opts: [agent: ctx.http],
        auto_refresh: false,
        name: nil
      )

    # Fail once: the backoff timer fires next, not the 60s interval.
    assert {:error, _} = Refresh.refresh(pid)
    timer = :sys.get_state(pid).timer
    {:ok, ms} = :erlang.read_timer(timer) |> wrap()
    assert ms <= 100
  end

  defp wrap(false), do: :error
  defp wrap(ms) when is_integer(ms), do: {:ok, ms}
end
