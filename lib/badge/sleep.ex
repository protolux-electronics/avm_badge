defmodule Badge.Sleep do
  @moduledoc """
  When the CPU may stop. `Badge.UI` counts the ticks after the screen blanks
  and asks here before handing the sleep itself to `Badge.Keyboard`.
  """

  @after_screen_ms 30_000

  @doc "How many ticks of `interval` milliseconds after the screen blanks the CPU sleeps."
  @spec ticks(pos_integer) :: pos_integer
  def ticks(interval), do: div(@after_screen_ms, interval)

  @doc """
  Whether a sleep is allowed right now. USB power, a download in flight and an
  open Bluetooth link all refuse.
  """
  @spec allowed?(map) :: boolean
  def allowed?(%{usb: true}), do: false
  def allowed?(%{downloading: true}), do: false
  def allowed?(%{bluetooth: true}), do: false
  def allowed?(_holds), do: true
end
