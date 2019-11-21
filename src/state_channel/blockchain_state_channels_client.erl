%%%-------------------------------------------------------------------
%% @doc
%% == Blockchain State Channels Client ==
%% @end
%%%-------------------------------------------------------------------
-module(blockchain_state_channels_client).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    credits/1,
    packet/1,
    state_channel/1
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-include("blockchain.hrl").
-include_lib("helium_proto/src/pb/helium_longfi_pb.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(SERVER, ?MODULE).

-record(state, {
    db :: rocksdb:db_handle() | undefined,
    swarm :: pid(),
    state_channels = #{} :: #{binary() => blockchain_state_channel_v1:state_channel()},
    pending = queue:new() :: pending()
}).

-type pending() :: queue:new({blockchain_state_channel_request_v1:request(), any()}).

-define(STATE_CHANNELS, <<"blockchain_state_channels_client.STATE_CHANNELS">>).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec credits(blockchain_state_channel_v1:id()) -> {ok, non_neg_integer()}.
credits(ID) ->
    gen_server:call(?SERVER, {credits, ID}).

packet(Packet) ->
    gen_server:cast(?SERVER, {packet, Packet}).

state_channel(SC) ->
    gen_server:cast(?SERVER, {state_channel, SC}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init([Swarm]=_Args) ->
    lager:info("~p init with ~p", [?SERVER, _Args]),
    {ok, DB} = blockchain_state_channel_db:get(),
    {ok, #state{db=DB, swarm=Swarm}}.

handle_call({credits, ID}, _From, #state{state_channels=SCs}=State) ->
    Reply = case maps:get(ID, SCs, undefined) of
        undefined -> {error, not_found};
        SC -> {ok, blockchain_state_channel_v1:credits(SC)}
    end,
    {reply, Reply, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast({packet, #helium_LongFiRxPacket_pb{oui=OUI,
                                               fingerprint=Fingerprint}=Packet},
            #state{swarm=Swarm, pending=Pending}=State) ->
    lager:debug("got packet ~p", [Packet]),
    case find_routing(OUI) of
        {error, _Reason} ->
             lager:warning("failed to find router for oui ~p:~p", [OUI, _Reason]),
             {noreply, State};
        {ok, Peer} ->
            case blockchain_state_channel_handler:dial(Swarm, Peer, []) of
                {error, _Reason} ->
                    lager:warning("failed to dial ~p:~p", [Peer, _Reason]),
                    {noreply, State};
                {ok, Pid} ->
                    {PubKeyBin, _SigFun} = blockchain_utils:get_pubkeybin_sigfun(Swarm),
                    % TODO: Get amount from somewhere?
                    Req = blockchain_state_channel_request_v1:new(PubKeyBin, 1, Fingerprint),
                    lager:info("sending payment req ~p to ~p", [Req, Peer]),
                    blockchain_state_channel_handler:send_request(Pid, Req),
                    {noreply, State#state{pending=queue:in({Req, Packet}, Pending)}}
            end
    end;
handle_cast({state_channel, UpdateSC}, #state{db=DB, state_channels=SCs, pending=Pending}=State) ->
    ID = blockchain_state_channel_v1:id(UpdateSC),
    lager:debug("received state channel update for ~p", [ID]),
    SC = maps:get(ID, SCs, undefined),
    case check_pending_requests(SC, UpdateSC, Pending) of
        {error, _Reason} ->
            lager:warning("state channel ~p is invalid ~p", [UpdateSC, _Reason]),
            {noreply, State};
        {ok, Found} ->
            % TODO: Send found packets
            ok = blockchain_state_channel_v1:save(DB, UpdateSC),
            {noreply, State#state{state_channels=maps:put(ID, UpdateSC, SCs),
                                  pending=queue:filter(fun(E) -> not queue:member(E, Found) end, Pending)}}
    end;
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason,  #state{db=DB}) ->
    ok = rocksdb:close(DB).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec check_pending_requests(blockchain_state_channel_v1:state_channel() | undefined, blockchain_state_channel_v1:state_channel(), pending()) ->
    {ok, pending()} | {error, any()}.
check_pending_requests(SC, UpdateSC, Pending0) ->
     case blockchain_state_channel_v1:validate(UpdateSC) of
        {error, _}=Error -> 
            Error;
        true ->
            Pending1 = queue:filter(
                fun({Req, Packet}) ->
                    check_packet(Packet, UpdateSC) andalso check_balance(Req, SC, UpdateSC)
                end,
                Pending0
            ),
            {ok, Pending1}
    end.

% TODO: Verify merkle tree here
-spec check_packet(any(), blockchain_state_channel_v1:state_channel()) -> true.
check_packet(_Packet, SC) ->
    _RootHash = blockchain_state_channel_v1:packets(SC),
    true.

-spec check_balance(blockchain_state_channel_request_v1:request(),
                    blockchain_state_channel_v1:state_channel() | undefined,
                    blockchain_state_channel_v1:state_channel()) -> boolean().
check_balance(Req, SC, UpdateSC) ->
    ReqPayee = blockchain_state_channel_request_v1:payee(Req),
    case blockchain_state_channel_v1:balance(ReqPayee, UpdateSC) of
        0 ->
            false;
        NewBalance ->
            ReqAmount = blockchain_state_channel_request_v1:amount(Req),
            OldBalance = case SC == undefined of
                false -> blockchain_state_channel_v1:balance(ReqPayee, SC);
                true -> 0
            end,
            NewBalance-OldBalance >= ReqAmount
    end.

-spec find_routing(non_neg_integer()) -> {ok, string()} | {error, any()}.
find_routing(OUI) ->
    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),
    case blockchain_ledger_v1:find_routing(OUI, Ledger) of
        {error, _}=Error ->
            Error;
        {ok, Routing} ->
            [Address|_] = blockchain_ledger_routing_v1:addresses(Routing),
            {ok, erlang:binary_to_list(Address)}
    end.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-endif.