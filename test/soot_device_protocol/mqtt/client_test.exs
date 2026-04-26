defmodule SootDeviceProtocol.MQTT.ClientTest do
  use ExUnit.Case, async: true

  alias SootDeviceProtocol.MQTT.{Client, Message}
  alias SootDeviceProtocol.MQTT.Transport.Test, as: TestTransport

  setup do
    {:ok, pid} =
      Client.start_link(
        transport: TestTransport,
        transport_opts: [],
        name: nil
      )

    transport = :sys.get_state(pid).transport

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    %{client: pid, transport: transport}
  end

  test "publish/4 forwards through the transport", %{client: client, transport: transport} do
    Client.publish(client, "tenants/acme/devices/d1/reported", "hello", qos: 1)
    [%Message{topic: "tenants/acme/devices/d1/reported", payload: "hello", qos: 1}] =
      TestTransport.published(transport)
  end

  test "subscribe/4 records the filter and routes inbound messages", %{client: client, transport: transport} do
    me = self()
    handler = fn msg -> send(me, {:got, msg.topic, msg.payload}) end

    :ok = Client.subscribe(client, "tenants/+/devices/+/cmd/reboot", 1, handler)
    assert MapSet.member?(TestTransport.subscriptions(transport), "tenants/+/devices/+/cmd/reboot")

    TestTransport.deliver(
      transport,
      Message.new("tenants/acme/devices/d1/cmd/reboot", "now")
    )

    assert_receive {:got, "tenants/acme/devices/d1/cmd/reboot", "now"}, 500
  end

  test "two handlers may match the same incoming topic", %{client: client, transport: transport} do
    me = self()
    Client.subscribe(client, "a/+", 0, fn msg -> send(me, {:a, msg.payload}) end)
    Client.subscribe(client, "+/b", 0, fn msg -> send(me, {:b, msg.payload}) end)

    TestTransport.deliver(transport, Message.new("a/b", "hit"))

    assert_receive {:a, "hit"}, 500
    assert_receive {:b, "hit"}, 500
  end

  test "unsubscribe/2 stops the handler from firing", %{client: client, transport: transport} do
    me = self()
    Client.subscribe(client, "drop/me", 0, fn msg -> send(me, {:got, msg.payload}) end)
    :ok = Client.unsubscribe(client, "drop/me")

    assert "drop/me" in TestTransport.unsubscribed(transport)

    TestTransport.deliver(transport, Message.new("drop/me", "ignored"))
    refute_receive {:got, _}, 100
  end

  test "topic_matches?/2 honors wildcards" do
    assert Client.topic_matches?("a/+/c", "a/b/c")
    assert Client.topic_matches?("a/#", "a/b/c/d")
    refute Client.topic_matches?("a/+", "a/b/c")
    refute Client.topic_matches?("a/b", "a/c")
  end
end
