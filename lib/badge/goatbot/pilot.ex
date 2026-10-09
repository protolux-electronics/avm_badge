defmodule Badge.Goatbot.Pilot do
  @moduledoc """
  Drives the goatbot from the accelerometer, for `Badge.Page.Goatbot`.

  A process the page owns, aimed at the robot's node (see
  `Badge.Goatbot.node/1`). Every `period` it reads the tilt and, once the
  robot has answered, sends a drive command while engaged or a hello while
  not. Its owner gets `{:pilot, pilot, report}` every other period, with:

    * `:link` — `:no_node` before the badge's own node is up, `:no_address`
      with no robot to aim at, `:searching` until the robot answers, then
      `:connected`
    * `:robot` — the robot's state as it last answered, or `nil`
    * `:engaged` — whether tilt is driving
    * `:tilt` — `{roll, pitch}` against the reference, in degrees
    * `:command` — `{throttle, turn}`, as `Badge.Goatbot.command/2` gives it
    * `:notice` — the last robot command and its result, such as
      `"arm: ok"`, for a few seconds, or `nil`

  It stops the robot and exits when told to, or when its owner exits. Losing
  the robot drops out of driving, so a link that comes back does not start
  it moving again by itself. Drive commands only go out while the robot is
  answering, so nothing queues up behind a connection that is still being
  made. The robot stops by itself once commands stop arriving.
  """

  alias Badge.Goatbot
  alias Badge.Sensors

  @compile {:no_warn_undefined, [:net_kernel]}

  @period 100

  # Hello every fifth period, so an idle link costs little.
  @hello_every 5

  # The robot counts as gone after this long without an answer.
  @stale 1_500

  # How long a command's result stays in the report.
  @notice_ms 5_000

  @doc "Starts a pilot that reports to `owner` and drives `target`, a node or `nil`."
  @spec start(pid, atom | nil) :: pid
  def start(owner, target) do
    spawn(fn ->
      :erlang.monitor(:process, owner)
      loop(fresh(owner, target))
    end)
  end

  @doc "Aims at another robot node, stopping and dropping out of driving first."
  @spec retarget(pid, atom | nil) :: :ok
  def retarget(pilot, target), do: tell(pilot, {:target, target})

  @doc """
  Runs `:arm`, `:stand` or `:disarm` on the robot, if it is answering.
  Disarming also stops driving.
  """
  @spec command(pid, atom) :: :ok
  def command(pilot, name), do: tell(pilot, {:command, name})

  @doc "Starts driving, taking the badge's pose now as level."
  @spec engage(pid) :: :ok
  def engage(pilot), do: tell(pilot, :engage)

  @doc "Stops driving and sends the robot a stop."
  @spec release(pid) :: :ok
  def release(pilot), do: tell(pilot, :release)

  @doc "Sends the robot a stop and exits."
  @spec stop(pid) :: :ok
  def stop(pilot), do: tell(pilot, :stop)

  defp tell(pilot, message) do
    send(pilot, message)
    :ok
  end

  defp fresh(owner, target) do
    %{
      owner: owner,
      target: target,
      count: 0,
      tilt: {0, 0},
      reference: {0, 0},
      engaged: false,
      robot: nil,
      heard_at: nil,
      logged: nil,
      notice: nil
    }
  end

  defp loop(state) do
    state = %{state | tilt: read_tilt(state.tilt), count: state.count + 1}
    state = state |> drain() |> with_cookie() |> transmit() |> log_link()

    if rem(state.count, 2) == 0, do: send(state.owner, {:pilot, self(), report(state)})

    Process.sleep(@period)
    loop(state)
  end

  defp read_tilt(previous) do
    Sensors.orientation()
  catch
    _kind, _reason -> previous
  end

  defp drain(state) do
    receive do
      :engage -> drain(%{state | engaged: true, reference: state.tilt})
      :release -> drain(halt(%{state | engaged: false}))
      :stop -> exit_after(state)
      {:DOWN, _ref, :process, _owner, _reason} -> exit_after(state)
      {:target, target} -> drain(retargeted(halt(state), target))
      {:goatbot, robot} -> drain(%{state | robot: robot, heard_at: now()})
      {:command, name} -> drain(order(state, name))
      {:goatbot_command, name, text} -> drain(noted(state, name, ": " <> text))
      _other -> drain(state)
    after
      0 -> state
    end
  end

  defp order(state, name) do
    case link(state) do
      :connected ->
        post(state, {:command, self(), name})
        state = if name == :disarm, do: halt(%{state | engaged: false}), else: state
        noted(state, name, "...")

      _offline ->
        noted(state, name, ": no robot")
    end
  end

  defp noted(state, name, text) do
    %{state | notice: {:erlang.atom_to_binary(name, :latin1) <> text, now()}}
  end

  defp notice(%{notice: {text, at}}), do: if(now() - at < @notice_ms, do: text, else: nil)
  defp notice(_state), do: nil

  defp retargeted(state, target) do
    %{state | target: target, engaged: false, robot: nil, heard_at: nil}
  end

  defp exit_after(state) do
    halt(state)
    exit(:normal)
  end

  # A single explicit stop, rather than waiting out the robot's timeout.
  defp halt(state) do
    if link(state) == :connected, do: post(state, {:drive, self(), 0.0, 0.0})
    state
  end

  defp transmit(state) do
    case {link(state), state.engaged} do
      {:connected, true} ->
        {throttle, turn} = command(state)
        post(state, {:drive, self(), throttle, turn})
        state

      {:searching, _engaged} ->
        if rem(state.count, @hello_every) == 0, do: post(state, {:hello, self()})
        %{state | engaged: false}

      {:connected, false} ->
        if rem(state.count, @hello_every) == 0, do: post(state, {:hello, self()})
        state

      _offline ->
        state
    end
  end

  defp post(state, message) do
    send({Goatbot.remote(), state.target}, message)
  catch
    _kind, _reason -> :ok
  end

  # The cookie is per node and dies with the badge's node, so it goes in before every attempt.
  defp with_cookie(state) do
    if link(state) == :searching and rem(state.count, @hello_every) == 0, do: set_cookie(state.target)
    state
  end

  defp set_cookie(target) do
    :net_kernel.set_cookie(target, Goatbot.cookie())
  catch
    _kind, _reason -> :ok
  end

  defp link(state) do
    cond do
      :erlang.node() == :nonode@nohost -> :no_node
      state.target == nil -> :no_address
      state.heard_at != nil and now() - state.heard_at < @stale -> :connected
      true -> :searching
    end
  end

  defp log_link(state) do
    link = link(state)

    if link != state.logged do
      :io.format(~c"Goatbot: ~p ~p~n", [link, state.target])
    end

    %{state | logged: link}
  end

  defp command(%{engaged: true} = state), do: Goatbot.command(state.tilt, state.reference)
  defp command(_state), do: {0.0, 0.0}

  defp report(state) do
    {roll, pitch} = state.tilt
    {roll0, pitch0} = state.reference

    %{
      link: link(state),
      robot: state.robot,
      engaged: state.engaged,
      tilt: {roll - roll0, pitch - pitch0},
      command: command(state),
      notice: notice(state)
    }
  end

  defp now, do: :erlang.monotonic_time(:millisecond)
end
