defmodule SootDeviceProtocol.Enrollment do
  @moduledoc """
  Bootstrap enrollment: turn a bootstrap cert + an enrollment token
  into an operational cert chain and persist the result.

  The flow mirrors `SootCore.Plug.Enroll`:

    1. The supervisor starts this GenServer with `:bootstrap_cert`,
       `:bootstrap_key`, `:enroll_url`, `:enrollment_token` and a
       storage binding.
    2. If the storage already holds an operational cert + key pair the
       process boots into the `:enrolled` state and is a no-op.
    3. Otherwise it generates a fresh EC keypair, builds a CSR with
       the configured subject, and POSTs it to `:enroll_url` while
       presenting the bootstrap cert/key at the TLS layer.
    4. On a 200 response it persists `operational_cert_pem`,
       `operational_chain_pem`, `operational_key_pem`, and
       `device_id` to storage.

  The supervisor is `:rest_for_one`, so a failing enrollment that
  raises will block the dependent components (MQTT, contract refresh,
  etc.) from starting until enrollment succeeds. Operators that want
  retry-with-backoff semantics wrap this process in their own
  supervisor.
  """

  use GenServer
  require Logger

  alias SootDeviceProtocol.{HTTPClient, Storage}

  @type state :: :unenrolled | :enrolled

  defmodule State do
    @moduledoc false
    defstruct [
      :storage,
      :enroll_url,
      :enrollment_token,
      :bootstrap_cert,
      :bootstrap_key,
      :trust_pems,
      :subject,
      :http_client,
      :http_opts,
      :status,
      :device_id
    ]
  end

  @keys [
    :operational_cert_pem,
    :operational_chain_pem,
    :operational_key_pem,
    :device_id
  ]

  # ─── client API ──────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Has this device been issued an operational identity?"
  @spec enrolled?(GenServer.server()) :: boolean()
  def enrolled?(server \\ __MODULE__), do: GenServer.call(server, :enrolled?)

  @doc "Run enrollment now if the device isn't already enrolled. Returns the new state."
  @spec ensure_enrolled(GenServer.server()) :: {:ok, state()} | {:error, term()}
  def ensure_enrolled(server \\ __MODULE__), do: GenServer.call(server, :ensure_enrolled, 30_000)

  @doc "Read the operational identity for downstream components."
  @spec operational_identity(GenServer.server()) ::
          {:ok, %{cert_pem: String.t(), key_pem: String.t(), chain_pem: String.t(), device_id: String.t()}}
          | :error
  def operational_identity(server \\ __MODULE__), do: GenServer.call(server, :operational_identity)

  @doc """
  Static helper: read the persisted operational identity straight from
  the given storage binding without going through the GenServer. Used
  by other components (e.g. the MQTT client supervisor) when they only
  need read-only access to the identity material.
  """
  @spec read_identity(Storage.binding()) ::
          {:ok, %{cert_pem: String.t(), key_pem: String.t(), chain_pem: String.t(), device_id: String.t()}}
          | :error
  def read_identity(storage) do
    with {:ok, cert} <- Storage.get(storage, :operational_cert_pem),
         {:ok, key} <- Storage.get(storage, :operational_key_pem),
         {:ok, chain} <- Storage.get(storage, :operational_chain_pem),
         {:ok, device_id} <- Storage.get(storage, :device_id) do
      {:ok, %{cert_pem: cert, key_pem: key, chain_pem: chain, device_id: device_id}}
    end
  end

  # ─── GenServer ────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    storage = Keyword.fetch!(opts, :storage)
    enroll_url = Keyword.fetch!(opts, :enroll_url)

    state = %State{
      storage: storage,
      enroll_url: enroll_url,
      enrollment_token: Keyword.get(opts, :enrollment_token),
      bootstrap_cert: Keyword.get(opts, :bootstrap_cert),
      bootstrap_key: Keyword.get(opts, :bootstrap_key),
      trust_pems: Keyword.get(opts, :trust_pems, []),
      subject: Keyword.get(opts, :subject, "/CN=device"),
      http_client: Keyword.get(opts, :http_client, HTTPClient.HTTPC),
      http_opts: Keyword.get(opts, :http_opts, []),
      status: detect_status(storage),
      device_id: detect_device_id(storage)
    }

    if Keyword.get(opts, :auto_enroll, true) and state.status == :unenrolled do
      {:ok, state, {:continue, :enroll}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:enroll, state) do
    case do_enroll(state) do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason} ->
        Logger.error("soot_device_protocol enrollment failed: #{inspect(reason)}")
        {:stop, {:enrollment_failed, reason}, state}
    end
  end

  @impl true
  def handle_call(:enrolled?, _from, state) do
    {:reply, state.status == :enrolled, state}
  end

  def handle_call(:ensure_enrolled, _from, %State{status: :enrolled} = state) do
    {:reply, {:ok, :enrolled}, state}
  end

  def handle_call(:ensure_enrolled, _from, state) do
    case do_enroll(state) do
      {:ok, state} -> {:reply, {:ok, state.status}, state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call(:operational_identity, _from, state) do
    {:reply, read_identity(state.storage), state}
  end

  # ─── enrollment flow ─────────────────────────────────────────────────

  defp do_enroll(%State{} = state) do
    with :ok <- ensure_inputs(state),
         {private, csr_pem} <- generate_csr(state),
         {:ok, response} <- post_enroll(state, csr_pem),
         {:ok, decoded} <- decode_response(response),
         :ok <- persist_identity(state.storage, private, decoded) do
      {:ok,
       %{
         state
         | status: :enrolled,
           device_id: decoded.device_id
       }}
    end
  end

  defp ensure_inputs(%State{enrollment_token: nil}), do: {:error, :missing_enrollment_token}
  defp ensure_inputs(%State{bootstrap_cert: nil}), do: {:error, :missing_bootstrap_cert}
  defp ensure_inputs(%State{bootstrap_key: nil}), do: {:error, :missing_bootstrap_key}
  defp ensure_inputs(_state), do: :ok

  defp generate_csr(%State{subject: subject}) do
    private = X509.PrivateKey.new_ec(:secp256r1)
    csr = X509.CSR.new(private, subject)
    csr_pem = X509.CSR.to_pem(csr)
    {private, csr_pem}
  end

  defp post_enroll(%State{} = state, csr_pem) do
    body = Jason.encode!(%{token: state.enrollment_token, csr_pem: csr_pem})

    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    opts =
      Keyword.merge(state.http_opts,
        cert_pem: state.bootstrap_cert,
        key_pem: state.bootstrap_key,
        trust_pems: state.trust_pems,
        client: state.http_client
      )

    case HTTPClient.request(:post, state.enroll_url, headers, body, opts) do
      {:ok, {200, _headers, body}} ->
        {:ok, body}

      {:ok, {status, _headers, body}} ->
        {:error, {:enroll_http_error, status, decode_error_body(body)}}

      {:error, _} = err ->
        err
    end
  end

  defp decode_response(json) do
    case Jason.decode(json) do
      {:ok,
       %{
         "certificate_pem" => cert,
         "chain_pem" => chain,
         "device_id" => device_id,
         "state" => server_state
       }}
      when is_binary(cert) and is_binary(chain) and is_binary(device_id) ->
        {:ok,
         %{
           cert_pem: cert,
           chain_pem: chain,
           device_id: device_id,
           server_state: server_state
         }}

      {:ok, _} ->
        {:error, :invalid_enroll_response_shape}

      {:error, reason} ->
        {:error, {:invalid_enroll_response_json, reason}}
    end
  end

  defp decode_error_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  defp persist_identity(storage, private_key, decoded) do
    key_pem = X509.PrivateKey.to_pem(private_key)

    with :ok <- Storage.put(storage, :operational_cert_pem, decoded.cert_pem),
         :ok <- Storage.put(storage, :operational_chain_pem, decoded.chain_pem),
         :ok <- Storage.put(storage, :operational_key_pem, key_pem),
         :ok <- Storage.put(storage, :device_id, decoded.device_id) do
      :ok
    end
  end

  defp detect_status(storage) do
    case read_identity(storage) do
      {:ok, _} -> :enrolled
      _ -> :unenrolled
    end
  end

  defp detect_device_id(storage) do
    case Storage.get(storage, :device_id) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  @doc false
  def storage_keys, do: @keys
end
