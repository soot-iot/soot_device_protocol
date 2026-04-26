defmodule SootDeviceProtocol.Telemetry.PipelineTest do
  use ExUnit.Case, async: true

  alias SootDeviceProtocol.Storage
  alias SootDeviceProtocol.Storage.Memory, as: StorageMemory
  alias SootDeviceProtocol.Telemetry.Pipeline
  alias SootDeviceProtocol.Test.FakeHTTP

  @base_url "https://example.test"

  setup do
    {:ok, http} = FakeHTTP.start_link()
    {:ok, storage} = StorageMemory.open()

    %{http: http, storage: storage}
  end

  defp start_pipeline(ctx, extra_opts \\ []) do
    base_opts = [
      base_url: @base_url,
      storage: ctx.storage,
      http_client: FakeHTTP,
      http_opts: [agent: ctx.http],
      auto_flush?: false,
      flush_interval_ms: 60_000,
      streams: [
        {"vibration",
         %{
           fingerprint: "fp-vibration",
           ingest_endpoint: "/ingest/vibration"
         }}
      ],
      name: nil
    ]

    Pipeline.start_link(Keyword.merge(base_opts, extra_opts))
  end

  test "write/3 appends to the buffer and assigns a monotonic sequence", ctx do
    {:ok, pipe} = start_pipeline(ctx)

    {:ok, 1} = Pipeline.write(pipe, "vibration", %{"x" => 1})
    {:ok, 2} = Pipeline.write(pipe, "vibration", %{"x" => 2})

    %{rows: rows} = Pipeline.stats(pipe)
    assert rows == 2

    assert {:ok, 2} == Storage.get(ctx.storage, {:telemetry_sequence, "vibration"})
  end

  test "write to an unknown stream is rejected", ctx do
    {:ok, pipe} = start_pipeline(ctx)
    assert {:error, :unknown_stream} = Pipeline.write(pipe, "wat", %{})
  end

  test "flush uploads, succeeds, and drops the buffered rows", ctx do
    FakeHTTP.stub(ctx.http, :post, @base_url <> "/ingest/vibration", {204, [], <<>>})

    {:ok, pipe} = start_pipeline(ctx)
    Pipeline.write(pipe, "vibration", %{"x" => 1})
    Pipeline.write(pipe, "vibration", %{"x" => 2})

    results = Pipeline.flush(pipe)
    assert results["vibration"] == {:ok, 2, 2}
    assert Pipeline.stats(pipe).rows == 0

    [request] = FakeHTTP.requests(ctx.http)
    headers = Map.new(request.headers, fn {k, v} -> {String.downcase(k), v} end)
    assert headers["x-stream"] == "vibration"
    assert headers["x-schema-fingerprint"] == "fp-vibration"
    assert headers["x-sequence-start"] == "1"
    assert headers["x-sequence-end"] == "2"

    body_lines = request.body |> String.split("\n", trim: true)
    assert Enum.map(body_lines, &Jason.decode!/1) == [%{"x" => 1}, %{"x" => 2}]
  end

  test "409 fingerprint mismatch drops the rows and triggers contract refresh", ctx do
    FakeHTTP.stub(
      ctx.http,
      :post,
      @base_url <> "/ingest/vibration",
      {409, [], Jason.encode!(%{error: "fingerprint_mismatch"})}
    )

    me = self()
    refresh_fun = fn -> send(me, :refresh) end

    {:ok, pipe} = start_pipeline(ctx, on_contract_refresh: refresh_fun)

    Pipeline.write(pipe, "vibration", %{"x" => 1})
    results = Pipeline.flush(pipe)

    assert {:dropped, :fingerprint_mismatch} = results["vibration"]
    assert Pipeline.stats(pipe).rows == 0
    assert_received :refresh
  end

  test "transient errors keep rows and apply backoff", ctx do
    FakeHTTP.stub(
      ctx.http,
      :post,
      @base_url <> "/ingest/vibration",
      {503, [], Jason.encode!(%{error: "service_unavailable"})}
    )

    {:ok, pipe} = start_pipeline(ctx, initial_backoff_ms: 100, max_backoff_ms: 200)
    Pipeline.write(pipe, "vibration", %{"x" => 1})

    results = Pipeline.flush(pipe)
    assert {:retry, {:http_error, 503, _}} = results["vibration"]
    assert Pipeline.stats(pipe).rows == 1

    # Second flush within backoff window: still retried, but no new request
    # because retry_after is still in the future.
    results = Pipeline.flush(pipe)
    assert results["vibration"] == :backoff
    # Only the original failed request hit the wire.
    assert length(FakeHTTP.requests(ctx.http)) == 1
  end

  test "buffer prunes oldest rows when over retention_rows", ctx do
    {:ok, pipe} = start_pipeline(ctx, retention_rows: 3)

    Enum.each(1..10, fn n -> Pipeline.write(pipe, "vibration", %{"n" => n}) end)

    %{rows: rows} = Pipeline.stats(pipe)
    assert rows <= 3
  end

  test "stats reports per-stream counts", ctx do
    {:ok, pipe} = start_pipeline(ctx)
    Pipeline.write(pipe, "vibration", %{"x" => 1})

    stats = Pipeline.stats(pipe)
    assert stats.streams["vibration"].rows == 1
  end

  test "configure_stream/3 registers a stream after start", ctx do
    {:ok, pipe} =
      Pipeline.start_link(
        base_url: @base_url,
        storage: ctx.storage,
        http_client: FakeHTTP,
        http_opts: [agent: ctx.http],
        auto_flush?: false,
        flush_interval_ms: 60_000,
        name: nil
      )

    assert {:ok, 0} =
             Pipeline.configure_stream(pipe, "vibration", %{
               fingerprint: "fp",
               ingest_endpoint: "/ingest/vibration"
             })

    {:ok, 1} = Pipeline.write(pipe, "vibration", %{"x" => 1})
  end

  test "persisted sequence survives a process restart", ctx do
    {:ok, pipe} = start_pipeline(ctx)
    Pipeline.write(pipe, "vibration", %{"x" => 1})
    Pipeline.write(pipe, "vibration", %{"x" => 2})

    GenServer.stop(pipe)

    {:ok, pipe2} = start_pipeline(ctx)
    {:ok, 3} = Pipeline.write(pipe2, "vibration", %{"x" => 3})
  end
end
