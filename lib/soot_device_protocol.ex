defmodule SootDeviceProtocol do
  @moduledoc """
  Imperative device-side runtime for the Soot framework.

  This package implements the five behaviors a Soot device honors:

  1. **Identity / enrollment** — `SootDeviceProtocol.Enrollment`.
  2. **Contract refresh** — `SootDeviceProtocol.Contract.Refresh`.
  3. **MQTT transport** — `SootDeviceProtocol.MQTT.Client`.
  4. **Shadow sync** — `SootDeviceProtocol.Shadow.Sync` (Phase D2).
  5. **Commands + telemetry** — `SootDeviceProtocol.Commands.Dispatcher`
     and `SootDeviceProtocol.Telemetry.Pipeline` (Phases D2/D3).

  The library is intentionally lean: each component is a supervised
  GenServer with a documented API, and they communicate through those
  APIs rather than shared state.

  See `DEVICE-SPEC.md` in the `soot` repo for the architecture
  rationale and phase plan.
  """
end
