defmodule SootDeviceProtocol.Supervisor do
  @moduledoc """
  `:rest_for_one` supervisor that brings up the device-side runtime in
  the order required by the spec:

      ├─ Storage              (operator-supplied; not started here)
      ├─ Enrollment           (blocks the rest until we have an op cert)
      ├─ MQTT.Client
      ├─ Contract.Refresh
      ├─ Shadow.Sync          (Phase D2)
      ├─ Commands.Dispatcher  (Phase D2)
      └─ Telemetry.Pipeline   (Phase D3)

  Phase D1 wires Storage / Enrollment / MQTT / Contract.Refresh; the
  shadow / commands / telemetry slots are kept as no-ops here so the
  later phases can drop in without a tree refactor.

  ## Options

    * `:storage`          — `t:SootDeviceProtocol.Storage.binding/0`
                            (required).
    * `:enrollment`       — keyword passed to
                            `SootDeviceProtocol.Enrollment.start_link/1`.
    * `:mqtt`             — keyword passed to
                            `SootDeviceProtocol.MQTT.Client.start_link/1`,
                            or `:disabled` to skip the MQTT process.
    * `:contract_refresh` — keyword passed to
                            `SootDeviceProtocol.Contract.Refresh.start_link/1`,
                            or `:disabled` to skip the refresh poller.
  """

  use Supervisor

  alias SootDeviceProtocol.{Commands, Contract, Enrollment, MQTT, Shadow, Telemetry}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    storage = Keyword.fetch!(opts, :storage)

    enrollment_opts = Keyword.get(opts, :enrollment, []) |> Keyword.put_new(:storage, storage)

    children =
      []
      |> add_child(Enrollment, enrollment_opts)
      |> maybe_add(MQTT.Client, Keyword.get(opts, :mqtt))
      |> maybe_add_with_storage(Contract.Refresh, Keyword.get(opts, :contract_refresh), storage)
      |> maybe_add_with_storage(Shadow.Sync, Keyword.get(opts, :shadow), storage)
      |> maybe_add(Commands.Dispatcher, Keyword.get(opts, :commands))
      |> maybe_add_with_storage(Telemetry.Pipeline, Keyword.get(opts, :telemetry), storage)
      |> Enum.reverse()

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp add_child(acc, mod, opts), do: [{mod, opts} | acc]

  defp maybe_add(acc, _mod, nil), do: acc
  defp maybe_add(acc, _mod, :disabled), do: acc
  defp maybe_add(acc, mod, opts), do: add_child(acc, mod, opts)

  defp maybe_add_with_storage(acc, _mod, nil, _storage), do: acc
  defp maybe_add_with_storage(acc, _mod, :disabled, _storage), do: acc

  defp maybe_add_with_storage(acc, mod, opts, storage) do
    add_child(acc, mod, Keyword.put_new(opts, :storage, storage))
  end
end
