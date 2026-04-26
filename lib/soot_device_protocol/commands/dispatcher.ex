defmodule SootDeviceProtocol.Commands.Dispatcher do
  @moduledoc """
  Subscribes to command topics from the contract bundle's
  `commands.json` and routes inbound MQTT messages to operator-supplied
  handlers.

  ## Command spec

  Each command is registered with the dispatcher as a map:

      %{
        name: "reboot",
        topic: "tenants/acme/devices/d1/cmd/reboot",
        payload_format: :json | :binary | :empty,
        qos: 1,
        handler: fn payload, meta -> ... end
      }

  Handlers are arity-2 functions:

      handler(payload, meta) ::
        :ok
        | {:reply, body :: binary()}
        | {:reply, body :: binary(), keyword()}
        | {:error, reason :: term()}

  `meta` is a `%{name: String.t(), command: map(), message: Message.t()}`
  giving the handler access to the request's response_topic /
  correlation_data when it needs to construct its own reply.

  When the handler returns `{:reply, body, opts}` and the inbound
  message had a `response_topic`, the dispatcher publishes the body
  with the same `correlation_data` so the backend's request/response
  correlator can match it.

  ## Payload validation

  `payload_format` is honored as a strict gate before the handler
  fires:

    * `:json`   — `Jason.decode!/1` is run; on parse error the message
                  is rejected with a logged warning, the handler isn't
                  called, and (if reply-able) an error reply is sent.
    * `:binary` — the raw payload binary is passed through unchanged.
    * `:empty`  — the dispatcher requires `payload == <<>>`; non-empty
                  payloads are rejected.
  """

  use GenServer
  require Logger

  alias SootDeviceProtocol.MQTT
  alias SootDeviceProtocol.MQTT.Message

  defmodule State do
    @moduledoc false
    defstruct [:mqtt_client, commands: %{}]
  end

  # ─── client API ──────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register or replace a command at runtime. `command` is the map
  described in the moduledoc.
  """
  @spec register(GenServer.server(), map()) :: :ok | {:error, term()}
  def register(server \\ __MODULE__, command) do
    GenServer.call(server, {:register, command})
  end

  @doc "Drop a command's subscription and handler."
  @spec unregister(GenServer.server(), String.t()) :: :ok
  def unregister(server \\ __MODULE__, name) do
    GenServer.call(server, {:unregister, name})
  end

  @doc "List currently-registered command names."
  @spec list(GenServer.server()) :: [String.t()]
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  # ─── GenServer ──────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    mqtt = Keyword.fetch!(opts, :mqtt_client)
    commands = Keyword.get(opts, :commands, [])

    state = %State{mqtt_client: mqtt}

    state =
      Enum.reduce(commands, state, fn cmd, acc ->
        case do_register(acc, cmd) do
          {:ok, new_state} -> new_state
          {:error, reason} -> raise "invalid command #{inspect(cmd)}: #{inspect(reason)}"
        end
      end)

    {:ok, state}
  end

  @impl true
  def handle_call({:register, cmd}, _from, state) do
    case do_register(state, cmd) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:unregister, name}, _from, state) do
    case Map.pop(state.commands, name) do
      {nil, _} ->
        {:reply, :ok, state}

      {%{topic: topic}, rest} ->
        _ = MQTT.Client.unsubscribe(state.mqtt_client, topic)
        {:reply, :ok, %{state | commands: rest}}
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.keys(state.commands), state}
  end

  @impl true
  def handle_info({:command_inbound, name, %Message{} = msg}, state) do
    case Map.get(state.commands, name) do
      nil ->
        Logger.debug("command_inbound for unregistered #{name}; dropping")
        {:noreply, state}

      command ->
        run_command(state, command, msg)
        {:noreply, state}
    end
  end

  # ─── registration ───────────────────────────────────────────────────

  defp do_register(state, cmd) do
    with {:ok, command} <- normalize(cmd),
         :ok <- subscribe(state.mqtt_client, command) do
      {:ok, %{state | commands: Map.put(state.commands, command.name, command)}}
    end
  end

  defp normalize(cmd) when is_map(cmd) do
    name = Map.get(cmd, :name) || Map.get(cmd, "name")
    topic = Map.get(cmd, :topic) || Map.get(cmd, "topic")
    handler = Map.get(cmd, :handler) || Map.get(cmd, "handler")

    payload_format =
      Map.get(cmd, :payload_format) || Map.get(cmd, "payload_format") || :binary

    qos = Map.get(cmd, :qos) || Map.get(cmd, "qos") || 1

    cond do
      not is_binary(name) -> {:error, :missing_name}
      not is_binary(topic) -> {:error, :missing_topic}
      not is_function(handler, 2) -> {:error, :missing_handler}
      payload_format not in [:json, :binary, :empty] -> {:error, :invalid_payload_format}
      true ->
        {:ok,
         %{
           name: name,
           topic: topic,
           payload_format: payload_format,
           qos: qos,
           handler: handler
         }}
    end
  end

  defp subscribe(client, %{name: name, topic: topic, qos: qos}) do
    me = self()
    handler = fn msg -> send(me, {:command_inbound, name, msg}) end
    MQTT.Client.subscribe(client, topic, qos, handler)
  end

  # ─── execution ──────────────────────────────────────────────────────

  defp run_command(state, command, %Message{} = msg) do
    case validate_payload(command.payload_format, msg.payload) do
      {:ok, payload} ->
        meta = %{name: command.name, command: command, message: msg}
        invoke_handler(state, command, msg, payload, meta)

      {:error, reason} ->
        Logger.warning("command #{command.name} rejected: #{inspect(reason)}")
        publish_reply(state, msg, error_body(reason), [content_type: "application/json"])
    end
  end

  defp validate_payload(:json, payload) do
    case Jason.decode(payload) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp validate_payload(:binary, payload), do: {:ok, payload}

  defp validate_payload(:empty, <<>>), do: {:ok, nil}
  defp validate_payload(:empty, _other), do: {:error, :unexpected_payload}

  defp invoke_handler(state, command, msg, payload, meta) do
    try do
      case command.handler.(payload, meta) do
        :ok ->
          :ok

        {:reply, body} when is_binary(body) ->
          publish_reply(state, msg, body, [])

        {:reply, body, opts} when is_binary(body) and is_list(opts) ->
          publish_reply(state, msg, body, opts)

        {:error, reason} ->
          Logger.warning("command #{command.name} handler error: #{inspect(reason)}")
          publish_reply(state, msg, error_body(reason), content_type: "application/json")

        other ->
          Logger.warning("command #{command.name} handler returned unexpected #{inspect(other)}")
      end
    rescue
      error ->
        Logger.error("command #{command.name} handler raised: #{inspect(error)}")
        publish_reply(state, msg, error_body(:handler_crashed), content_type: "application/json")
    end
  end

  defp publish_reply(_state, %Message{response_topic: nil}, _body, _opts), do: :ok

  defp publish_reply(state, %Message{response_topic: topic, correlation_data: corr}, body, opts) do
    publish_opts = [
      qos: Keyword.get(opts, :qos, 1),
      content_type: Keyword.get(opts, :content_type),
      correlation_data: corr
    ]

    MQTT.Client.publish(state.mqtt_client, topic, body, publish_opts)
  end

  defp error_body(reason) do
    Jason.encode!(%{error: error_code(reason), reason: inspect(reason)})
  end

  defp error_code({:invalid_json, _}), do: "invalid_json"
  defp error_code(:unexpected_payload), do: "unexpected_payload"
  defp error_code(:handler_crashed), do: "handler_crashed"
  defp error_code(_), do: "command_error"
end
