defmodule SootDeviceProtocol.Contract.RefreshTest do
  use ExUnit.Case, async: true

  alias SootDeviceProtocol.Contract.{Bundle, Refresh}
  alias SootDeviceProtocol.Storage
  alias SootDeviceProtocol.Storage.Memory
  alias SootDeviceProtocol.Test.{FakeHTTP, PKI}

  @url "https://example.test/.well-known/soot/contract"

  setup do
    {:ok, http} = FakeHTTP.start_link()
    {:ok, storage} = Memory.open()

    ca = PKI.build_ca("/CN=Refresh CA")
    fixture = PKI.build_signed_bundle(ca)

    stub_bundle(http, fixture)

    %{
      http: http,
      storage: storage,
      ca: ca,
      fixture: fixture,
      trust_pems: [ca.cert_pem]
    }
  end

  test "fetches, verifies, and persists the bundle on first refresh", ctx do
    me = self()
    on_change = fn bundle -> send(me, {:change, bundle}) end

    {:ok, pid} =
      Refresh.start_link(
        url: @url,
        storage: ctx.storage,
        trust_pems: ctx.trust_pems,
        on_change: on_change,
        interval_ms: 60_000,
        http_client: FakeHTTP,
        http_opts: [agent: ctx.http],
        auto_refresh: false,
        name: nil
      )

    assert {:ok, :updated} = Refresh.refresh(pid)
    assert_receive {:change, %Bundle{} = bundle}
    assert bundle.fingerprint == ctx.fixture.fingerprint

    assert {:ok, ctx.fixture.fingerprint} == Storage.get(ctx.storage, :contract_fingerprint)
  end

  test "second refresh against the same fingerprint is a no-op", ctx do
    {:ok, pid} =
      Refresh.start_link(
        url: @url,
        storage: ctx.storage,
        trust_pems: ctx.trust_pems,
        interval_ms: 60_000,
        http_client: FakeHTTP,
        http_opts: [agent: ctx.http],
        auto_refresh: false,
        name: nil
      )

    assert {:ok, :updated} = Refresh.refresh(pid)
    assert {:ok, :unchanged} = Refresh.refresh(pid)
  end

  test "verification failure leaves the cached bundle in place", ctx do
    other = PKI.build_ca("/CN=Wrong CA")

    {:ok, pid} =
      Refresh.start_link(
        url: @url,
        storage: ctx.storage,
        trust_pems: [other.cert_pem],
        interval_ms: 60_000,
        http_client: FakeHTTP,
        http_opts: [agent: ctx.http],
        auto_refresh: false,
        name: nil
      )

    assert {:error, :signature_verification_failed} = Refresh.refresh(pid)
    assert :error = Storage.get(ctx.storage, :contract_fingerprint)
  end

  test "force_refresh schedules a refresh asynchronously", ctx do
    me = self()
    on_change = fn bundle -> send(me, {:change, bundle.fingerprint}) end

    {:ok, pid} =
      Refresh.start_link(
        url: @url,
        storage: ctx.storage,
        trust_pems: ctx.trust_pems,
        on_change: on_change,
        interval_ms: 60_000,
        http_client: FakeHTTP,
        http_opts: [agent: ctx.http],
        auto_refresh: false,
        name: nil
      )

    :ok = Refresh.force_refresh(pid)
    assert_receive {:change, fp}, 1_000
    assert fp == ctx.fixture.fingerprint
  end

  defp stub_bundle(http, fixture) do
    FakeHTTP.stub(
      http,
      :get,
      @url,
      {200, [{"content-type", "application/json"}], fixture.manifest_json}
    )

    Enum.each(fixture.assets, fn {path, body} ->
      url = @url <> "/" <> fixture.fingerprint <> "/" <> path

      FakeHTTP.stub(http, :get, url, {200, [{"content-type", "application/json"}], body})
    end)
  end
end
