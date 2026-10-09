defmodule Badge.Goatbot do
  @moduledoc """
  Tilt to drive commands for the goatbot balance robot.

  The robot runs an Erlang node named for its wifi address,
  `goatbot@192.168.1.40`, and takes `{:drive, from, throttle, turn}` on its
  registered `Goatbot.Remote`. The address is typed in on the page, since the
  badge cannot yet resolve the robot's `goatbot.local` name.
  Both are fractions from -1 to 1, positive forwards and to the robot's left;
  the robot scales them to its own speed and turn rate.

  Tilt is measured from a reference pose, the one the badge was held in when
  driving started. Tipping the top edge away drives forwards and tipping the
  right edge down turns right. Each axis ignores the first `deadband/0`
  degrees and reaches full scale at `full_scale/0`.
  """

  @remote :"Elixir.Goatbot.Remote"
  @cookie "goatbot_cookie"
  @deadband 5
  @full_scale 25

  @doc "The robot's node at an IPv4 address, or `nil` without one."
  @spec node(binary | nil) :: atom | nil
  def node(nil), do: nil
  def node(ip), do: :erlang.binary_to_atom(<<"goatbot@", ip::binary>>, :latin1)

  @doc "A dotted IPv4 address with surrounding spaces trimmed, or `:error`."
  @spec address(binary) :: {:ok, binary} | :error
  def address(text) do
    ip = trim(text)

    case :binary.split(ip, ".", [:global]) do
      [_, _, _, _] = parts -> if :lists.all(&octet?/1, parts), do: {:ok, ip}, else: :error
      _other -> :error
    end
  end

  defp octet?(part) when byte_size(part) in 1..3 do
    :lists.all(fn char -> char >= ?0 and char <= ?9 end, :erlang.binary_to_list(part)) and
      :erlang.binary_to_integer(part) <= 255
  end

  defp octet?(_part), do: false

  defp trim(<<" ", rest::binary>>), do: trim(rest)
  defp trim(text), do: trim_end(text, byte_size(text))

  defp trim_end(text, 0), do: text

  defp trim_end(text, size) do
    case :binary.at(text, size - 1) do
      ?\s -> trim_end(:binary.part(text, 0, size - 1), size - 1)
      _char -> text
    end
  end

  @doc "The name the robot's drive process is registered under."
  @spec remote() :: atom
  def remote, do: @remote

  @doc "The robot's distribution cookie."
  @spec cookie() :: binary
  def cookie, do: @cookie

  @doc "Degrees of tilt either side of the reference that drive nothing."
  @spec deadband() :: pos_integer
  def deadband, do: @deadband

  @doc "Degrees of tilt that ask for full speed or turn."
  @spec full_scale() :: pos_integer
  def full_scale, do: @full_scale

  @doc """
  `{throttle, turn}` for a roll and pitch in whole degrees, as
  `Badge.Accel.orientation/1` reports them, against a reference pair.
  """
  @spec command({integer, integer}, {integer, integer}) :: {float, float}
  def command({roll, pitch}, {roll0, pitch0}) do
    {axis(pitch0 - pitch), axis(roll0 - roll)}
  end

  @doc "A tilt in degrees as a fraction from -1 to 1, rounded to hundredths."
  @spec axis(integer) :: float
  def axis(degrees) when degrees < 0, do: 0.0 - axis(-degrees)
  def axis(degrees) when degrees <= @deadband, do: 0.0
  def axis(degrees) when degrees >= @full_scale, do: 1.0
  def axis(degrees), do: round((degrees - @deadband) * 100 / (@full_scale - @deadband)) / 100
end
