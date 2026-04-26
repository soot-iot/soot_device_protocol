defmodule SootDeviceProtocol.MQTT.Transport.Test do
  @moduledoc """
  In-memory MQTT transport for tests. Records every publish/subscribe
  call on an Agent and exposes `deliver/2` to simulate an inbound
  message from the broker.

  Mirrors `AshMqtt.Runtime.Transport.Test` from the backend so
  test-doubles look familiar across the framework.
  """

  @behaviour SootDeviceProtocol.MQTT.Transport

  alias SootDeviceProtocol.MQTT.Message

  defstruct [:agent, :owner]

  @type t :: %__MODULE__{agent: pid(), owner: pid()}

  @impl true
  def connect(_opts, owner) when is_pid(owner) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{published: [], subscribed: MapSet.new(), unsubscribed: []}
      end)

    {:ok, %__MODULE__{agent: agent, owner: owner}}
  end

  @impl true
  def publish(%__MODULE__{agent: agent}, %Message{} = message) do
    Agent.update(agent, fn state ->
      %{state | published: state.published ++ [message]}
    end)

    :ok
  end

  @impl true
  def subscribe(%__MODULE__{agent: agent}, filter, _qos) do
    Agent.update(agent, fn state ->
      %{state | subscribed: MapSet.put(state.subscribed, filter)}
    end)

    :ok
  end

  @impl true
  def unsubscribe(%__MODULE__{agent: agent}, filter) do
    Agent.update(agent, fn state ->
      %{
        state
        | subscribed: MapSet.delete(state.subscribed, filter),
          unsubscribed: state.unsubscribed ++ [filter]
      }
    end)

    :ok
  end

  @impl true
  def disconnect(%__MODULE__{agent: agent}) do
    Agent.stop(agent)
    :ok
  end

  # ─── test helpers ─────────────────────────────────────────────────────

  @doc "Inject an incoming message; the runtime client receives it via the owner."
  @spec deliver(t(), Message.t()) :: :ok
  def deliver(%__MODULE__{owner: owner}, %Message{} = msg) do
    send(owner, {:soot_mqtt_msg, msg})
    :ok
  end

  @doc "Every message published through this transport, in order."
  @spec published(t()) :: [Message.t()]
  def published(%__MODULE__{agent: agent}) do
    Agent.get(agent, & &1.published)
  end

  @doc "Topic filters this transport is currently subscribed to."
  @spec subscriptions(t()) :: MapSet.t(String.t())
  def subscriptions(%__MODULE__{agent: agent}) do
    Agent.get(agent, & &1.subscribed)
  end

  @doc "Topic filters this transport has unsubscribed from since connect."
  @spec unsubscribed(t()) :: [String.t()]
  def unsubscribed(%__MODULE__{agent: agent}) do
    Agent.get(agent, & &1.unsubscribed)
  end
end
