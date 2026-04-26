defmodule SootDeviceProtocol.HTTPClient do
  @moduledoc """
  Behavior for the small HTTP client the device uses to:

    * `POST /enroll` with the bootstrap cert/key (mTLS).
    * `GET  /.well-known/soot/contract` and asset paths (mTLS, with the
      operational cert once enrolled).
    * `POST /ingest/<stream>` with telemetry batches (Phase D3, mTLS).

  The behavior is small so a target with a constrained HTTP stack —
  e.g. a Nerves device using `Mint.HTTP` directly, or a constrained
  device using `:httpc` — can plug in. The default
  `SootDeviceProtocol.HTTPClient.HTTPC` implementation uses Erlang's
  built-in `:httpc` so we don't ship a Finch/Mint dependency for D1.

  ## SSL options

  Callers pass:

    * `:cert_pem` — PEM-encoded leaf cert presented at the TLS layer.
    * `:key_pem`  — PEM-encoded private key for that cert.
    * `:trust_pems` — list of CA PEMs to validate the server cert
      against.

  An implementation is expected to honor those options and refuse to
  connect with `verify_none`.

  ## Response shape

  `{status, headers, body}` on success, where:

    * `status`  — integer.
    * `headers` — list of `{lower-case-name, value}` strings.
    * `body`    — raw response binary.
  """

  @type ssl_opts :: [
          cert_pem: String.t(),
          key_pem: String.t(),
          trust_pems: [String.t()]
        ]

  @type response :: {non_neg_integer(), [{String.t(), String.t()}], binary()}

  @callback request(
              method :: :get | :post,
              url :: String.t(),
              headers :: [{String.t(), String.t()}],
              body :: binary(),
              opts :: keyword()
            ) :: {:ok, response()} | {:error, term()}

  @doc """
  Convenience entry point. Pulls the implementation module from
  `opts[:client]`, defaulting to `SootDeviceProtocol.HTTPClient.HTTPC`.
  """
  @spec request(
          :get | :post,
          String.t(),
          [{String.t(), String.t()}],
          binary(),
          keyword()
        ) :: {:ok, response()} | {:error, term()}
  def request(method, url, headers \\ [], body \\ <<>>, opts \\ []) do
    {client, opts} = Keyword.pop(opts, :client, __MODULE__.HTTPC)
    client.request(method, url, headers, body, opts)
  end
end
