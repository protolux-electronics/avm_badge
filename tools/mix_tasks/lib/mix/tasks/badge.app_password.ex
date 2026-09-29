defmodule Mix.Tasks.Badge.AppPassword do
  @shortdoc "Creates a Bluesky app password for the badge to log in with"

  @moduledoc """
  Logs in to the account once with its main password and creates a named app
  password, for Settings > Bluesky on the badge.

      mix badge.app_password your.handle
      mix badge.app_password your.handle --name "second badge"

  The main password is asked for interactively, hidden, and never stored. An
  account that mails a sign-in code asks for that too. The app password is
  printed once; revoke it in the account's settings at any time. A name the
  account already uses is refused, since the PDS would answer a bare 500.
  """

  use Mix.Task

  @compile {:no_warn_undefined, [:httpc, :public_key]}

  @appview "https://public.api.bsky.app"
  @plc "https://plc.directory"
  @default_name "goatmire badge"

  @impl Mix.Task
  def run(args) do
    {opts, rest, _invalid} = OptionParser.parse(args, strict: [name: :string])
    # Mix leaves OTP apps the project does not declare off the code path.
    Enum.each([:crypto, :asn1, :public_key, :ssl, :inets], &Mix.ensure_application!/1)
    {:ok, _started} = Application.ensure_all_started([:inets, :ssl])

    handle = List.first(rest) || String.trim(Mix.shell().prompt("Handle:"))
    name = opts[:name] || @default_name

    did = resolve(handle)
    pds = pds(did)
    password = read_password("Main password for #{handle}: ")
    access = login(pds, handle, password, nil)

    refuse_taken(pds, access, name)

    %{"password" => app_password} =
      xrpc!(:post, pds, "com.atproto.server.createAppPassword", access, %{name: name})

    Mix.shell().info("""

    App password "#{name}" created for #{did} on #{pds}:

        #{app_password}

    Type it on the badge under Settings > Bluesky.#{provision_hint(pds)}\
    """)
  end

  # The badge tries eurosky.social first, so only another PDS is worth provisioning.
  defp provision_hint("https://eurosky.social"), do: ""

  defp provision_hint(pds) do
    "\n\nTo save the badge looking up the PDS on every login, provision it too:\n\n" <>
      "    python3 tools/provision.py --bsky-pds #{pds}"
  end

  defp resolve("did:" <> _rest = did), do: did

  defp resolve(handle) do
    query = URI.encode_query(handle: handle)

    case request(:get, "#{@appview}/xrpc/com.atproto.identity.resolveHandle?#{query}", nil, nil) do
      {200, %{"did" => did}} -> did
      _other -> Mix.raise("#{handle} does not resolve to an account")
    end
  end

  defp pds("did:plc:" <> _rest = did), do: did_document("#{@plc}/#{did}")
  defp pds("did:web:" <> host), do: did_document("https://#{host}/.well-known/did.json")
  defp pds(did), do: Mix.raise("#{did} is not a DID this task can read")

  defp did_document(url) do
    with {200, %{"service" => services}} <- request(:get, url, nil, nil),
         %{"serviceEndpoint" => pds} <- Enum.find(services, &pds_service?/1) do
      pds
    else
      _other -> Mix.raise("#{url} names no PDS")
    end
  end

  defp pds_service?(service),
    do:
      String.ends_with?(service["id"] || "", "#atproto_pds") or
        service["type"] == "AtprotoPersonalDataServer"

  # An account with email sign-in codes answers the first try with a 401 asking for one.
  defp login(pds, handle, password, token) do
    body =
      %{identifier: handle, password: password}
      |> then(&if(token, do: Map.put(&1, :authFactorToken, token), else: &1))

    url = "#{pds}/xrpc/com.atproto.server.createSession"

    case request(:post, url, nil, body) do
      {200, %{"accessJwt" => access}} ->
        access

      {401, %{"error" => "AuthFactorTokenRequired"}} when token == nil ->
        code = String.trim(Mix.shell().prompt("Sign-in code from your email:"))
        login(pds, handle, password, code)

      {401, %{"message" => message}} ->
        Mix.raise("Login failed: #{message}")

      {status, body} ->
        Mix.raise("PDS answered #{status}: #{inspect(body)}")
    end
  end

  defp refuse_taken(pds, access, name) do
    %{"passwords" => passwords} =
      xrpc!(:get, pds, "com.atproto.server.listAppPasswords", access, nil)

    if Enum.any?(passwords, &(&1["name"] == name)) do
      Mix.raise(
        "An app password named \"#{name}\" already exists. " <>
          "Pass --name, or revoke the old one in the account's settings"
      )
    end
  end

  defp xrpc!(method, pds, nsid, access, body) do
    case request(method, "#{pds}/xrpc/#{nsid}", access, body) do
      {200, answer} -> answer
      {status, answer} -> Mix.raise("PDS answered #{status} to #{nsid}: #{inspect(answer)}")
    end
  end

  defp request(method, url, access, body) do
    headers =
      [{~c"accept", ~c"application/json"}] ++
        if(access, do: [{~c"authorization", ~c"Bearer " ++ String.to_charlist(access)}], else: [])

    request =
      case body do
        nil -> {String.to_charlist(url), headers}
        body -> {String.to_charlist(url), headers, ~c"application/json", :json.encode(body)}
      end

    case :httpc.request(method, request, [ssl: tls()], body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, answer}} -> {status, decode(answer)}
      {:error, reason} -> Mix.raise("#{url}: #{inspect(reason)}")
    end
  end

  defp decode(""), do: nil

  defp decode(answer) do
    :json.decode(answer)
  rescue
    _error -> answer
  end

  defp tls do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  # Hidden input: `:io.get_password/0` needs the Erlang shell; under Mix the
  # terminal's echo is switched off with stty around a plain read instead.
  defp read_password(prompt) do
    IO.write(prompt)

    case :io.get_password() do
      password when is_list(password) ->
        IO.puts("")
        password |> to_string() |> String.trim()

      _error ->
        System.cmd("stty", ["-echo"], stderr_to_stdout: true)
        password = IO.gets("") || ""
        System.cmd("stty", ["echo"], stderr_to_stdout: true)
        IO.puts("")
        String.trim(password)
    end
  end
end
