%%
%% AtomVM ESPNOW Port Driver Wrapper
%%
%% Usage:
%%   {ok, Port} = espnow:open([{channel, 1}]).
%%   ok = espnow:send(Port, broadcast, <<"hello">>).
%%   ok = espnow:add_peer(Port, <<MAC:6/binary>>, 0).
%%
%% Messages received by the calling process:
%%   {espnow, rx, FromMacBin, DataBin}
%%   {espnow, tx, broadcast | MacBin, StatusInt}
%%

-module(espnow).

-export([
    open/0, open/1,
    close/1,
    send/3,
    add_peer/3,
    mod_peer/3,
    del_peer/2,
    peer_exists/2,
    get_channel/1
]).

%% @doc Open the ESPNOW port with default options (channel 0, owner = self()).
-spec open() -> {ok, port()} | {error, term()}.
open() ->
    open([]).

%% @doc Open the ESPNOW port.
%% Options:
%%   {channel, 0..14} - WiFi channel (0 = don't change)
%%   {owner, pid()}   - Process to receive RX/TX messages (default: self())
-spec open(proplists:proplist()) -> {ok, port()} | {error, term()}.
open(Options) when is_list(Options) ->
    Owner = proplists:get_value(owner, Options, self()),
    Channel = proplists:get_value(channel, Options, 0),
    PortOptions = [{channel, Channel}, {owner, Owner}],
    try
        Port = open_port({spawn, "espnow"}, PortOptions),
        {ok, Port}
    catch
        error:badarg ->
            {error, already_started};
        Class:Reason ->
            {error, {Class, Reason}}
    end.

%% @doc Close the ESPNOW port.
-spec close(port()) -> ok.
close(Port) when is_port(Port) ->
    port_close(Port),
    ok.

%% @doc Send data via ESPNOW.
%% To = broadcast | <<Mac:6/binary>>
-spec send(port(), broadcast | binary(), binary()) -> ok | {error, term()}.
send(Port, To, Data) when is_port(Port), is_binary(Data) ->
    case To of
        broadcast -> ok;
        B when is_binary(B), byte_size(B) =:= 6 -> ok;
        _ -> error(badarg)
    end,
    gen_server_call(Port, {send, To, Data}).

%% @doc Add a peer for unicast communication.
-spec add_peer(port(), binary(), non_neg_integer()) -> ok | {error, term()}.
add_peer(Port, Mac, Channel) when is_port(Port), is_binary(Mac), byte_size(Mac) =:= 6, is_integer(Channel) ->
    gen_server_call(Port, {add_peer, Mac, Channel}).

%% @doc Modify an existing peer's channel.
-spec mod_peer(port(), binary(), non_neg_integer()) -> ok | {error, term()}.
mod_peer(Port, Mac, Channel) when is_port(Port), is_binary(Mac), byte_size(Mac) =:= 6, is_integer(Channel) ->
    gen_server_call(Port, {mod_peer, Mac, Channel}).

%% @doc Delete a peer.
-spec del_peer(port(), binary()) -> ok | {error, term()}.
del_peer(Port, Mac) when is_port(Port), is_binary(Mac), byte_size(Mac) =:= 6 ->
    gen_server_call(Port, {del_peer, Mac}).

%% @doc Check if a peer exists.
-spec peer_exists(port(), binary()) -> boolean() | {error, term()}.
peer_exists(Port, Mac) when is_port(Port), is_binary(Mac), byte_size(Mac) =:= 6 ->
    gen_server_call(Port, {peer_exists, Mac}).

%% @doc Get the current WiFi channel.
%% Returns the primary channel number (1-14).
%% Note: When connected to an AP, channel is locked to the AP's channel.
-spec get_channel(port()) -> non_neg_integer() | {error, term()}.
get_channel(Port) when is_port(Port) ->
    gen_server_call(Port, get_channel).

%% Internal: Simple gen_server:call style implementation for ports
gen_server_call(Port, Request) ->
    Ref = make_ref(),
    Port ! {'$gen_call', {self(), Ref}, Request},
    receive
        {Ref, Reply} -> Reply
    after 5000 ->
        {error, timeout}
    end.
