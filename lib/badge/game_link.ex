defmodule Badge.GameLink do
  @moduledoc """
  Shared types for GameLink sessions, the largest payload a frame carries and
  the text an app shows while it waits.
  """

  alias Badge.GameLink.Wire

  @type slot :: 0..7
  @type address :: binary
  @type chip_reference :: <<_::48>>
  @type session :: <<_::16>>
  @type token :: <<_::32>>
  @type scope :: %{
          required(:channel) => 0..14,
          required(:net) => <<_::16>>,
          optional(:ssid) => binary
        }
  @type mode :: :latest | :reliable
  @type reason ::
          :no_radio
          | :other_no_radio
          | :no_wifi
          | :other_no_wifi
          | :different_network
          | {:no_wifi | :different_network, ssid :: binary}
          | :other_access_point
          | :unreachable
          | :searching
          | :full
          | :started
          | :update_needed
  @type event ::
          {:waiting, reason}
          | {:session, me :: slot, members :: [{slot, name :: binary}]}
          | {:joined, slot, name :: binary}
          | {:left, slot, :bye | :timeout}
          | {:message, from :: slot, payload :: binary}
          | {:overflow, slot}
          | {:closed, :host_left | :reset}
  @type offer :: %{
          version: pos_integer,
          app: binary | nil,
          session: session | nil,
          token: token | nil,
          transport: :espnow | {:other, byte} | nil,
          scope: scope | nil,
          host_reference: chip_reference,
          host_addr: address | nil,
          available: boolean,
          present: boolean,
          admitting: boolean
        }

  @doc "The largest app payload a frame carries."
  @spec max_payload() :: 200
  def max_payload, do: Wire.max_payload()

  @doc """
  The text an app shows for a waiting reason, at most 36 characters of code
  page 437; an unknown one gives the generic wait.
  """
  @spec hint(reason | term) :: binary
  def hint({reason, ssid}) when reason == :no_wifi or reason == :different_network do
    name = Badge.Text.cp437(ssid)
    "Join " <> :binary.part(name, 0, min(byte_size(name), 23)) <> " to play"
  end

  def hint(:no_radio), do: "This badge needs a firmware update"
  def hint(:other_no_radio), do: "Other badge needs a firmware update"
  def hint(:no_wifi), do: "Join wifi to play"
  def hint(:other_no_wifi), do: "Other badge has no wifi"
  def hint(:different_network), do: "Join the same wifi to play"
  def hint(:other_access_point), do: "Same wifi, other access point"
  def hint(:unreachable), do: "Waiting for the other badges"
  def hint(:full), do: "Game is full"
  def hint(:started), do: "Game already started"
  def hint(:update_needed), do: "One badge needs a firmware update"
  def hint(_other), do: "Waiting for the other badges"
end
