defmodule SootDeviceProtocol.Shadow.Sync do
  @moduledoc """
  Reconciles the device's shadow with the backend's view of it.

  ## Topics

      <base>/desired   — full desired state from backend.
      <base>/delta     — explicit per-key delta the backend wants applied.
      <base>/reported  — what the device says about itself.

  ## Lifecycle

    1. On `init/1` the GenServer reads the persisted reported state from
       storage (`:shadow_reported`) — defaulting to `%{}` — subscribes
       to `<base>/desired` and `<base>/delta`, and publishes
       `<base>/reported` with the persisted state so the backend's view
       converges immediately.

    2. On a `<base>/desired` message, the server diffs the incoming
       desired map against `reported` and calls the configured handler
       for every changed top-level key. Each handler runs as
       `(value, meta) -> {:ok, accepted_value} | :ok | {:error, term}`.
       Successful handler returns are merged into the reported map and
       persisted; error returns leave the reported map unchanged.

    3. `<base>/delta` works the same way, except only the keys present
       in the delta payload are reconciled.

    4. `report/3` is the side-channel for code outside the shadow loop
       (e.g. an uptime ticker) to push reported state.

  ## Handler contract

  Handlers are arity-2 functions: `(value, meta) -> result`.

    * `value` — the desired value for the key.
    * `meta`  — `%{key: atom_or_string, source: :desired | :delta,
                   reported_value: term}`.

    * `:ok`                — apply `value` as-is to the reported state.
    * `{:ok, accepted}`    — apply `accepted` instead.
    * `{:error, reason}`   — leave the reported state untouched and log.

  Keys with no registered handler are accepted as-is (they round-trip
  back to the backend in the next reported publish). This matches the
  spec's "operator-supplied handlers" rule: a missing handler isn't an
  error, it's the no-op case.

  ## Payload format

  All shadow payloads are JSON objects.
  """

  use GenServer
  require Logger

  alias SootDeviceProtocol.{MQTT, Storage}
  alias SootDeviceProtocol.MQTT.Message

  @reported_key :shadow_reported

  defmodule State do
    @moduledoc false
    defstruct [
      :base_topic,
      :mqtt_client,
      :storage,
      :qos,
      :retain,
      handlers: %{},
      reported: %{}
    ]
  end

  # ─── client API ──────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Read the device's current view of reported state."
  @spec current(GenServer.server()) :: map()
  def current(server \\ __MODULE__), do: GenServer.call(server, :current)

  @doc """
  Push a reported-state update for `key`. Persists, publishes to
  `<base>/reported`, and returns the new reported map.
  """
  @spec report(GenServer.server(), atom() | String.t(), term()) :: {:ok, map()} | {:error, term()}
  def report(server \\ __MODULE__, key, value),
    do: GenServer.call(server, {:report, key, value})

  @doc "Register or replace the handler function for `key` at runtime."
  @spec register_handler(GenServer.server(), atom() | String.t(), (term(), map() -> any())) :: :ok
  def register_handler(server \\ __MODULE__, key, handler) when is_function(handler, 2) do
    GenServer.call(server, {:register_handler, key, handler})
  end

  # ─── GenServer ──────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    base = Keyword.fetch!(opts, :base_topic)
    mqtt = Keyword.fetch!(opts, :mqtt_client)
    storage = Keyword.fetch!(opts, :storage)

    handlers = Keyword.get(opts, :handlers, %{}) |> Map.new()
    qos = Keyword.get(opts, :qos, 1)
    retain = Keyword.get(opts, :retain, false)

    reported = load_reported(storage)

    state = %State{
      base_topic: base,
      mqtt_client: mqtt,
      storage: storage,
      qos: qos,
      retain: retain,
      handlers: handlers,
      reported: reported
    }

    :ok = subscribe_topics(state)

    if Keyword.get(opts, :publish_on_boot?, true) and reported != %{} do
      publish_reported(state)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:current, _from, state), do: {:reply, state.reported, state}

  def handle_call({:report, key, value}, _from, state) do
    new_reported = Map.put(state.reported, normalize_key(key), value)
    state = persist(%{state | reported: new_reported})
    publish_reported(state)
    {:reply, {:ok, state.reported}, state}
  end

  def handle_call({:register_handler, key, handler}, _from, state) do
    handlers = Map.put(state.handlers, normalize_key(key), handler)
    {:reply, :ok, %{state | handlers: handlers}}
  end

  @impl true
  def handle_info({:shadow_inbound, source, %Message{} = msg}, state) do
    {:noreply, apply_inbound(state, source, msg)}
  end

  # ─── reconcile flow ─────────────────────────────────────────────────

  defp apply_inbound(state, source, %Message{payload: payload}) do
    case Jason.decode(payload) do
      {:ok, map} when is_map(map) ->
        reconcile(state, source, map)

      {:ok, _} ->
        Logger.warning("shadow #{source} payload was not a JSON object; ignored")
        state

      {:error, reason} ->
        Logger.warning("shadow #{source} payload was not JSON: #{inspect(reason)}")
        state
    end
  end

  defp reconcile(state, source, incoming) do
    {accepted, errors} =
      incoming
      |> Enum.reduce({state.reported, []}, fn {key, value}, {acc, errs} ->
        norm = normalize_key(key)
        meta = %{key: norm, source: source, reported_value: Map.get(acc, norm)}

        case run_handler(state.handlers, norm, value, meta) do
          {:keep, accepted_value} ->
            {Map.put(acc, norm, accepted_value), errs}

          {:reject, reason} ->
            {acc, [{norm, reason} | errs]}
        end
      end)

    if errors != [] do
      Logger.warning("shadow #{source} handler errors: #{inspect(errors)}")
    end

    if accepted == state.reported do
      state
    else
      state = persist(%{state | reported: accepted})
      publish_reported(state)
      state
    end
  end

  defp run_handler(handlers, key, value, meta) do
    case Map.get(handlers, key) do
      nil ->
        {:keep, value}

      fun when is_function(fun, 2) ->
        try do
          case fun.(value, meta) do
            :ok -> {:keep, value}
            {:ok, accepted} -> {:keep, accepted}
            {:error, reason} -> {:reject, reason}
          end
        rescue
          error -> {:reject, error}
        end
    end
  end

  defp persist(state) do
    case Storage.put(state.storage, @reported_key, state.reported) do
      :ok ->
        state

      {:error, reason} ->
        Logger.warning("shadow persist failed: #{inspect(reason)}")
        state
    end
  end

  defp publish_reported(state) do
    payload = Jason.encode!(state.reported)
    topic = state.base_topic <> "/reported"

    MQTT.Client.publish(state.mqtt_client, topic, payload, qos: state.qos, retain: state.retain)
  end

  defp subscribe_topics(state) do
    me = self()

    desired_handler = fn msg -> send(me, {:shadow_inbound, :desired, msg}) end
    delta_handler = fn msg -> send(me, {:shadow_inbound, :delta, msg}) end

    :ok =
      MQTT.Client.subscribe(
        state.mqtt_client,
        state.base_topic <> "/desired",
        state.qos,
        desired_handler
      )

    :ok =
      MQTT.Client.subscribe(
        state.mqtt_client,
        state.base_topic <> "/delta",
        state.qos,
        delta_handler
      )

    :ok
  end

  defp load_reported(storage) do
    case Storage.get(storage, @reported_key) do
      {:ok, value} when is_map(value) -> value
      _ -> %{}
    end
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
end
