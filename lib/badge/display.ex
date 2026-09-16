defmodule Badge.Display do
  @moduledoc "The display operations shared by the AtomGL panel and host simulator."

  @type t :: {module, term}

  @callback update(term, [tuple]) :: :ok
  @callback register_font(term, atom, binary) :: :ok
  @callback deregister_font(term, atom) :: :ok

  @doc "Draws a complete frame."
  @spec update(t, [tuple]) :: :ok
  def update({backend, display}, items), do: backend.update(display, items)

  @doc "Makes a font available to subsequent frames."
  @spec register_font(t, atom, binary) :: :ok
  def register_font({backend, display}, name, bytes),
    do: backend.register_font(display, name, bytes)

  @doc "Releases a previously registered font."
  @spec deregister_font(t, atom) :: :ok
  def deregister_font({backend, display}, name), do: backend.deregister_font(display, name)
end
