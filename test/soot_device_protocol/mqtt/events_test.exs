defmodule SootDeviceProtocol.MQTT.EventsTest do
  use ExUnit.Case, async: true

  alias SootDeviceProtocol.MQTT.{Client, Message}
  alias SootDeviceProtocol.MQTT.Transport.Test, as: TestTransport

  setup do
    handler_id = make_ref()
    me = self()

    :telemetry.attach_many(
      handler_id,
      [
        [:soot_device, :mqtt, :connect],
        [:soot_device, :mqtt, :disconnect],
        [:soot_device, :mqtt, :publish],
        [:soot_device, :mqtt, :subscribe],
        [:soot_device, :mqtt, :unsubscribe],
        [:soot_device, :mqtt, :inbound]
      ],
      fn name, measurements, metadata, _ ->
        send(me, {:event, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, mqtt} = Client.start_link(transport: TestTransport, transport_opts: [], name: nil)
    transport = :sys.get_state(mqtt).transport

    on_exit(fn ->
      if Process.alive?(mqtt), do: GenServer.stop(mqtt)
    end)

    %{client: mqtt, transport: transport}
  end

  test "connect emits :connect event", %{client: _client} do
    assert_received {:event, [:soot_device, :mqtt, :connect], _, %{transport: _}}
  end

  test "publish emits :publish with bytes + topic", %{client: client} do
    Client.publish(client, "topic/x", "hello")
    assert_receive {:event, [:soot_device, :mqtt, :publish], %{bytes: 5},
                    %{topic: "topic/x", qos: 1}}
  end

  test "subscribe / unsubscribe emit events", %{client: client} do
    Client.subscribe(client, "topic/+", 1, fn _ -> :ok end)
    assert_receive {:event, [:soot_device, :mqtt, :subscribe], _, %{filter: "topic/+", qos: 1}}

    Client.unsubscribe(client, "topic/+")
    assert_receive {:event, [:soot_device, :mqtt, :unsubscribe], _, %{filter: "topic/+"}}
  end

  test "inbound emits :inbound with bytes + topic", %{client: client, transport: transport} do
    Client.subscribe(client, "topic/+", 0, fn _ -> :ok end)
    TestTransport.deliver(transport, Message.new("topic/x", "abc"))
    assert_receive {:event, [:soot_device, :mqtt, :inbound], %{bytes: 3}, %{topic: "topic/x"}}
  end
end
