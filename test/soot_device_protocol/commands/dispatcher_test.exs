defmodule SootDeviceProtocol.Commands.DispatcherTest do
  use ExUnit.Case, async: true

  alias SootDeviceProtocol.Commands.Dispatcher
  alias SootDeviceProtocol.MQTT.{Client, Message}
  alias SootDeviceProtocol.MQTT.Transport.Test, as: TestTransport

  setup do
    {:ok, mqtt} = Client.start_link(transport: TestTransport, transport_opts: [], name: nil)
    transport = :sys.get_state(mqtt).transport

    on_exit(fn ->
      try do
        GenServer.stop(mqtt)
      catch
        :exit, _ -> :ok
      end
    end)

    %{mqtt: mqtt, transport: transport}
  end

  defp wait_for_publishes(transport, count, deadline \\ 1_000) do
    end_time = System.monotonic_time(:millisecond) + deadline
    do_wait_for_publishes(transport, count, end_time)
  end

  defp do_wait_for_publishes(transport, count, end_time) do
    case TestTransport.published(transport) do
      list when length(list) >= count ->
        list

      _ ->
        if System.monotonic_time(:millisecond) >= end_time do
          flunk(
            "timed out waiting for #{count} publish(es); got #{inspect(TestTransport.published(transport))}"
          )
        else
          Process.sleep(5)
          do_wait_for_publishes(transport, count, end_time)
        end
    end
  end

  test "subscribes to commands listed in the start_link opts", ctx do
    {:ok, _} =
      Dispatcher.start_link(
        mqtt_client: ctx.mqtt,
        commands: [
          %{
            name: "reboot",
            topic: "tenants/acme/devices/d1/cmd/reboot",
            payload_format: :empty,
            handler: fn _payload, _meta -> :ok end
          }
        ],
        name: nil
      )

    subs = TestTransport.subscriptions(ctx.transport)
    assert MapSet.member?(subs, "tenants/acme/devices/d1/cmd/reboot")
  end

  test "calls the handler on a matching inbound publish", ctx do
    me = self()

    {:ok, _disp} =
      Dispatcher.start_link(
        mqtt_client: ctx.mqtt,
        commands: [
          %{
            name: "reboot",
            topic: "cmd/reboot",
            payload_format: :empty,
            handler: fn payload, meta ->
              send(me, {:called, payload, meta.name})
              :ok
            end
          }
        ],
        name: nil
      )

    TestTransport.deliver(ctx.transport, Message.new("cmd/reboot", <<>>))
    assert_receive {:called, nil, "reboot"}
  end

  test "publishes a reply to response_topic with the same correlation_data", ctx do
    {:ok, _disp} =
      Dispatcher.start_link(
        mqtt_client: ctx.mqtt,
        commands: [
          %{
            name: "read_config",
            topic: "cmd/read_config",
            payload_format: :empty,
            handler: fn _payload, _meta ->
              {:reply, Jason.encode!(%{"firmware" => "0.4.2"}), content_type: "application/json"}
            end
          }
        ],
        name: nil
      )

    TestTransport.deliver(
      ctx.transport,
      Message.new("cmd/read_config", <<>>,
        response_topic: "_replies/req-001",
        correlation_data: <<"corr">>
      )
    )

    [%Message{topic: topic, payload: payload, correlation_data: corr, content_type: ct}] =
      wait_for_publishes(ctx.transport, 1)

    assert topic == "_replies/req-001"
    assert Jason.decode!(payload) == %{"firmware" => "0.4.2"}
    assert corr == <<"corr">>
    assert ct == "application/json"
  end

  test "rejects malformed JSON before invoking the handler", ctx do
    me = self()

    {:ok, _disp} =
      Dispatcher.start_link(
        mqtt_client: ctx.mqtt,
        commands: [
          %{
            name: "configure",
            topic: "cmd/configure",
            payload_format: :json,
            handler: fn _, _ ->
              send(me, :handler_called)
              :ok
            end
          }
        ],
        name: nil
      )

    TestTransport.deliver(
      ctx.transport,
      Message.new("cmd/configure", "}{not json",
        response_topic: "_replies/req-002",
        correlation_data: <<"x">>
      )
    )

    [%Message{topic: "_replies/req-002", payload: payload}] = wait_for_publishes(ctx.transport, 1)

    refute_received :handler_called
    assert Jason.decode!(payload)["error"] == "invalid_json"
  end

  test "rejects an :empty command with payload", ctx do
    me = self()

    {:ok, _disp} =
      Dispatcher.start_link(
        mqtt_client: ctx.mqtt,
        commands: [
          %{
            name: "ping",
            topic: "cmd/ping",
            payload_format: :empty,
            handler: fn _, _ ->
              send(me, :handler_called)
              :ok
            end
          }
        ],
        name: nil
      )

    TestTransport.deliver(ctx.transport, Message.new("cmd/ping", "garbage"))
    Process.sleep(20)
    refute_received :handler_called
  end

  test "register/2 installs a command at runtime", ctx do
    me = self()

    {:ok, disp} = Dispatcher.start_link(mqtt_client: ctx.mqtt, name: nil)

    :ok =
      Dispatcher.register(disp, %{
        name: "later",
        topic: "cmd/later",
        payload_format: :binary,
        handler: fn payload, _meta ->
          send(me, {:got, payload})
          :ok
        end
      })

    assert ["later"] = Dispatcher.list(disp)

    TestTransport.deliver(ctx.transport, Message.new("cmd/later", "hi"))
    assert_receive {:got, "hi"}
  end

  test "unregister/2 stops dispatching for a command", ctx do
    me = self()

    {:ok, disp} =
      Dispatcher.start_link(
        mqtt_client: ctx.mqtt,
        commands: [
          %{
            name: "drop",
            topic: "cmd/drop",
            payload_format: :binary,
            handler: fn _, _ ->
              send(me, :still_alive)
              :ok
            end
          }
        ],
        name: nil
      )

    :ok = Dispatcher.unregister(disp, "drop")
    assert "cmd/drop" in TestTransport.unsubscribed(ctx.transport)

    TestTransport.deliver(ctx.transport, Message.new("cmd/drop", "ignored"))
    Process.sleep(20)
    refute_received :still_alive
  end

  test "rejects malformed command spec", ctx do
    {:ok, disp} = Dispatcher.start_link(mqtt_client: ctx.mqtt, name: nil)
    assert {:error, :missing_handler} = Dispatcher.register(disp, %{name: "x", topic: "t"})
  end
end
