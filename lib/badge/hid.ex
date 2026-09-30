defmodule Badge.Hid do
  @moduledoc """
  Builds HID boot keyboard input reports from `Badge.Keyboard` labels.

  A report is eight bytes: the modifier bits, a reserved zero, then up to six
  key usages. `report/1` takes the whole set of labels held right now, so a
  press and a release are both just the next report. `Fn` and the six shape
  keys have no usage and add nothing.

  The lookup tables are built at compile time on the host; only the lookups
  run on AtomVM.
  """

  @letters for c <- ?A..?Z, into: %{}, do: {[c], 0x04 + c - ?A}

  @digits for {c, usage} <- Enum.zip(~c"1234567890", 0x1E..0x27), into: %{}, do: {[c], usage}

  @keys %{
    ~c"Enter" => 0x28,
    ~c"Esc" => 0x29,
    ~c"Bksp" => 0x2A,
    ~c"Tab" => 0x2B,
    ~c"Space" => 0x2C,
    ~c"-" => 0x2D,
    ~c"=" => 0x2E,
    ~c"[" => 0x2F,
    ~c"]" => 0x30,
    ~c"\\" => 0x31,
    ~c";" => 0x33,
    ~c"'" => 0x34,
    ~c"`" => 0x35,
    ~c"," => 0x36,
    ~c"." => 0x37,
    ~c"/" => 0x38,
    ~c"Right" => 0x4F,
    ~c"Left" => 0x50,
    ~c"Down" => 0x51,
    ~c"Up" => 0x52
  }

  @usages @letters |> Map.merge(@digits) |> Map.merge(@keys)

  # Bits of the modifier byte; `SP` is the Cmd key.
  @modifiers %{
    ~c"Ctrl" => 0x01,
    ~c"LShift" => 0x02,
    ~c"Alt" => 0x04,
    ~c"SP" => 0x08,
    ~c"RShift" => 0x20,
    ~c"AltGr" => 0x40
  }

  @rollover 0x01
  @slots 6

  @doc "The HID usage for a label, or `nil` for a modifier or a key without one."
  @spec usage(charlist) :: non_neg_integer | nil
  def usage(label), do: Map.get(@usages, label)

  @doc "The modifier bit for a label, or 0 for anything that is not a modifier."
  @spec modifier(charlist) :: non_neg_integer
  def modifier(label), do: Map.get(@modifiers, label, 0)

  @doc """
  The input report for every label held at once.

  Usages are in ascending order. More than six keys give the rollover report,
  six `0x01`s, with the modifiers still set.
  """
  @spec report([charlist]) :: binary
  def report(labels) do
    <<modifiers(labels, 0), 0>> <> keys(:lists.usort(usages(labels, [])))
  end

  @doc "The report with nothing held, which releases every key on the host."
  @spec empty() :: binary
  def empty, do: <<0, 0, 0, 0, 0, 0, 0, 0>>

  defp modifiers([], bits), do: bits
  defp modifiers([label | rest], bits), do: modifiers(rest, :erlang.bor(bits, modifier(label)))

  defp usages([], acc), do: acc

  defp usages([label | rest], acc) do
    case usage(label) do
      nil -> usages(rest, acc)
      code -> usages(rest, [code | acc])
    end
  end

  defp keys(codes) when length(codes) > @slots do
    :erlang.list_to_binary(:lists.duplicate(@slots, @rollover))
  end

  defp keys(codes) do
    :erlang.list_to_binary(codes ++ :lists.duplicate(@slots - length(codes), 0))
  end
end
