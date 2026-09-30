defmodule Badge.Ble.Status do
  @moduledoc """
  What `Badge.Ble.Link` reports, as plain data.

  Every transition the driver's events cause is a pure function here, so the
  link GenServer only moves messages. `state` is one of `:off`, `:starting`,
  `:advertising`, `:passkey`, `:connected`, `:ready` and `:error`.
  """

  @type t :: %{
          state: atom,
          peer: binary | nil,
          name: binary,
          bonded: boolean,
          passkey: non_neg_integer | nil,
          internal_free: integer | nil,
          largest_block: integer | nil,
          reason: term
        }

  @doc "A link that is not open."
  @spec new(binary) :: t
  def new(name) do
    %{
      state: :off,
      peer: nil,
      name: name,
      bonded: false,
      passkey: nil,
      internal_free: nil,
      largest_block: nil,
      reason: nil
    }
  end

  @doc "The port is open; nothing has been heard from the stack yet."
  @spec starting(t) :: t
  def starting(status), do: %{new(status.name) | state: :starting}

  @doc "The port is closed."
  @spec closed(t) :: t
  def closed(status), do: new(status.name)

  @doc "The port could not be opened, or went away."
  @spec failed(t, term) :: t
  def failed(status, reason), do: %{status | state: :error, reason: reason}

  @doc "A fresh internal RAM reading."
  @spec mem(t, integer, integer) :: t
  def mem(status, free, largest), do: %{status | internal_free: free, largest_block: largest}

  @doc "Applies one driver event."
  @spec event(t, term) :: t
  def event(status, :advertising) do
    %{status | state: :advertising, peer: nil, bonded: false, passkey: nil, reason: nil}
  end

  def event(status, {:connected, addr}) do
    %{status | state: :connected, peer: address(addr), passkey: nil, reason: nil}
  end

  def event(status, :passkey_input), do: %{status | state: :passkey, passkey: nil}

  def event(status, {:passkey_display, n}), do: %{status | state: :passkey, passkey: n}

  def event(%{state: :ready} = status, {:encrypted, bonded}), do: %{status | bonded: bonded}

  def event(status, {:encrypted, bonded}) do
    %{status | state: :connected, bonded: bonded, passkey: nil}
  end

  def event(status, :ready), do: %{status | state: :ready, passkey: nil, reason: nil}

  def event(status, :disconnected) do
    %{status | state: :advertising, peer: nil, bonded: false, passkey: nil}
  end

  def event(status, {:error, reason}), do: %{status | state: :error, reason: reason}

  def event(status, _other), do: status

  @doc "A six-byte address as `AA:BB:CC:DD:EE:FF`, most significant byte first."
  @spec address(binary) :: binary | nil
  def address(<<a, b, c, d, e, f>>) do
    :erlang.iolist_to_binary([hex(a), ?:, hex(b), ?:, hex(c), ?:, hex(d), ?:, hex(e), ?:, hex(f)])
  end

  def address(_other), do: nil

  defp hex(byte), do: <<digit(div(byte, 16)), digit(rem(byte, 16))>>

  defp digit(value) when value < 10, do: ?0 + value
  defp digit(value), do: ?A + value - 10
end
