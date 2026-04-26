defmodule SootDeviceProtocol.MQTT.Message do
  @moduledoc """
  Plain MQTT-5-shaped message struct used by the device's MQTT
  transport and client. Mirrors `AshMqtt.Runtime.Message` so devices
  and the backend share a wire-level vocabulary without having to share
  an Elixir dependency.
  """

  defstruct [
    :topic,
    :payload,
    :qos,
    :retain,
    :content_type,
    :response_topic,
    :correlation_data,
    :user_properties
  ]

  @type t :: %__MODULE__{
          topic: String.t(),
          payload: binary(),
          qos: 0 | 1 | 2,
          retain: boolean(),
          content_type: String.t() | nil,
          response_topic: String.t() | nil,
          correlation_data: binary() | nil,
          user_properties: [{String.t(), String.t()}]
        }

  @spec new(String.t(), binary(), keyword()) :: t()
  def new(topic, payload, opts \\ []) do
    %__MODULE__{
      topic: topic,
      payload: payload,
      qos: Keyword.get(opts, :qos, 1),
      retain: Keyword.get(opts, :retain, false),
      content_type: Keyword.get(opts, :content_type),
      response_topic: Keyword.get(opts, :response_topic),
      correlation_data: Keyword.get(opts, :correlation_data),
      user_properties: Keyword.get(opts, :user_properties, [])
    }
  end
end
