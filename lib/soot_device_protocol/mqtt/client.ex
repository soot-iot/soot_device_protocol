defmodule SootDeviceProtocol.MQTT.Client do
  @moduledoc """
  Device-side MQTT client. GenServer that owns a transport, dispatches
  inbound messages to subscribed handlers, and exposes a small API
  matching the spec's `connect / disconnect / publish / subscribe`
  surface.

  The transport is pluggable: in production it's
  `SootDeviceProtocol.MQTT.Transport.EMQTT`; in tests it's
  `SootDeviceProtocol.MQTT.Transport.Test`.

  Inbound publishes are routed to handlers registered with
  `subscribe/4`. Handlers are arity-1 functions of an
  `SootDeviceProtocol.MQTT.Message`. They run in the client's process,
  so any work that may block (storage writes, HTTP calls) belongs in a
  separately-supervised process the handler hands off to.

  Reconnect / backoff is the operator's job — wrap this GenServer in a
  `Supervisor` with whatever policy fits the target.
  """

  use GenServer
  require Logger

  alias SootDeviceProtocol.MQTT.Message

  defmodule State do
    @moduledoc false
    defstruct [:transport_mod, :transport, handlers: []]
  end

  @type t :: GenServer.server()

  # ─── client API ──────────────────────────────────────────────────────

  @doc """
  Start the client.

  Required:
    * `:transport`      — module implementing
      `SootDeviceProtocol.MQTT.Transport`.
    * `:transport_opts` — keyword forwarded to `connect/2`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Stop the client and disconnect the transport."
  @spec disconnect(t()) :: :ok
  def disconnect(server \\ __MODULE__), do: GenServer.stop(server)

  @doc "Publish a message; fire and forget."
  @spec publish(t(), String.t(), binary(), keyword()) :: :ok | {:error, term()}
  def publish(server \\ __MODULE__, topic, payload, opts \\ []) do
    GenServer.call(server, {:publish, Message.new(topic, payload, opts)})
  end

  @doc """
  Subscribe to `filter` and route incoming messages to `handler`. The
  handler is `(message -> any())`.
  """
  @spec subscribe(t(), String.t(), 0 | 1 | 2, (Message.t() -> any())) :: :ok | {:error, term()}
  def subscribe(server \\ __MODULE__, filter, qos, handler) when is_function(handler, 1) do
    GenServer.call(server, {:subscribe, filter, qos, handler})
  end

  @doc "Unsubscribe and drop the matching handler."
  @spec unsubscribe(t(), String.t()) :: :ok | {:error, term()}
  def unsubscribe(server \\ __MODULE__, filter) do
    GenServer.call(server, {:unsubscribe, filter})
  end

  # ─── GenServer ──────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    transport_mod = Keyword.fetch!(opts, :transport)
    transport_opts = Keyword.get(opts, :transport_opts, [])

    case transport_mod.connect(transport_opts, self()) do
      {:ok, transport} ->
        {:ok, %State{transport_mod: transport_mod, transport: transport}}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def handle_call({:publish, %Message{} = msg}, _from, state) do
    {:reply, state.transport_mod.publish(state.transport, msg), state}
  end

  def handle_call({:subscribe, filter, qos, handler}, _from, state) do
    case state.transport_mod.subscribe(state.transport, filter, qos) do
      :ok ->
        handlers = put_handler(state.handlers, filter, handler)
        {:reply, :ok, %{state | handlers: handlers}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:unsubscribe, filter}, _from, state) do
    case state.transport_mod.unsubscribe(state.transport, filter) do
      :ok ->
        handlers = Enum.reject(state.handlers, fn {f, _} -> f == filter end)
        {:reply, :ok, %{state | handlers: handlers}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_info({:soot_mqtt_msg, %Message{} = msg}, state) do
    route(msg, state.handlers)
    {:noreply, state}
  end

  def handle_info({:soot_mqtt_disconnect, reason}, state) do
    Logger.warning("soot_device_protocol mqtt transport disconnected: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.transport, do: state.transport_mod.disconnect(state.transport)
    :ok
  end

  # ─── routing ────────────────────────────────────────────────────────

  defp route(%Message{topic: topic} = msg, handlers) do
    handlers
    |> Enum.filter(fn {filter, _} -> topic_matches?(filter, topic) end)
    |> Enum.each(fn {_filter, handler} -> safe_call(handler, msg) end)
  end

  defp put_handler(handlers, filter, handler) do
    case Enum.split_with(handlers, fn {f, _} -> f == filter end) do
      {[], rest} -> [{filter, handler} | rest]
      {_existing, rest} -> [{filter, handler} | rest]
    end
  end

  defp safe_call(handler, msg) do
    handler.(msg)
  rescue
    error ->
      Logger.error("soot_device_protocol mqtt handler raised: #{inspect(error)}")
      :error
  end

  @doc """
  MQTT topic-filter wildcard match: `+` matches one segment, `#`
  matches the rest. Exposed for components that route by filter
  themselves (e.g. the commands dispatcher).
  """
  @spec topic_matches?(String.t(), String.t()) :: boolean()
  def topic_matches?(filter, topic) do
    do_match(String.split(filter, "/"), String.split(topic, "/"))
  end

  defp do_match([], []), do: true
  defp do_match(["#" | _], _rest), do: true
  defp do_match(["+" | f_rest], [_ | t_rest]), do: do_match(f_rest, t_rest)
  defp do_match([same | f_rest], [same | t_rest]), do: do_match(f_rest, t_rest)
  defp do_match(_, _), do: false
end
