defmodule SootDeviceProtocol.MQTT.MessageTest do
  use ExUnit.Case, async: true

  alias SootDeviceProtocol.MQTT.Message

  describe "new/3" do
    test "fills topic and payload" do
      msg = Message.new("t/x", "hello")
      assert msg.topic == "t/x"
      assert msg.payload == "hello"
    end

    test "defaults qos to 1, retain to false" do
      msg = Message.new("t/x", "")
      assert msg.qos == 1
      assert msg.retain == false
    end

    test "defaults MQTT 5 fields to nil / []" do
      msg = Message.new("t/x", "")
      assert msg.content_type == nil
      assert msg.response_topic == nil
      assert msg.correlation_data == nil
      assert msg.user_properties == []
    end

    test "honours all opts" do
      msg =
        Message.new("t/x", "body",
          qos: 2,
          retain: true,
          content_type: "application/json",
          response_topic: "t/reply",
          correlation_data: <<1, 2, 3>>,
          user_properties: [{"k", "v"}]
        )

      assert %Message{
               qos: 2,
               retain: true,
               content_type: "application/json",
               response_topic: "t/reply",
               correlation_data: <<1, 2, 3>>,
               user_properties: [{"k", "v"}]
             } = msg
    end
  end
end
