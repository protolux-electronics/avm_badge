defmodule :spi do
  @moduledoc false

  def write(_spi, :pixels, %{write_data: data}) when is_binary(data), do: :ok
end
