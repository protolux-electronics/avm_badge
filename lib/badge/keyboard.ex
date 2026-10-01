defmodule Badge.Keyboard do
  @moduledoc """
  Scanner for the 6-row x 13-column GPIO keyboard matrix.

  Columns are held high by internal pull-ups. To scan a row, drive that row
  low and read every column; a closed switch pulls its column low.

  The matrix has no diodes, so only the row being scanned is ever driven.
  Rows are open-drain with pull-ups, so writing `:high` releases a row
  rather than driving it, and two rows can never fight through a closed
  switch. ROW5 (GPIO45) boots with an internal pull-down, so its pull-up is
  not optional: a released row that sags low would drag its column low for
  every other row's scan slot.

  Without diodes the matrix also ghosts. Two keys pressed at once are always
  unambiguous; three keys forming three corners of a rectangle conjure a
  phantom fourth, so that geometry is detected and the whole reading
  discarded.

  Scanning runs on a timer rather than a tight loop.
  """

  use GenServer

  alias Badge.Hardware
  alias Badge.KeyRepeat
  alias Badge.Keymap

  @compile {:no_warn_undefined, [:esp, :gpio, GPIO]}

  @rows Hardware.rows()
  @cols Hardware.cols()

  # Computed at compile time; AtomVM's runtime Enum has no with_index/1.
  @indexed_rows Enum.with_index(@rows)
  @indexed_cols Enum.with_index(@cols)

  # nil marks no switch; a label used more than once is one shared physical key.
  @layout [
    [
      nil,
      ~c"Esc",
      ~c"Square",
      ~c"Triangle",
      ~c"Cross",
      nil,
      nil,
      nil,
      ~c"Circle",
      ~c"Clover",
      ~c"Diamond",
      ~c"Bksp",
      nil
    ],
    [~c"`", ~c"1", ~c"2", ~c"3", ~c"4", ~c"5", ~c"6", ~c"7", ~c"8", ~c"9", ~c"0", ~c"-", ~c"="],
    [~c"Tab", ~c"Q", ~c"W", ~c"E", ~c"R", ~c"T", ~c"Y", ~c"U", ~c"I", ~c"O", ~c"P", ~c"[", ~c"]"],
    [
      ~c"Fn",
      ~c"A",
      ~c"S",
      ~c"D",
      ~c"F",
      ~c"G",
      ~c"H",
      ~c"J",
      ~c"K",
      ~c"L",
      ~c";",
      ~c"'",
      ~c"Enter"
    ],
    [
      ~c"LShift",
      ~c"Z",
      ~c"X",
      ~c"C",
      ~c"V",
      ~c"B",
      ~c"N",
      ~c"M",
      ~c",",
      ~c".",
      ~c"/",
      ~c"Up",
      ~c"RShift"
    ],
    [
      ~c"Ctrl",
      ~c"SP",
      ~c"Alt",
      ~c"\\",
      ~c"Space",
      ~c"Space",
      ~c"Space",
      ~c"Space",
      nil,
      ~c"AltGr",
      ~c"Left",
      ~c"Down",
      ~c"Right"
    ]
  ]

  @keymap for {row, r} <- Enum.with_index(@layout),
              {key, c} <- Enum.with_index(row),
              key != nil,
              into: %{},
              do: {{r, c}, key}

  # Milliseconds between scan passes.
  @scan_interval 5

  # Scans a reading must hold steady before it counts; raising this can cause a fast re-press to be dropped as a repeat.
  @debounce 2

  # Discarded reads to let a released row's pull-ups settle before reading.
  @settle_reads 2
  @settle_pin hd(@cols)

  # Delay before auto-repeat starts; kept well above the repeat interval.
  @repeat_delay 500

  # Expressed as a rate, not an interval, so a smaller number always means slower repeat.
  @repeat_rate 8
  @repeat_interval div(1000, @repeat_rate)

  def start_link(_arg) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Whether a key is held down right now, by its layout label.

  Presses are delivered as events; this answers the other question, for a
  page that wants a key held rather than tapped.
  """
  @spec holding?(charlist) :: boolean
  def holding?(label) do
    GenServer.call(__MODULE__, {:holding?, label})
  end

  @doc """
  Stops the CPU on the next scan until a key is pressed, unless one is held.
  The badge restarts when it wakes, so the key comes back as a fresh boot.
  """
  @spec light_sleep() :: :ok
  def light_sleep, do: GenServer.cast(__MODULE__, :light_sleep)

  @impl true
  def handle_call({:holding?, label}, _from, state) do
    {:reply, :lists.member(label, state.held), state}
  end

  @impl true
  def handle_cast(:light_sleep, state), do: {:noreply, %{state | sleep: true}}

  @impl true
  def init(:ok) do
    :io.format(~c"Keyboard: 6 rows x 13 cols, no diodes~n")

    setup()
    idle_self_test()
    # Leaves every row driven low, which is what the idle fast path needs.
    stuck_key_test()

    send(self(), :scan)

    {:ok, %{candidate: [], count: 0, held: [], repeat: KeyRepeat.new(), sleep: false}}
  end

  @impl true
  def handle_info(:scan, %{sleep: true} = state) do
    Process.sleep(@scan_interval)
    send(self(), :scan)

    {:noreply, nap(%{state | sleep: false})}
  end

  def handle_info(:scan, state) do
    state =
      state
      |> debounce(scan())
      |> maybe_repeat()

    # Sleeps rather than using Process.send_after/3.
    Process.sleep(@scan_interval)
    send(self(), :scan)

    {:noreply, state}
  end

  defp maybe_repeat(state) do
    case KeyRepeat.due(state.repeat, now(), @repeat_interval) do
      {:fire, event, repeat} ->
        route_event(event)
        %{state | repeat: repeat}

      {:idle, repeat} ->
        %{state | repeat: repeat}
    end
  end

  defp route_event(event) do
    Badge.UI.key_event(event)
  end

  # A level wake on a held key returns at once, so a held key refuses rather than loops.
  defp nap(%{held: held} = state) when held != [] do
    :io.format(~c"Sleep: refused, key held~n")
    Badge.UI.slept(:refused)

    state
  end

  defp nap(state) do
    Enum.each(@cols, fn pin -> :gpio.wakeup_enable(pin, :low) end)
    :esp.sleep_enable_gpio_wakeup()
    :io.format(~c"Sleep: light sleep~n")

    # Held, or the pads switch to their sleep configuration and no key can pull a column low.
    Enum.each(@rows ++ @cols, &GPIO.hold_en/1)
    started = :erlang.monotonic_time(:millisecond)
    result = :esp.light_sleep()
    slept = :erlang.monotonic_time(:millisecond) - started
    Enum.each(@rows ++ @cols, &GPIO.hold_dis/1)

    :io.format(~c"Sleep: woke after ~ps (~p), restarting~n", [div(slept, 1000), result])

    # A fresh boot rather than a resume; see the light-sleep spec in ../docs.
    :esp.restart()

    state
  end

  defp setup do
    Enum.each(@cols, fn pin ->
      GPIO.set_pin_mode(pin, :input)
      GPIO.set_pin_pull(pin, :up)
    end)

    # Open-drain, so writing :high releases the row rather than driving it; ROW5 (GPIO45) boots pulled down, so its pull-up must be set explicitly.
    Enum.each(@rows, fn pin ->
      GPIO.set_pin_mode(pin, :output_od)
      GPIO.set_pin_pull(pin, :up)
      GPIO.digital_write(pin, :high)
    end)

    # Leaves every row low, which the idle fast path in scan/0 assumes.
    set_rows(@rows, :low)
  end

  # A column reading low here, with every row driven low, means a fault or a stuck switch.
  defp idle_self_test do
    stuck = Enum.filter(@indexed_cols, fn {pin, _c} -> GPIO.digital_read(pin) == :low end)

    case stuck do
      [] ->
        :io.format(~c"Self-test: all 13 columns idle high~n")

      pins ->
        Enum.each(pins, fn {pin, c} ->
          :io.format(~c"Self-test: COL~p (GPIO ~p) STUCK LOW~n", [c, pin])
        end)
    end
  end

  # A full matrix pass with nothing held should come back empty.
  defp stuck_key_test do
    case full_scan() do
      [] ->
        :io.format(~c"Self-test: no keys stuck~n")

      pressed ->
        Enum.each(pressed, fn {r, c} ->
          :io.format(~c"Self-test: R~pC~p reads pressed with nothing held~n", [r, c])
        end)
    end
  end

  @doc """
  Measures where the scan budget goes. Not called at boot; run it by hand from
  the console when the timing needs re-checking. Subtract the empty-loop
  baseline from each figure.
  """
  def profile do
    col = hd(@cols)
    row = hd(@rows)
    n = 200

    bench(~c"baseline (empty loop)", n, fn -> :ok end)
    bench(~c"GPIO.digital_read (wrapper)", n, fn -> GPIO.digital_read(col) end)
    bench(~c":gpio.digital_read (direct)", n, fn -> :gpio.digital_read(col) end)
    bench(~c"GPIO.digital_write", n, fn -> GPIO.digital_write(row, :high) end)
    bench(~c"idle sweep (13 cols)", n, fn -> any_low?(@indexed_cols) end)
    bench(~c"full matrix scan", 50, fn -> full_scan() end)

    set_rows(@rows, :low)
  end

  defp bench(name, n, fun) do
    started = :erlang.monotonic_time(:microsecond)
    repeat(n, fun)
    elapsed = :erlang.monotonic_time(:microsecond) - started

    :io.format(~c"profile: ~s ~p ns/op (~p us total, n=~p)~n", [
      name,
      div(elapsed * 1000, n),
      elapsed,
      n
    ])
  end

  defp repeat(0, _fun), do: :ok

  defp repeat(n, fun) do
    fun.()
    repeat(n - 1, fun)
  end

  # Idle fast path: one sweep of all columns checks whether anything is pressed before doing a full scan.
  defp scan do
    case any_low?(@indexed_cols) do
      false -> []
      true -> full_scan()
    end
  end

  defp any_low?([]), do: false

  defp any_low?([{pin, _c} | rest]) do
    case GPIO.digital_read(pin) do
      :low -> true
      _high -> any_low?(rest)
    end
  end

  defp full_scan do
    # Releases every row, scans each in turn, then settles back to all-low.
    set_rows(@rows, :high)
    pressed = scan_rows(@indexed_rows, [])
    set_rows(@rows, :low)
    pressed
  end

  defp set_rows([], _level), do: :ok

  defp set_rows([pin | rest], level) do
    GPIO.digital_write(pin, level)
    set_rows(rest, level)
  end

  defp scan_rows([], pressed), do: pressed

  defp scan_rows([{pin, r} | rest], pressed) do
    GPIO.digital_write(pin, :low)
    settle(@settle_reads)
    closed = read_cols(@indexed_cols, r, pressed)
    # Release the line before the next row pulls down.
    GPIO.digital_write(pin, :high)
    scan_rows(rest, closed)
  end

  defp read_cols([], _r, pressed), do: pressed

  defp read_cols([{pin, c} | rest], r, pressed) do
    case GPIO.digital_read(pin) do
      :low -> read_cols(rest, r, [{r, c} | pressed])
      _high -> read_cols(rest, r, pressed)
    end
  end

  defp now, do: :erlang.monotonic_time(:microsecond)

  defp settle(0), do: :ok

  defp settle(n) do
    GPIO.digital_read(@settle_pin)
    settle(n - 1)
  end

  # A fresh reading restarts the debounce window.
  defp debounce(%{candidate: candidate} = state, pressed) when pressed != candidate do
    %{state | candidate: pressed, count: 1}
  end

  # The reading has now held steady long enough to act on.
  defp debounce(%{count: n} = state, pressed) when n + 1 == @debounce do
    commit(%{state | count: n + 1}, pressed)
  end

  defp debounce(%{count: n} = state, _pressed) when n < @debounce do
    %{state | count: n + 1}
  end

  # Already committed; nothing to do until the reading changes.
  defp debounce(state, _pressed), do: state

  defp commit(state, pressed) do
    case ghosts(pressed) do
      [] -> emit(state, pressed)
      ambiguous -> report_ghosting(state, ambiguous)
    end
  end

  # A key is ambiguous when another pressed key shares both its row and column.
  defp ghosts(pressed) do
    Enum.filter(pressed, fn {r, c} ->
      count_in_row(pressed, r) > 1 and count_in_col(pressed, c) > 1
    end)
  end

  defp count_in_row(pressed, r) do
    length(Enum.filter(pressed, fn {row, _c} -> row == r end))
  end

  defp count_in_col(pressed, c) do
    length(Enum.filter(pressed, fn {_r, col} -> col == c end))
  end

  defp report_ghosting(state, ambiguous) do
    :io.format(~c"GHOST ~p keys form a rectangle; reading discarded~n", [length(ambiguous)])
    state
  end

  # One event per key on the way down: held keys don't repeat, and shift is read from the full pressed set.
  defp emit(state, pressed) do
    labels = Enum.map(label_once(pressed), fn {label, _pos} -> label end)
    shifted = :lists.member(~c"LShift", labels) or :lists.member(~c"RShift", labels)

    # Releases against the new label set, before any newly-pressed key arms.
    released = KeyRepeat.release(state.repeat, labels)

    repeat =
      labels
      |> Enum.filter(fn label -> not :lists.member(label, state.held) end)
      |> Enum.reduce(released, fn label, repeat ->
        case dispatch(label, shifted) do
          {:emitted, event} -> KeyRepeat.arm(repeat, label, event, now(), @repeat_delay)
          :ignored -> repeat
        end
      end)

    %{state | held: labels, repeat: repeat}
  end

  defp dispatch(label, shifted) do
    case Keymap.decode(label, shifted) do
      :ignore ->
        :ignored

      event ->
        route_event(event)
        {:emitted, event}
    end
  end

  # Collapses duplicate labels to one event, keeping the first matrix position.
  defp label_once(pressed) do
    Enum.reduce(pressed, [], fn pos, acc ->
      label = label(pos)

      case :lists.keymember(label, 1, acc) do
        true -> acc
        false -> [{label, pos} | acc]
      end
    end)
  end

  # Unmapped intersections still produce a label; Keymap returns :ignore for these.
  defp label({r, c} = pos) do
    case Map.get(@keymap, pos) do
      nil -> :lists.flatten(:io_lib.format(~c"<unmapped R~pC~p>", [r, c]))
      label -> label
    end
  end
end
