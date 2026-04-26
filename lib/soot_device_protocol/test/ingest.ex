defmodule SootDeviceProtocol.Test.Ingest do
  @moduledoc """
  In-memory `Plug` that mimics the backend's
  `SootTelemetry.Plug.Ingest`.

  Tests bring up this plug via `start/0`, mount it under a Plug router
  (or wrap it via `Plug.Adapters.Cowboy`) and point their device at it.
  Every successful batch is recorded so the test can assert on what
  was uploaded; rejection rules can be configured per stream to
  exercise the device's contract-mismatch / sequence-regression paths.

  ## Behavior

  Defaults: every `POST /ingest/<stream>` returns `204 No Content` and
  appends an entry to the recorder's `:batches` list.

  Per-stream overrides via `set_response/3`:

    * `{:ok, status}` — return `status` (default 204).
    * `{:fingerprint_mismatch, expected}` — 409 with the matching
      hint body the real backend serves.
    * `{:stream_retired}` — 410.

  ## Recorded shape

      %{
        stream: "vibration",
        body: <bytes>,
        headers: [{"x-stream", "vibration"}, ...],
        timestamp: ~U[2026-04-26 12:00:00Z]
      }
  """

  @behaviour Plug
  import Plug.Conn

  @type t :: pid()

  @spec start() :: {:ok, t()}
  def start do
    Agent.start_link(fn -> %{batches: [], responses: %{}} end)
  end

  @spec start_link() :: {:ok, t()}
  def start_link, do: start()

  @spec batches(t()) :: [map()]
  def batches(agent), do: Agent.get(agent, & &1.batches)

  @spec reset(t()) :: :ok
  def reset(agent),
    do: Agent.update(agent, fn _ -> %{batches: [], responses: %{}} end)

  @spec set_response(t(), String.t(), term()) :: :ok
  def set_response(agent, stream, response) do
    Agent.update(agent, fn state ->
      put_in(state, [:responses, stream], response)
    end)
  end

  # ─── Plug ───────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Keyword.fetch!(opts, :agent)
    opts
  end

  @impl true
  def call(%Plug.Conn{method: "POST"} = conn, opts) do
    agent = Keyword.fetch!(opts, :agent)
    stream = stream_name(conn)

    {:ok, body, conn} = Plug.Conn.read_body(conn, length: 16 * 1024 * 1024)

    headers =
      conn.req_headers
      |> Enum.map(fn {k, v} -> {String.downcase(k), v} end)

    Agent.update(agent, fn state ->
      entry = %{
        stream: stream,
        body: body,
        headers: headers,
        timestamp: DateTime.utc_now()
      }

      Map.update!(state, :batches, fn list -> list ++ [entry] end)
    end)

    case stream_response(agent, stream) do
      {:ok, status} ->
        send_resp(conn, status, "")

      {:fingerprint_mismatch, expected} ->
        body =
          Jason.encode!(%{
            error: "fingerprint_mismatch",
            expected: expected,
            hint: "GET /.well-known/soot/contract for the current schema descriptor"
          })

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(409, body)

      {:stream_retired} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(410, Jason.encode!(%{error: "stream_retired"}))

      {:custom, status, body} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, body)
    end
  end

  def call(conn, _opts) do
    send_resp(conn, 405, "")
  end

  defp stream_name(%Plug.Conn{path_params: %{"stream_name" => name}}), do: name

  defp stream_name(%Plug.Conn{path_info: path_info}) do
    case List.last(path_info) do
      nil -> ""
      n -> n
    end
  end

  defp stream_response(agent, stream) do
    case Agent.get(agent, fn state -> Map.get(state.responses, stream) end) do
      nil -> {:ok, 204}
      override -> override
    end
  end
end
