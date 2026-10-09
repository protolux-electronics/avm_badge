defmodule Badge.Page.Goatbot do
  @moduledoc """
  Drives the goatbot balance robot by tilting the badge.

  Opening the page brings the badge's Erlang node up (see
  `Badge.Cluster.Link`) and starts a `Badge.Goatbot.Pilot` aimed at the
  robot's address, kept in NVS under `goatbot_ip`. I asks for the address,
  and the page asks by itself when none is stored.

  Once the robot answers, A arms it, S stands it up and D disarms it, as in
  the robot's dashboard. Enter starts driving and takes the pose the badge is
  held in as level; Enter again, D, or leaving the page, stops it. Tipping
  the top edge away drives forwards, tipping it back reverses, and tipping
  sideways turns, each past a small deadband. The pad shows the tilt from
  level, with the deadband in the middle.
  """

  use Badge.Page

  alias Badge.Cluster.Link
  alias Badge.Field
  alias Badge.Goatbot
  alias Badge.Goatbot.Pilot
  alias Badge.Nav
  alias Badge.Nvs
  alias Badge.Readout
  alias Badge.Theme

  @status_y Theme.content_top() + 4
  @address_y @status_y + Readout.pitch()
  @drive_y @address_y + Readout.pitch()
  @notice_y @drive_y + Readout.pitch()

  @pad 96
  @pad_x div(Theme.width() - @pad, 2)
  @pad_y 104
  @centre_x @pad_x + div(@pad, 2)
  @centre_y @pad_y + div(@pad, 2)
  @marker 10
  @reach div(@pad - @marker, 2) - 1
  @dead div(Goatbot.deadband() * @reach, Goatbot.full_scale())

  @help_y 204
  @help2_y @help_y + Readout.pitch()

  # "255.255.255.255"
  @capacity 15

  @impl true
  def title, do: "Goatbot"

  @impl true
  def icon, do: :cross

  @impl true
  def init, do: %{pilot: nil, report: nil, address: nil, field: nil, save: nil}

  @impl true
  def refresh(_state), do: 200

  @impl true
  def tick(%{pilot: nil} = state) do
    Link.open()
    address = Nvs.get(:goatbot_ip)
    field = if address == nil, do: Field.new(@capacity), else: nil

    %{state | pilot: Pilot.start(self(), Goatbot.node(address)), address: address, field: field}
  end

  def tick(%{save: nil} = state), do: state

  def tick(%{save: address} = state) do
    Nvs.put(:goatbot_ip, address)
    Pilot.retarget(state.pilot, Goatbot.node(address))

    %{state | address: address, save: nil}
  end

  @impl true
  def leave(%{pilot: nil}), do: :ok
  def leave(%{pilot: pilot}), do: Pilot.stop(pilot)

  # Typing owns every key, so an A in an address is not a command.
  @impl true
  def handle_key(event, %{field: field} = state) when field != nil, do: typing(event, state)

  def handle_key({:edit, :newline}, state), do: toggle(state)
  def handle_key({:char, ?\s}, state), do: toggle(state)

  def handle_key({:char, char}, %{report: report} = state) when char == ?i or char == ?I do
    case report do
      %{engaged: true} -> :ignore
      _idle -> {:ok, %{state | field: fill(state.address || "")}}
    end
  end

  def handle_key({:char, char}, state) do
    case {robot_command(char), state.report} do
      {nil, _report} -> :ignore
      {_name, nil} -> :ignore
      {name, _report} ->
        Pilot.command(state.pilot, name)
        {:ok, state}
    end
  end

  def handle_key(_event, _state), do: :ignore

  @doc "The robot command a key asks for, as in the robot's dashboard, or `nil`."
  @spec robot_command(integer) :: atom | nil
  def robot_command(char) when char == ?a or char == ?A, do: :arm
  def robot_command(char) when char == ?s or char == ?S, do: :stand
  def robot_command(char) when char == ?d or char == ?D, do: :disarm
  def robot_command(_char), do: nil

  @impl true
  def handle_info({:pilot, pilot, report}, %{pilot: pilot} = state) do
    {:ok, %{state | report: report}}
  end

  def handle_info(_message, _state), do: :ignore

  defp toggle(%{report: %{engaged: true}} = state) do
    Pilot.release(state.pilot)
    {:ok, state}
  end

  defp toggle(%{report: %{link: :connected}} = state) do
    Pilot.engage(state.pilot)
    {:ok, state}
  end

  defp toggle(_state), do: :ignore

  # An address that does not parse stays open for correcting.
  defp typing({:edit, :newline}, state) do
    case Goatbot.address(Field.value(state.field)) do
      {:ok, address} -> {:ok, %{state | field: nil, save: address}}
      :error -> {:ok, state}
    end
  end

  defp typing({:nav, :home}, %{address: nil}), do: :ignore
  defp typing({:nav, :home}, state), do: {:ok, %{state | field: nil}}

  defp typing({:char, char}, state) do
    {:ok, %{state | field: Field.insert(state.field, char)}}
  end

  defp typing({:edit, :backspace}, state) do
    {:ok, %{state | field: Field.backspace(state.field)}}
  end

  defp typing({:move, :left}, state), do: {:ok, %{state | field: Field.left(state.field)}}
  defp typing({:move, :right}, state), do: {:ok, %{state | field: Field.right(state.field)}}

  defp typing(_event, state), do: {:ok, state}

  defp fill(value) do
    :lists.foldl(&Field.insert(&2, &1), Field.new(@capacity), :erlang.binary_to_list(value))
  end

  @impl true
  def render(state) do
    {text, colour} = status(state.report, state.address)

    status_row(text, colour) ++
      address_row(state) ++
      drive_row(state.report) ++ notice_row(state.report) ++ pad(state.report) ++ help(state)
  end

  @doc "What the status row says for a pilot report and robot address, and in what colour."
  @spec status(map | nil, binary | nil) :: {binary, integer}
  def status(nil, _address), do: {"starting", Theme.dim()}
  def status(%{link: :no_node}, _address), do: {"waiting for wifi", Theme.warn()}
  def status(%{link: :no_address}, _address), do: {"no address", Theme.warn()}
  def status(%{link: :searching}, address), do: {"connecting to " <> address, Theme.warn()}
  def status(%{robot: :balancing, engaged: true}, _address), do: {"driving", Theme.ok()}
  def status(%{robot: :balancing}, _address), do: {"balancing", Theme.ok()}

  def status(%{robot: robot}, _address) when is_atom(robot) and robot != nil do
    {:erlang.atom_to_binary(robot, :latin1), Theme.warn()}
  end

  def status(_report, _address), do: {"connected", Theme.warn()}

  defp status_row(text, colour), do: Readout.right_row("robot", text, @status_y, colour)

  defp address_row(%{field: field}) when field != nil do
    Readout.right_row("address", Field.value(field) <> "_", @address_y, Theme.select())
  end

  defp address_row(%{address: nil}), do: Readout.right_row("address", "not set", @address_y, Theme.dim())
  defp address_row(%{address: address}), do: Readout.right_row("address", address, @address_y, Theme.dim())

  defp drive_row(%{command: command}), do: Readout.right_row("drive", drive(command), @drive_y, Theme.fg())
  defp drive_row(_report), do: []

  defp notice_row(%{notice: notice}) when is_binary(notice) do
    Readout.right_row("last", notice, @notice_y, Theme.accent())
  end

  defp notice_row(_report), do: []

  @doc "A drive command as the drive row shows it."
  @spec drive({float, float}) :: binary
  def drive({throttle, turn}) when throttle == 0 and turn == 0, do: "stopped"
  def drive({throttle, turn}) when turn == 0, do: speed(throttle)
  def drive({throttle, turn}) when throttle == 0, do: turn(turn)
  def drive({throttle, turn}), do: speed(throttle) <> ", " <> turn(turn)

  @doc "A throttle as the speed row shows it."
  @spec speed(float) :: binary
  def speed(throttle) when throttle > 0, do: percent(throttle) <> " fwd"
  def speed(throttle) when throttle < 0, do: percent(throttle) <> " back"
  def speed(_throttle), do: "stopped"

  @doc "A turn as the turn row shows it; positive is left."
  @spec turn(float) :: binary
  def turn(turn) when turn > 0, do: percent(turn) <> " left"
  def turn(turn) when turn < 0, do: percent(turn) <> " right"
  def turn(_turn), do: "straight"

  defp percent(fraction), do: :erlang.integer_to_binary(abs(round(fraction * 100))) <> "%"

  # Marker first, frame last: AtomGL draws the tail first.
  defp pad(report) do
    [marker(report), deadband() | frame()]
  end

  defp marker(report) do
    {x, y} = marker_at(report)
    {:rect, x, y, @marker, @marker, marker_colour(report)}
  end

  @doc "Top-left of the pad's marker for a pilot report."
  @spec marker_at(map | nil) :: {integer, integer}
  def marker_at(%{tilt: {roll, pitch}}), do: {spot(@centre_x, roll), spot(@centre_y, pitch)}
  def marker_at(_report), do: {spot(@centre_x, 0), spot(@centre_y, 0)}

  defp spot(centre, degrees), do: centre - div(@marker, 2) + div(clamp(degrees) * @reach, Goatbot.full_scale())

  defp clamp(degrees), do: max(-Goatbot.full_scale(), min(Goatbot.full_scale(), degrees))

  defp marker_colour(%{engaged: true}), do: Theme.ok()
  defp marker_colour(_report), do: Theme.dim()

  defp deadband do
    {:rect, @centre_x - @dead, @centre_y - @dead, 2 * @dead, 2 * @dead, Theme.muted()}
  end

  defp frame do
    colour = Theme.dim()

    [
      {:rect, @pad_x, @pad_y, @pad, 1, colour},
      {:rect, @pad_x, @pad_y + @pad - 1, @pad, 1, colour},
      {:rect, @pad_x, @pad_y, 1, @pad, colour},
      {:rect, @pad_x + @pad - 1, @pad_y, 1, @pad, colour}
    ]
  end

  defp help(%{field: field, address: nil}) when field != nil do
    Nav.hint([{"Enter", "save robot IP"}], @help_y, Theme.accent())
  end

  defp help(%{field: field}) when field != nil do
    Nav.hint([{"Enter", "save"}, {"Esc", "cancel"}], @help_y, Theme.accent())
  end

  defp help(%{report: %{engaged: true}}) do
    Nav.hint([{"Enter", "stop"}, {"D", "disarm"}], @help_y, Theme.accent())
  end

  defp help(%{report: %{link: :connected}}) do
    Nav.hint([{"A", "arm"}, {"S", "stand"}, {"D", "disarm"}], @help_y, Theme.dim()) ++
      Nav.hint([{"Enter", "drive"}, {"I", "address"}], @help2_y, Theme.dim())
  end

  defp help(_state), do: Nav.hint([{"I", "address"}, {"Esc", "leave"}], @help_y, Theme.dim())
end
