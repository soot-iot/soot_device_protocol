if Code.ensure_loaded?(Duxedo.Streams) do
defmodule SootDeviceProtocol.Telemetry.PipelineDuxedoTest do
  use ExUnit.Case, async: false

  alias SootDeviceProtocol.Storage.Memory, as: StorageMemory
  alias SootDeviceProtocol.Telemetry.Buffer.Duxedo, as: DuxedoBuffer
  alias SootDeviceProtocol.Telemetry.Pipeline
  alias SootDeviceProtocol.Test.FakeHTTP

  @base_url "https://example.test"

  setup ctx do
    instance =
      :"pdx_#{ctx.test |> Atom.to_string() |> String.replace(~r/[^a-zA-Z0-9]/, "_") |> String.slice(0, 50)}"

    tmp = System.tmp_dir!() |> Path.join("pdx_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    start_supervised!(
      {Duxedo,
       [
         instance: instance,
         persistence_dir: tmp,
         memory_limit: "32MB",
         flush_interval: 3600,
         collect_interval: 3600,
         metrics: [],
         events: []
       ]}
    )

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, http} = FakeHTTP.start_link()
    {:ok, storage} = StorageMemory.open()
    {:ok, buffer} = DuxedoBuffer.open(instance: instance)

    %{http: http, storage: storage, buffer: {DuxedoBuffer, buffer}, instance: instance}
  end

  test "pipeline + Buffer.Duxedo: write → flush as Arrow IPC → 204 → drop", ctx do
    FakeHTTP.stub(ctx.http, :post, @base_url <> "/ingest/vibration", {204, [], <<>>})

    {:ok, pipe} =
      Pipeline.start_link(
        base_url: @base_url,
        storage: ctx.storage,
        buffer: ctx.buffer,
        http_client: FakeHTTP,
        http_opts: [agent: ctx.http],
        auto_flush?: false,
        flush_interval_ms: 60_000,
        streams: [
          {"vibration",
           %{
             fingerprint: "fp-vibration",
             ingest_endpoint: "/ingest/vibration",
             schema: [{:seq, :s64}, {:ts, :s64}, {:x, :f64}, {:y, :f64}, {:z, :f64}]
           }}
        ],
        name: nil
      )

    {:ok, 1} = Pipeline.write(pipe, "vibration", %{ts: 1000, x: 0.1, y: 0.2, z: 0.3})
    {:ok, 2} = Pipeline.write(pipe, "vibration", %{ts: 1010, x: 0.4, y: 0.5, z: 0.6})

    results = Pipeline.flush(pipe)
    assert {:ok, 2, 2} = results["vibration"]

    [request] = FakeHTTP.requests(ctx.http)
    headers = Map.new(request.headers, fn {k, v} -> {String.downcase(k), v} end)
    assert headers["x-stream"] == "vibration"
    assert headers["x-schema-fingerprint"] == "fp-vibration"
    assert headers["x-sequence-start"] == "1"
    assert headers["x-sequence-end"] == "2"
    assert headers["content-type"] == "application/vnd.apache.arrow.stream"

    # Body decodes as Arrow IPC and contains both rows.
    {:ok, %Adbc.Result{data: [batch]}} = Adbc.Result.from_ipc_stream(request.body)
    cols = Enum.map(batch, &Adbc.Column.materialize/1)
    seq_col = Enum.find(cols, &(&1.field.name == "seq"))
    assert Adbc.Column.to_list(seq_col) == [1, 2]
  end

  test "409 fingerprint mismatch drops the rows from Duxedo and triggers contract refresh", ctx do
    FakeHTTP.stub(
      ctx.http,
      :post,
      @base_url <> "/ingest/vibration",
      {409, [], Jason.encode!(%{error: "fingerprint_mismatch"})}
    )

    me = self()
    refresh_fun = fn -> send(me, :refresh) end

    {:ok, pipe} =
      Pipeline.start_link(
        base_url: @base_url,
        storage: ctx.storage,
        buffer: ctx.buffer,
        http_client: FakeHTTP,
        http_opts: [agent: ctx.http],
        on_contract_refresh: refresh_fun,
        auto_flush?: false,
        flush_interval_ms: 60_000,
        streams: [
          {"vibration",
           %{
             fingerprint: "fp-vibration",
             ingest_endpoint: "/ingest/vibration",
             schema: [{:seq, :s64}, {:x, :f64}]
           }}
        ],
        name: nil
      )

    Pipeline.write(pipe, "vibration", %{x: 0.1})
    results = Pipeline.flush(pipe)
    assert {:dropped, :fingerprint_mismatch} = results["vibration"]
    assert_received :refresh

    %{rows: 0} = Pipeline.stats(pipe)
  end

  test "configure_stream/3 propagates schema to Buffer.Duxedo", ctx do
    {:ok, pipe} =
      Pipeline.start_link(
        base_url: @base_url,
        storage: ctx.storage,
        buffer: ctx.buffer,
        http_client: FakeHTTP,
        http_opts: [agent: ctx.http],
        auto_flush?: false,
        flush_interval_ms: 60_000,
        name: nil
      )

    assert {:ok, 0} =
             Pipeline.configure_stream(pipe, "vibration", %{
               fingerprint: "fp",
               ingest_endpoint: "/ingest/vibration",
               schema: [{:seq, :s64}, {:x, :f64}]
             })

    {:ok, 1} = Pipeline.write(pipe, "vibration", %{x: 0.1})
  end
end
end
