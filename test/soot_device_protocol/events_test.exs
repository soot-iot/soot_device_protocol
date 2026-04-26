defmodule SootDeviceProtocol.EventsTest do
  use ExUnit.Case, async: true

  alias SootDeviceProtocol.Events

  setup do
    handler_id = make_ref()
    me = self()

    :telemetry.attach_many(
      handler_id,
      [
        [:soot_device_test, :probe, :start],
        [:soot_device_test, :probe, :stop],
        [:soot_device_test, :probe, :exception],
        [:soot_device_test, :event]
      ],
      fn name, measurements, metadata, _config ->
        send(me, {:event, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  test "span emits start and stop with duration_ms and result" do
    Events.span([:soot_device_test, :probe], %{key: "x"}, fn -> :ok end)

    assert_receive {:event, [:soot_device_test, :probe, :start], _, %{key: "x"}}
    assert_receive {:event, [:soot_device_test, :probe, :stop], stop_meas, stop_meta}
    assert is_integer(stop_meas.duration_ms)
    assert stop_meta.result == :ok
  end

  test "span passes through {:ok, value} as the result metadata" do
    Events.span([:soot_device_test, :probe], %{}, fn -> {:ok, :updated} end)

    assert_receive {:event, [:soot_device_test, :probe, :stop], _, meta}
    assert meta.result == {:ok, :updated}
  end

  test "span re-raises and emits :exception" do
    assert_raise RuntimeError, "boom", fn ->
      Events.span([:soot_device_test, :probe], %{}, fn -> raise "boom" end)
    end

    assert_receive {:event, [:soot_device_test, :probe, :exception], _, meta}
    assert %RuntimeError{message: "boom"} = meta.reason
  end

  test "emit/3 publishes a single event" do
    Events.emit([:soot_device_test, :event], %{n: 1}, %{tag: "y"})
    assert_receive {:event, [:soot_device_test, :event], %{n: 1}, %{tag: "y"}}
  end
end
