defmodule SootDeviceProtocol.Shadow.SyncTest do
  use ExUnit.Case, async: true

  alias SootDeviceProtocol.MQTT.{Client, Message}
  alias SootDeviceProtocol.MQTT.Transport.Test, as: TestTransport
  alias SootDeviceProtocol.Shadow.Sync
  alias SootDeviceProtocol.Storage
  alias SootDeviceProtocol.Storage.Memory

  @base "tenants/acme/devices/d1/shadow"

  setup do
    {:ok, mqtt} = Client.start_link(transport: TestTransport, transport_opts: [], name: nil)
    transport = :sys.get_state(mqtt).transport

    {:ok, storage} = Memory.open()

    on_exit(fn ->
      if Process.alive?(mqtt), do: GenServer.stop(mqtt)
    end)

    %{mqtt: mqtt, transport: transport, storage: storage}
  end

  test "subscribes to desired/delta and publishes persisted reported on boot", ctx do
    Storage.put(ctx.storage, :shadow_reported, %{"firmware_version" => "0.4.2"})

    {:ok, _} =
      Sync.start_link(
        base_topic: @base,
        mqtt_client: ctx.mqtt,
        storage: ctx.storage,
        handlers: %{},
        name: nil
      )

    subs = TestTransport.subscriptions(ctx.transport)
    assert MapSet.member?(subs, @base <> "/desired")
    assert MapSet.member?(subs, @base <> "/delta")

    [%Message{topic: topic, payload: payload}] = TestTransport.published(ctx.transport)
    assert topic == @base <> "/reported"
    assert Jason.decode!(payload) == %{"firmware_version" => "0.4.2"}
  end

  test "applies a desired update with no handler by accepting it as-is", ctx do
    {:ok, sync} =
      Sync.start_link(
        base_topic: @base,
        mqtt_client: ctx.mqtt,
        storage: ctx.storage,
        handlers: %{},
        name: nil
      )

    TestTransport.deliver(
      ctx.transport,
      Message.new(@base <> "/desired", Jason.encode!(%{"led" => "on"}))
    )

    Process.sleep(20)

    assert Sync.current(sync) == %{"led" => "on"}
    [%Message{topic: topic, payload: payload}] = TestTransport.published(ctx.transport)
    assert topic == @base <> "/reported"
    assert Jason.decode!(payload) == %{"led" => "on"}
  end

  test "calls a registered handler with previous reported value", ctx do
    me = self()

    handler = fn value, meta ->
      send(me, {:handler_called, value, meta})
      :ok
    end

    {:ok, _} =
      Sync.start_link(
        base_topic: @base,
        mqtt_client: ctx.mqtt,
        storage: ctx.storage,
        handlers: %{"led" => handler},
        name: nil
      )

    TestTransport.deliver(
      ctx.transport,
      Message.new(@base <> "/desired", Jason.encode!(%{"led" => "on"}))
    )

    assert_receive {:handler_called, "on", %{key: "led", source: :desired, reported_value: nil}}
  end

  test "handler returning {:ok, accepted} stores the accepted value", ctx do
    handler = fn value, _meta -> {:ok, String.upcase(value)} end

    {:ok, sync} =
      Sync.start_link(
        base_topic: @base,
        mqtt_client: ctx.mqtt,
        storage: ctx.storage,
        handlers: %{"led" => handler},
        name: nil
      )

    TestTransport.deliver(
      ctx.transport,
      Message.new(@base <> "/desired", Jason.encode!(%{"led" => "on"}))
    )

    Process.sleep(20)
    assert Sync.current(sync) == %{"led" => "ON"}
  end

  test "handler returning {:error, _} leaves the reported state unchanged", ctx do
    handler = fn _value, _meta -> {:error, :rejected} end

    {:ok, sync} =
      Sync.start_link(
        base_topic: @base,
        mqtt_client: ctx.mqtt,
        storage: ctx.storage,
        handlers: %{"led" => handler},
        name: nil
      )

    TestTransport.deliver(
      ctx.transport,
      Message.new(@base <> "/desired", Jason.encode!(%{"led" => "on"}))
    )

    Process.sleep(20)
    assert Sync.current(sync) == %{}

    # No publish since no successful change happened.
    assert TestTransport.published(ctx.transport) == []
  end

  test "delta only reconciles the keys present in the payload", ctx do
    Storage.put(ctx.storage, :shadow_reported, %{"led" => "off", "uptime_s" => 99})

    {:ok, sync} =
      Sync.start_link(
        base_topic: @base,
        mqtt_client: ctx.mqtt,
        storage: ctx.storage,
        handlers: %{},
        name: nil
      )

    TestTransport.deliver(
      ctx.transport,
      Message.new(@base <> "/delta", Jason.encode!(%{"led" => "on"}))
    )

    Process.sleep(20)
    assert Sync.current(sync) == %{"led" => "on", "uptime_s" => 99}
  end

  test "report/3 publishes and persists a side-channel update", ctx do
    {:ok, sync} =
      Sync.start_link(
        base_topic: @base,
        mqtt_client: ctx.mqtt,
        storage: ctx.storage,
        handlers: %{},
        name: nil
      )

    {:ok, _} = Sync.report(sync, :uptime_s, 60)

    assert {:ok, %{"uptime_s" => 60}} = Storage.get(ctx.storage, :shadow_reported)

    [%Message{topic: topic, payload: payload}] = TestTransport.published(ctx.transport)
    assert topic == @base <> "/reported"
    assert Jason.decode!(payload) == %{"uptime_s" => 60}
  end

  test "register_handler/3 lets new handlers attach at runtime", ctx do
    {:ok, sync} =
      Sync.start_link(
        base_topic: @base,
        mqtt_client: ctx.mqtt,
        storage: ctx.storage,
        handlers: %{},
        name: nil
      )

    me = self()

    Sync.register_handler(sync, :sample_rate, fn value, _meta ->
      send(me, {:rate, value})
      :ok
    end)

    TestTransport.deliver(
      ctx.transport,
      Message.new(@base <> "/desired", Jason.encode!(%{"sample_rate" => 100}))
    )

    assert_receive {:rate, 100}
  end
end
