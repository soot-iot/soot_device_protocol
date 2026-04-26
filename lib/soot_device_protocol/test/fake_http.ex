defmodule SootDeviceProtocol.Test.FakeHTTP do
  @moduledoc """
  In-memory `SootDeviceProtocol.HTTPClient` implementation. Tests
  configure a list of `{method, url}` → `{status, headers, body} |
  {:error, reason}` mappings; the fake records each request so tests
  can assert on what was sent.
  """

  @behaviour SootDeviceProtocol.HTTPClient

  @spec start_link() :: {:ok, pid()}
  def start_link do
    Agent.start_link(fn -> %{routes: %{}, requests: []} end)
  end

  @spec stub(pid(), :get | :post, String.t(), term()) :: :ok
  def stub(agent, method, url, response) do
    Agent.update(agent, fn state ->
      put_in(state, [:routes, {method, url}], response)
    end)
  end

  @spec requests(pid()) :: [map()]
  def requests(agent), do: Agent.get(agent, & &1.requests)

  @impl true
  def request(method, url, headers, body, opts) do
    agent = Keyword.fetch!(opts, :agent)

    Agent.update(agent, fn state ->
      Map.update!(state, :requests, fn list ->
        list ++
          [
            %{
              method: method,
              url: url,
              headers: headers,
              body: body,
              opts: Keyword.delete(opts, :agent)
            }
          ]
      end)
    end)

    case Agent.get(agent, fn state -> Map.get(state.routes, {method, url}) end) do
      nil -> {:error, {:no_stub, method, url}}
      {:error, _} = err -> err
      {status, headers, body} -> {:ok, {status, headers, body}}
    end
  end
end
