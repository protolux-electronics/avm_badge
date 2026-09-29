defmodule Badge.Page.Settings.Bluesky do
  @moduledoc """
  The Bluesky app password, typed on the badge.

  Shows the handle from the profile, whether a password is stored under the
  `bsky_pass` NVS key, and the PDS logins go to. Enter types a new one, `c`
  clears it, `t` tests the stored one.

  A saved password is checked at once through `Badge.Bluesky.Link.check/2`,
  which looks the PDS up and keeps it as `bsky_pds`, so the Bluesky page logs
  in directly and a wrong password shows here rather than there.

  While typing, the arrows are swallowed so typing cannot fling you sideways,
  and Esc backs out without saving. At the top level left, right and Esc are
  left alone for the carousel and the router.
  """

  use Badge.Page

  alias Badge.Bluesky
  alias Badge.Field
  alias Badge.Keyboard
  alias Badge.Nav
  alias Badge.Nvs
  alias Badge.Page.Settings
  alias Badge.Profile
  alias Badge.Readout
  alias Badge.Theme

  @capacity 64

  # Held, not tapped, so the password is only visible while you ask for it.
  @view_key ~c"Fn"

  @handle_y Settings.content_top()
  @stored_y @handle_y + 18
  @server_y @handle_y + 36
  @notice_y @handle_y + 62
  @note_y @handle_y + 96
  @help_y 216

  @name_y Settings.content_top() + 8
  @prompt_y Settings.content_top() + 46
  @hint_y Settings.content_top() + 68
  @field_y Settings.content_top() + 106

  @columns 38

  @note "Use an app password, made at"
  @note_where "bsky.app > Settings > App passwords"

  @impl true
  def title, do: "Bluesky"

  @impl true
  def init do
    %{
      mode: :view,
      loaded: false,
      handle: nil,
      stored: false,
      pds: nil,
      field: Field.new(@capacity),
      show: false,
      pending: nil,
      check_with: nil,
      check: :none,
      notice: nil
    }
  end

  # Hardware is only touched here, never from a key handler.
  @impl true
  def tick(state), do: state |> load() |> persist() |> start_check() |> poll() |> peek()

  defp load(%{loaded: true} = state), do: state

  defp load(state) do
    state = apply_stored(Map.get(Profile.load(), :bluesky), Nvs.get(:bsky_pass), state)

    %{state | pds: blank_to_nil(Nvs.get(:bsky_pds))}
  end

  @doc "Takes the profile's handle and the stored password. Called instead of `tick/1`."
  @spec apply_stored(binary | nil, binary | nil, map) :: map
  def apply_stored(handle, password, state) do
    %{state | loaded: true, handle: Bluesky.actor(handle), stored: stored?(password)}
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp stored?(nil), do: false
  defp stored?(""), do: false
  defp stored?(_password), do: true

  defp persist(%{pending: nil} = state), do: state

  defp persist(%{pending: {:save, password}} = state) do
    case Nvs.put(:bsky_pass, password) do
      :ok -> check_after_save(written(:ok, true, "saved", state), password)
      error -> written(error, true, "saved", state)
    end
  end

  defp persist(%{pending: :clear} = state),
    do: written(Nvs.delete(:bsky_pass), false, "cleared", state)

  @doc "Takes the result of a pending write. Called instead of `tick/1`."
  @spec written(term, boolean, binary, map) :: map
  def written(:ok, stored, notice, state),
    do: %{state | pending: nil, stored: stored, notice: notice}

  def written(error, _stored, _notice, state) do
    :io.format(~c"Bluesky: password write failed ~p~n", [error])

    %{state | pending: nil, notice: "could not save"}
  end

  @doc "Queues a check of a password just saved, when there is a handle to check it for."
  @spec check_after_save(map, binary) :: map
  def check_after_save(%{stored: true, handle: handle} = state, password) when handle != nil,
    do: %{state | check_with: password}

  def check_after_save(state, _password), do: state

  defp start_check(%{check_with: nil} = state), do: state
  defp start_check(%{check_with: :stored} = state), do: begin(state, Nvs.get(:bsky_pass))
  defp start_check(%{check_with: password} = state), do: begin(state, password)

  defp begin(state, password) when password == nil or password == "",
    do: %{state | check_with: nil}

  defp begin(state, password) do
    Bluesky.Link.check(state.handle, password)

    %{state | check_with: nil, check: :checking, notice: nil}
  end

  # Only while a check is out: a call from here costs a round of every process.
  defp poll(%{check: :checking} = state), do: apply_check(Bluesky.Link.check_status(), state)
  defp poll(state), do: state

  @doc "Takes where the link's check stands. Called instead of `tick/1`."
  @spec apply_check(term, map) :: map
  def apply_check({:ok, pds} = check, state), do: %{state | check: check, pds: pds}
  def apply_check({:error, _reason} = check, state), do: %{state | check: check}
  def apply_check(_under_way, state), do: state

  defp peek(%{mode: :entry} = state), do: %{state | show: Keyboard.holding?(@view_key)}
  defp peek(state), do: state

  @doc "What is waiting to be written on the next tick: `{:save, password}`, `:clear` or nil."
  @spec pending(map) :: {:save, binary} | :clear | nil
  def pending(%{pending: pending}), do: pending

  @impl true
  def handle_key(event, %{mode: :entry} = state), do: entry_key(event, state)

  def handle_key({:edit, :newline}, state) do
    {:ok, %{state | mode: :entry, field: Field.new(@capacity), show: false, notice: nil}}
  end

  def handle_key({:char, char}, %{stored: true} = state) when char == ?c or char == ?C,
    do: {:ok, %{state | pending: :clear, check: :none}}

  def handle_key({:char, char}, %{stored: true, handle: handle, check: check} = state)
      when (char == ?t or char == ?T) and handle != nil and check != :checking,
      do: {:ok, %{state | check_with: :stored, notice: nil}}

  def handle_key(_event, _state), do: :ignore

  defp entry_key({:nav, :home}, state), do: {:ok, to_view(state)}
  defp entry_key({:move, _direction}, state), do: {:ok, state}

  defp entry_key({:char, char}, state),
    do: {:ok, %{state | field: Field.insert(state.field, char)}}

  defp entry_key({:edit, :backspace}, state),
    do: {:ok, %{state | field: Field.backspace(state.field)}}

  defp entry_key({:edit, :newline}, state) do
    case Field.value(state.field) do
      "" -> {:ok, to_view(state)}
      password -> {:ok, %{to_view(state) | pending: {:save, password}}}
    end
  end

  defp entry_key(_event, state), do: {:ok, state}

  defp to_view(state), do: %{state | mode: :view, field: Field.new(@capacity), show: false}

  @impl true
  def render(%{mode: :entry} = state) do
    [
      centred(handle(state), @name_y, Theme.fg()),
      centred("enter app password below", @prompt_y, Theme.dim()),
      centred("hold Fn to view", @hint_y, Theme.dim()),
      centred(entry(state), @field_y, Theme.select())
    ] ++ Nav.hint([{"Enter", "save"}, {"Esc", "back"}], @help_y, Theme.dim(), :centre)
  end

  def render(state) do
    Readout.right_row("handle", handle(state), @handle_y, handle_colour(state)) ++
      Readout.right_row("password", stored(state), @stored_y, stored_colour(state)) ++
      Readout.right_row("server", server(state), @server_y, server_colour(state)) ++
      status_line(state) ++
      [centred(@note, @note_y, Theme.muted()), centred(@note_where, @note_y + 18, Theme.muted())] ++
      Nav.hint(hints(state), @help_y, Theme.dim(), :centre)
  end

  defp handle(%{handle: nil}), do: "not set"
  defp handle(%{handle: handle}), do: "@" <> handle

  defp handle_colour(%{handle: nil}), do: Theme.warn()
  defp handle_colour(_state), do: Theme.fg()

  defp stored(%{stored: true}), do: "stored"
  defp stored(_state), do: "not set"

  defp stored_colour(%{stored: true}), do: Theme.ok()
  defp stored_colour(_state), do: Theme.dim()

  defp server(%{pds: nil}), do: "found at login"
  defp server(%{pds: pds}), do: host(pds)

  defp server_colour(%{pds: nil}), do: Theme.dim()
  defp server_colour(_state), do: Theme.fg()

  defp host(<<"https://", rest::binary>>), do: rest
  defp host(<<"http://", rest::binary>>), do: rest
  defp host(url), do: url

  # A check says more than a saved notice, so it wins the line.
  defp status_line(%{check: :none} = state), do: notice(state)

  defp status_line(%{check: :checking}),
    do: [centred("checking login...", @notice_y, Theme.muted())]

  defp status_line(%{check: {:ok, pds}}),
    do: [centred(clip("logged in via " <> host(pds)), @notice_y, Theme.ok())]

  defp status_line(%{check: {:error, reason}}) do
    [
      centred("login failed", @notice_y, Theme.alert()),
      centred(clip(Bluesky.describe(reason)), @notice_y + 18, Theme.dim())
    ]
  end

  defp clip(text) when byte_size(text) <= @columns, do: text
  defp clip(text), do: :binary.part(text, 0, @columns)

  defp notice(%{notice: nil}), do: []

  defp notice(%{notice: "could not save" = notice}),
    do: [centred(notice, @notice_y, Theme.alert())]

  defp notice(%{notice: notice}), do: [centred(notice, @notice_y, Theme.ok())]

  defp hints(%{stored: true, handle: handle}) when handle != nil,
    do: [{"Enter", "change"}, {"t", "test"}, {"c", "clear"}]

  defp hints(%{stored: true}), do: [{"Enter", "change"}, {"c", "clear"}]
  defp hints(_state), do: [{"Enter", "set password"}]

  # Held Fn reveals what was typed; otherwise only its length shows.
  defp entry(%{show: true} = state), do: Field.value(state.field) <> "_"
  defp entry(state), do: Field.masked(state.field) <> "_"

  defp centred(text, y, colour) do
    {:text, Readout.centre_x(text), y, :default16px, colour, Theme.bg(), text}
  end
end
