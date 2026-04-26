defmodule SootDeviceProtocol.Telemetry.Encoder do
  @moduledoc """
  Behavior for the on-the-wire batch encoder. The pipeline's default
  encoder (`SootDeviceProtocol.Telemetry.Encoder.JSONLines`) emits
  newline-delimited JSON; production deployments swap in an Arrow IPC
  encoder (the format the backend's `Plug.Ingest` is expecting).

  The behavior is intentionally minimal so a per-target encoder can
  decide its own packaging and content type:

      @callback encode(stream_descriptor :: map(), rows :: [map()]) ::
                  {:ok, %{body: binary(), content_type: String.t()}} | {:error, term()}

  `stream_descriptor` is the bundle entry for the stream — schema
  fingerprint, schema descriptor, etc.
  """

  @callback encode(stream_descriptor :: map(), rows :: [map()]) ::
              {:ok, %{body: binary(), content_type: String.t()}} | {:error, term()}
end
