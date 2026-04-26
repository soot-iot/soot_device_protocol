defmodule SootDeviceProtocol.Test.IngestTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias SootDeviceProtocol.Test.Ingest

  setup do
    {:ok, agent} = Ingest.start()
    %{agent: agent}
  end

  defp post(stream, body, headers, agent) do
    conn(:post, "/ingest/#{stream}", body)
    |> put_path_params(%{"stream_name" => stream})
    |> Map.update!(:req_headers, fn rh ->
      rh ++ Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)
    end)
    |> Ingest.call(agent: agent)
  end

  defp put_path_params(conn, params), do: %{conn | path_params: params}

  test "default response is 204 and the batch is recorded", %{agent: agent} do
    conn =
      post("vibration", "row1\n", [{"x-stream", "vibration"}, {"x-sequence-start", "1"}], agent)

    assert conn.status == 204

    [%{stream: "vibration", body: body, headers: headers}] = Ingest.batches(agent)
    assert body == "row1\n"
    assert {"x-sequence-start", "1"} in headers
  end

  test "set_response/3 returns a 409 fingerprint mismatch", %{agent: agent} do
    Ingest.set_response(agent, "vibration", {:fingerprint_mismatch, "deadbeef"})

    conn = post("vibration", "row\n", [], agent)
    assert conn.status == 409
    assert Jason.decode!(conn.resp_body)["expected"] == "deadbeef"
  end

  test "stream_retired returns 410", %{agent: agent} do
    Ingest.set_response(agent, "vibration", {:stream_retired})

    conn = post("vibration", "row\n", [], agent)
    assert conn.status == 410
  end

  test "reset clears the batch list", %{agent: agent} do
    post("v", "x", [], agent)
    refute Ingest.batches(agent) == []
    Ingest.reset(agent)
    assert Ingest.batches(agent) == []
  end
end
