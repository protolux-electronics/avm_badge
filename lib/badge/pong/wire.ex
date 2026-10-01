defmodule Badge.Pong.Wire do
  @moduledoc """
  What a Pong frame carries on the IR beam.

      <<"P", type, fields...>>

  The leading `P` keeps Pong apart from share frames and noise:

      Wire.encode({:ball, seq, %{d: d, x: x, vx: vx, vy: vy}})
      Wire.decode(payload) #=> {:ok, message} | :error
  """

  @magic 0x50

  @hello 1
  @ball 2
  @ack 3
  @score 4
  @bye 5
  @ping 6

  @max_name 20

  @doc "The longest name a hello carries, in bytes."
  @spec max_name() :: pos_integer
  def max_name, do: @max_name

  @doc "The payload for a message."
  @spec encode(tuple | :bye | :ping) :: binary
  def encode({:hello, coin, ready, name}), do: <<@magic, @hello, coin, ready>> <> clip(name)

  def encode({:ball, seq, %{d: d, x: x, vx: vx, vy: vy}}) do
    <<@magic, @ball, seq, d::signed-16, x::16, vx::signed-16, vy::signed-16>>
  end

  def encode({:ack, seq}), do: <<@magic, @ack, seq>>
  def encode({:score, seq, mine, theirs}), do: <<@magic, @score, seq, mine, theirs>>
  def encode(:bye), do: <<@magic, @bye>>
  def encode(:ping), do: <<@magic, @ping>>

  @doc "The message a payload carries, or `:error` for one no Pong page sends."
  @spec decode(binary) :: {:ok, tuple | :bye | :ping} | :error
  def decode(<<@magic, @hello, coin, ready, name::binary>>)
      when ready <= 1 and byte_size(name) <= @max_name do
    {:ok, {:hello, coin, ready, name}}
  end

  def decode(<<@magic, @ball, seq, d::signed-16, x::16, vx::signed-16, vy::signed-16>>) do
    {:ok, {:ball, seq, %{d: d, x: x, vx: vx, vy: vy}}}
  end

  def decode(<<@magic, @ack, seq>>), do: {:ok, {:ack, seq}}
  def decode(<<@magic, @score, seq, mine, theirs>>), do: {:ok, {:score, seq, mine, theirs}}
  def decode(<<@magic, @bye>>), do: {:ok, :bye}
  def decode(<<@magic, @ping>>), do: {:ok, :ping}
  def decode(_payload), do: :error

  defp clip(name) when byte_size(name) > @max_name, do: :binary.part(name, 0, @max_name)
  defp clip(name), do: name
end
