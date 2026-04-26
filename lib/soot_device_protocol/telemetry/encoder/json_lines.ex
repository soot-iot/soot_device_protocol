defmodule SootDeviceProtocol.Telemetry.Encoder.JSONLines do
  @moduledoc """
  Default `SootDeviceProtocol.Telemetry.Encoder` implementation. Emits
  newline-delimited JSON, one row per line, content-type
  `application/x-ndjson`.

  Production deployments using the backend's Arrow-IPC ingest endpoint
  swap this out for an Arrow encoder; this implementation is enough
  for tests and for devices that don't have an Arrow library
  available.
  """

  @behaviour SootDeviceProtocol.Telemetry.Encoder

  @impl true
  def encode(_descriptor, rows) when is_list(rows) do
    body =
      rows
      |> Enum.map_join("\n", &Jason.encode!/1)

    body = if body == "", do: <<>>, else: body <> "\n"

    {:ok, %{body: body, content_type: "application/x-ndjson"}}
  end
end
