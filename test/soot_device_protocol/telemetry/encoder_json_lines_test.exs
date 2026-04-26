defmodule SootDeviceProtocol.Telemetry.Encoder.JSONLinesTest do
  use ExUnit.Case, async: true

  alias SootDeviceProtocol.Telemetry.Encoder.JSONLines

  test "emits newline-delimited JSON, one row per line" do
    rows = [%{"x" => 1}, %{"x" => 2}]
    {:ok, %{body: body, content_type: ct}} = JSONLines.encode(%{}, rows)

    lines = body |> String.split("\n", trim: true)
    assert length(lines) == 2
    assert Enum.map(lines, &Jason.decode!/1) == rows
    assert ct == "application/x-ndjson"
  end

  test "empty rows produce an empty body" do
    {:ok, %{body: body}} = JSONLines.encode(%{}, [])
    assert body == ""
  end
end
