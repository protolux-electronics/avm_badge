defmodule Badge.Page.Settings.Update do
  @moduledoc """
  Firmware updates, over NervesHub.

  The link is held open only while this tab is showing, so entering it costs a
  handshake and leaving it gives the socket back. Everything drawn comes from
  `Badge.Update.Link.status/0`; this page decides nothing for itself except
  whether a confirm is up.

  Nothing installs or restarts without a keypress, and both restarts are
  confirmed, because the badge is on someone.
  """

  use Badge.Page

  alias Badge.Page.Settings
  alias Badge.Readout
  alias Badge.Theme
  alias Badge.Update.Link

  @row_x 8
  @help_y 216

  # How much of a reason from the far side fits beside its label.
  @reason_columns 24

  @hub_y Settings.content_top()
  @id_y @hub_y + Readout.pitch()
  @running_y @id_y + Readout.pitch()
  @slot_y @running_y + Readout.pitch()
  @update_y @slot_y + Readout.pitch() + 8

  @bar_y @update_y + Readout.pitch()
  @bar_x 8
  @bar_w 240
  @bar_h 8

  @impl true
  def title, do: "Update"

  @impl true
  def init, do: %{status: nil, confirm: nil}

  # Opened on the first tick, not in init/0, which runs for every sub-page the
  # moment Settings is entered.
  @impl true
  def tick(%{status: nil} = state) do
    Link.open()

    %{state | status: Link.status()}
  end

  def tick(state), do: %{state | status: Link.status()}

  @impl true
  def leave(_state), do: Link.close()

  @impl true
  def handle_key(event, %{confirm: confirm} = state) when confirm != nil do
    confirming(event, state)
  end

  def handle_key({:edit, :newline}, state), do: enter(state)

  def handle_key({:char, char}, state) when char == ?r or char == ?R do
    case revertable?(state) do
      true -> {:ok, %{state | confirm: :revert}}
      false -> :ignore
    end
  end

  def handle_key(_event, _state), do: :ignore

  # A confirm owns the arrows, so nobody slides off a question they were asked.
  defp confirming({:move, _direction}, state), do: {:ok, state}
  defp confirming({:nav, :home}, state), do: {:ok, %{state | confirm: nil}}

  defp confirming({:edit, :newline}, %{confirm: :reboot} = state) do
    Link.reboot()

    {:ok, %{state | confirm: nil}}
  end

  defp confirming({:edit, :newline}, %{confirm: :revert} = state) do
    Link.revert()

    {:ok, %{state | confirm: nil}}
  end

  defp confirming(_event, state), do: {:ok, state}

  defp enter(%{status: %{state: :offered}} = state) do
    Link.install()

    {:ok, state}
  end

  defp enter(%{status: %{state: :ready}} = state), do: {:ok, %{state | confirm: :reboot}}

  defp enter(%{status: %{state: state_name}} = state)
       when state_name == :failed or state_name == :current do
    Link.check()

    {:ok, state}
  end

  defp enter(_state), do: :ignore

  defp revertable?(%{status: %{trial: true}}), do: true
  defp revertable?(_state), do: false

  @impl true
  def render(%{status: nil} = state), do: render(%{state | status: unknown()})

  def render(%{confirm: confirm} = state) when confirm != nil do
    rows(state) ++ [help(confirm_text(confirm), Theme.accent())]
  end

  def render(state), do: rows(state) ++ [help(help_text(state), Theme.dim())]

  defp rows(state) do
    hub_row(state) ++
      id_row(state) ++ running_row(state) ++ slot_row(state) ++ update_row(state) ++ bar(state)
  end

  defp unknown do
    %{
      identifier: nil,
      state: :connecting,
      percent: 0,
      offer: nil,
      reason: nil,
      firmware: nil,
      slot: nil,
      target: nil,
      trial: false
    }
  end

  defp hub_row(%{status: status}) do
    Readout.right_row("hub", hub_text(status), @hub_y, hub_colour(status))
  end

  defp hub_text(%{state: :unprovisioned}), do: "not provisioned"
  defp hub_text(%{state: :waiting, reason: nil}), do: "waiting for wifi"
  defp hub_text(%{state: :waiting, reason: reason}), do: clip(reason)
  defp hub_text(%{state: :connecting, reason: nil}), do: "connecting"
  defp hub_text(%{state: :connecting, reason: reason}), do: clip(reason)
  defp hub_text(%{state: :failed, reason: nil}), do: "failed"
  defp hub_text(%{state: :failed, reason: reason}), do: clip(reason)
  defp hub_text(_status), do: "connected"

  defp hub_colour(%{state: :failed}), do: Theme.alert()
  defp hub_colour(%{state: :unprovisioned}), do: Theme.warn()
  defp hub_colour(%{state: :waiting}), do: Theme.fg()
  defp hub_colour(%{state: :connecting, reason: nil}), do: Theme.fg()
  defp hub_colour(%{state: :connecting}), do: Theme.warn()
  defp hub_colour(_status), do: Theme.ok()

  defp id_row(%{status: %{identifier: nil}}),
    do: Readout.right_row("id", "unknown", @id_y, Theme.dim())

  defp id_row(%{status: %{identifier: id}}), do: Readout.right_row("id", id, @id_y, Theme.fg())

  defp running_row(%{status: %{firmware: nil}}) do
    Readout.right_row("running", "unknown", @running_y, Theme.dim())
  end

  defp running_row(%{status: %{firmware: firmware}}) do
    Readout.right_row("running", firmware.name <> " " <> firmware.version, @running_y, Theme.fg())
  end

  defp slot_row(%{status: %{slot: nil}}), do: []

  defp slot_row(%{status: status}) do
    Readout.right_row("slot", slot_text(status), @slot_y, slot_colour(status))
  end

  defp slot_text(%{slot: slot, firmware: nil, trial: trial}), do: slot <> trial_suffix(trial)

  defp slot_text(%{slot: slot, firmware: firmware, trial: trial}) do
    slot <> " " <> firmware.sha <> trial_suffix(trial)
  end

  defp trial_suffix(true), do: " on trial"
  defp trial_suffix(false), do: ""

  defp slot_colour(%{trial: true}), do: Theme.warn()
  defp slot_colour(_status), do: Theme.dim()

  defp update_row(%{status: %{state: :offered, offer: offer}}) do
    Readout.right_row("update", offer <> " available", @update_y, Theme.select())
  end

  defp update_row(%{status: %{state: :downloading, percent: percent}}) do
    Readout.right_row("update", percent_text(percent), @update_y, Theme.accent())
  end

  defp update_row(%{status: %{state: :ready, target: nil}}) do
    Readout.right_row("update", "installed", @update_y, Theme.ok())
  end

  defp update_row(%{status: %{state: :ready, target: target}}) do
    Readout.right_row("update", "installed to " <> target, @update_y, Theme.ok())
  end

  defp update_row(%{status: %{state: :current}}) do
    Readout.right_row("update", "up to date", @update_y, Theme.dim())
  end

  defp update_row(_state), do: []

  # Fill first, so the track shows through as the remainder.
  defp bar(%{status: %{state: :downloading, percent: percent}}) do
    [
      {:rect, @bar_x, @bar_y, div(@bar_w * percent, 100), @bar_h, Theme.accent()},
      {:rect, @bar_x, @bar_y, @bar_w, @bar_h, Theme.dim()}
    ]
  end

  defp bar(_state), do: []

  defp percent_text(percent), do: :erlang.integer_to_binary(percent) <> "%"

  defp confirm_text(:reboot), do: "restart now?   Enter yes   Esc cancel"
  defp confirm_text(:revert), do: "revert slot?   Enter yes   Esc cancel"

  defp help_text(state), do: joined(action_help(state), revert_help(state))

  defp action_help(%{status: %{state: :offered}}), do: "Enter install"
  defp action_help(%{status: %{state: :ready}}), do: "Enter reboot"
  defp action_help(%{status: %{state: :downloading}}), do: "downloading..."
  defp action_help(%{status: %{state: :failed}}), do: "Enter retry"
  defp action_help(%{status: %{state: :current}}), do: "Enter check"
  defp action_help(_state), do: ""

  defp revert_help(state) do
    case revertable?(state) do
      true -> "r revert"
      false -> ""
    end
  end

  defp joined("", ""), do: "nothing to do yet"
  defp joined(action, ""), do: action
  defp joined("", revert), do: revert
  defp joined(action, revert), do: action <> "   " <> revert

  # A reason from the far side can be any length; the row has to stay on panel.
  defp clip(text) when byte_size(text) <= @reason_columns, do: text
  defp clip(<<head::binary-@reason_columns, _rest::binary>>), do: head

  defp help(text, colour), do: {:text, @row_x, @help_y, :default16px, colour, Theme.bg(), text}
end
