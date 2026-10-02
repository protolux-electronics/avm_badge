defmodule Badge.Whenwhere do
  @moduledoc """
  Asks whenwhere.nerves-project.org where the badge is.

  The service answers with the zone name, coordinates and country for the
  address the request came from. It reports no UTC offset, so the zone name
  goes to `Badge.Zone` to become one.

  Plain HTTP rather than TLS on purpose: the system clock is set by SNTP, and
  a certificate cannot be checked before the clock is right.

  `fetch/0` blocks on the network and belongs in a process of its own;
  `parse/1` is pure.
  """

  alias Badge.Store.Fetch

  @host "whenwhere.nerves-project.org"
  @port 80
  @path "/"

  # The whole answer is under 200 bytes.
  @max_body 4_096

  @type place :: %{zone: binary, latitude: binary, longitude: binary, country: binary}

  @doc "Where the badge is, or an error when the service cannot be reached."
  @spec fetch() :: {:ok, place} | {:error, term}
  def fetch do
    case Fetch.get({:http, @host, @port, @path}, @max_body) do
      {:ok, body} -> parse(body)
      error -> error
    end
  end

  @doc "Reads a response body, or `:error` when it is not one we can use."
  @spec parse(binary) :: {:ok, place} | :error
  def parse(body) do
    case decode(body) do
      {:ok, decoded} -> place(decoded)
      :error -> :error
    end
  end

  defp decode(body) do
    {:ok, :json.decode(body)}
  catch
    _kind, _error -> :error
  end

  # A place without a zone cannot set the clock, which is the point of asking.
  defp place(%{"time_zone" => zone} = decoded) when is_binary(zone) do
    {:ok,
     %{
       zone: zone,
       latitude: text(decoded, "latitude"),
       longitude: text(decoded, "longitude"),
       country: text(decoded, "country")
     }}
  end

  defp place(_decoded), do: :error

  defp text(decoded, key) do
    case Map.get(decoded, key) do
      value when is_binary(value) -> value
      _absent -> ""
    end
  end
end
