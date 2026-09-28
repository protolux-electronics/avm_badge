# The badge VM's native :cjson module, answered by OTP's :json.
defmodule :cjson do
  @moduledoc false

  def decode(text), do: :json.decode(text)
end
