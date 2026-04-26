defmodule SootDeviceProtocol.MQTT.Transport do
  @moduledoc """
  Behavior every MQTT transport implements.

  The device-side runtime client (`SootDeviceProtocol.MQTT.Client`)
  calls these in the abstract; concrete implementations are:

    * `SootDeviceProtocol.MQTT.Transport.EMQTT` — production, talks to
      a real broker via `:emqtt`.
    * `SootDeviceProtocol.MQTT.Transport.Test` — in-memory; records
      calls and lets tests inject incoming messages.

  Connect to the broker, publish/subscribe under MQTT 5 semantics, and
  forward incoming messages to the owning process as
  `{:soot_mqtt_msg, %SootDeviceProtocol.MQTT.Message{}}`.
  """

  alias SootDeviceProtocol.MQTT.Message

  @type state :: any()

  @callback connect(opts :: keyword(), owner :: pid()) :: {:ok, state()} | {:error, term()}
  @callback publish(state(), Message.t()) :: :ok | {:error, term()}
  @callback subscribe(state(), topic_filter :: String.t(), qos :: 0 | 1 | 2) ::
              :ok | {:error, term()}
  @callback unsubscribe(state(), topic_filter :: String.t()) :: :ok | {:error, term()}
  @callback disconnect(state()) :: :ok
end
