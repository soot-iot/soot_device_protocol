defmodule SootDeviceProtocol.HTTPClient.HTTPC do
  @moduledoc """
  `:httpc`-backed implementation of `SootDeviceProtocol.HTTPClient`.

  Each request uses an isolated `:httpc` profile so concurrent device
  components don't share connection pools. SSL options are derived
  from the caller's `:cert_pem` / `:key_pem` / `:trust_pems` so every
  request is mTLS-authenticated against the configured trust roots.
  """

  @behaviour SootDeviceProtocol.HTTPClient

  @impl true
  def request(method, url, headers, body, opts) do
    profile = ensure_profile(opts)

    httpc_request = build_request(method, url, headers, body)
    http_options = http_options(opts)
    request_options = [body_format: :binary]

    case :httpc.request(method, httpc_request, http_options, request_options, profile) do
      {:ok, {{_version, status, _reason}, resp_headers, resp_body}} ->
        normalized_headers = Enum.map(resp_headers, fn {k, v} -> {to_string(k), to_string(v)} end)
        body_bin = IO.iodata_to_binary(resp_body)
        {:ok, {status, normalized_headers, body_bin}}

      {:error, _} = err ->
        err
    end
  end

  defp build_request(:get, url, headers, _body) do
    {String.to_charlist(url), to_httpc_headers(headers)}
  end

  defp build_request(:post, url, headers, body) do
    content_type =
      Enum.find_value(headers, ~c"application/octet-stream", fn {k, v} ->
        if String.downcase(k) == "content-type", do: String.to_charlist(v), else: nil
      end)

    {String.to_charlist(url), to_httpc_headers(headers), content_type, body}
  end

  defp to_httpc_headers(headers) do
    Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  defp http_options(opts) do
    timeout = Keyword.get(opts, :timeout, 15_000)
    base = [timeout: timeout, connect_timeout: timeout]

    case ssl_options(opts) do
      [] -> base
      ssl -> Keyword.put(base, :ssl, ssl)
    end
  end

  @doc false
  def ssl_options(opts) do
    cert_pem = Keyword.get(opts, :cert_pem)
    key_pem = Keyword.get(opts, :key_pem)
    trust_pems = Keyword.get(opts, :trust_pems, [])

    cond do
      is_nil(cert_pem) and is_nil(key_pem) and trust_pems == [] ->
        []

      true ->
        cert_der = decode_cert!(cert_pem)
        key_entry = decode_key!(key_pem)

        cacerts =
          trust_pems
          |> Enum.flat_map(&decode_cert_chain/1)

        [
          cert: cert_der,
          key: key_entry,
          cacerts: cacerts,
          verify: :verify_peer,
          server_name_indication: :disable,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
    end
  end

  defp decode_cert!(nil), do: nil

  defp decode_cert!(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, :not_encrypted} | _] -> der
      _ -> raise ArgumentError, "expected a PEM-encoded certificate"
    end
  end

  defp decode_key!(nil), do: nil

  defp decode_key!(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [{type, der, :not_encrypted} | _]
      when type in [:ECPrivateKey, :RSAPrivateKey, :PrivateKeyInfo] ->
        {type, der}

      _ ->
        raise ArgumentError, "expected a PEM-encoded private key"
    end
  end

  defp decode_cert_chain(pem) when is_binary(pem) do
    pem
    |> :public_key.pem_decode()
    |> Enum.flat_map(fn
      {:Certificate, der, :not_encrypted} -> [der]
      _ -> []
    end)
  end

  defp ensure_profile(opts) do
    profile = Keyword.get(opts, :profile, :soot_device_protocol_default)

    case :inets.start(:httpc, profile: profile) do
      {:ok, _pid} -> profile
      {:error, {:already_started, _pid}} -> profile
    end
  end
end
