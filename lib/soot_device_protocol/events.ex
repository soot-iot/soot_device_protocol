defmodule SootDeviceProtocol.Events do
  @moduledoc """
  Catalog of `:telemetry` events emitted by the device runtime.

  Every event below is published as `:telemetry.execute(event,
  measurements, metadata)`. Operators wire these to whatever metrics
  / logging backend they prefer; the device library itself does not
  attach any handlers.

  ## Enrollment

    * `[:soot_device, :enrollment, :start]`  — measurements: `%{}`,
       metadata: `%{enroll_url: String.t(), serial: term()}`.
    * `[:soot_device, :enrollment, :stop]`   — measurements:
       `%{duration_ms: integer()}`, metadata adds `:result`
       (`:ok | {:error, term()}`).

  ## Contract refresh

    * `[:soot_device, :contract, :refresh, :start]`  — `%{}`, `%{url: String.t()}`.
    * `[:soot_device, :contract, :refresh, :stop]`   —
      `%{duration_ms: integer()}`, metadata adds `:result`
      (`:unchanged | :updated | {:error, term()}`).

  ## MQTT

    * `[:soot_device, :mqtt, :connect]`     — `%{}`, `%{transport: module()}`.
    * `[:soot_device, :mqtt, :disconnect]`  — `%{}`, `%{reason: term()}`.
    * `[:soot_device, :mqtt, :publish]`     — `%{bytes: integer()}`,
      `%{topic: String.t(), qos: 0..2}`.
    * `[:soot_device, :mqtt, :subscribe]`   — `%{}`,
      `%{filter: String.t(), qos: 0..2}`.
    * `[:soot_device, :mqtt, :unsubscribe]` — `%{}`, `%{filter: String.t()}`.
    * `[:soot_device, :mqtt, :inbound]`     — `%{bytes: integer()}`,
      `%{topic: String.t()}`.

  ## Telemetry pipeline

    * `[:soot_device, :pipeline, :write]`   — `%{bytes: integer()}`,
      `%{stream: String.t(), seq: integer()}`.
    * `[:soot_device, :pipeline, :flush, :start]` — `%{}`, `%{stream: String.t()}`.
    * `[:soot_device, :pipeline, :flush, :stop]` —
      `%{duration_ms: integer(), rows: integer(), bytes: integer()}`,
      `%{stream: String.t(), result: term()}`.
  """

  @doc """
  Emit a `[..., :start]` / `[..., :stop]` pair around `fun`. The stop
  event includes a `:duration_ms` measurement and a `:result` metadata
  key set to whatever `fun` returns (or `{:exception, kind, reason}`
  if it raised).
  """
  @spec span([atom()], map(), (-> result)) :: result when result: term()
  def span(prefix, metadata, fun) when is_list(prefix) and is_map(metadata) do
    start = System.monotonic_time()
    :telemetry.execute(prefix ++ [:start], %{system_time: System.system_time()}, metadata)

    try do
      result = fun.()
      stop_metadata = Map.put(metadata, :result, summarize_result(result))
      duration_ms = duration_ms(start)

      :telemetry.execute(prefix ++ [:stop], %{duration_ms: duration_ms}, stop_metadata)
      result
    rescue
      e ->
        duration_ms = duration_ms(start)

        :telemetry.execute(
          prefix ++ [:exception],
          %{duration_ms: duration_ms},
          Map.merge(metadata, %{kind: :error, reason: e, stacktrace: __STACKTRACE__})
        )

        reraise e, __STACKTRACE__
    end
  end

  @doc "Plain `:telemetry.execute` wrapper for fire-and-forget events."
  @spec emit([atom()], map(), map()) :: :ok
  def emit(name, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute(name, measurements, metadata)
  end

  defp duration_ms(start) do
    diff = System.monotonic_time() - start
    System.convert_time_unit(diff, :native, :millisecond)
  end

  defp summarize_result(:ok), do: :ok
  defp summarize_result({:ok, value}), do: {:ok, value}
  defp summarize_result({:error, _} = err), do: err
  defp summarize_result(other), do: other
end
