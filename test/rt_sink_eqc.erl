-module(rt_sink_eqc).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").
-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

-define(SINK_PORT, 5008).
-define(all_remotes, ["a", "b", "c", "d", "e"]).

-record(state, {
    remotes_available = ?all_remotes,
    sources = [],
    rtq = []
    }).

-record(src_state, {
    pids,
    version
    }).

prop_test_() ->
    {timeout, 60000, fun() ->
        ?assert(eqc:quickcheck(?MODULE:prop_main()))
    end}.

prop_main() ->
    ?FORALL(Cmds, commands(?MODULE),
        aggregate(command_names(Cmds), begin
            {H, S, Res} = run_commands(?MODULE, Cmds),
            pretty_commands(?MODULE, Cmds, {H,S,Res}, Res == ok)
        end)).

%% ====================================================================
%% Generators (including commands)
%% ====================================================================

command(S) ->
    oneof(
        [{call, ?MODULE, connect_from_v1, [remote_name(S)]} || S#state.remotes_available /= []] ++
        [{call, ?MODULE, connect_from_v2, [remote_name(S)]} || S#state.remotes_available /= []] ++
        [{call, ?MODULE, disconnect, [elements(S#state.sources)]} || S#state.sources /= []] ++
        [{call, ?MODULE, push_object, [elements(S#state.sources), binary(), g_unique(?all_remotes)]} || S#state.sources /= []] ++
        [{call, ?MODULE, ack_objects, [elements(S#state.sources)]} || S#state.sources /= []]
        ).

g_unique(Possibilites) ->
    ?LET(List, list(elements(Possibilites)), lists:usort(List)).

remote_name(#state{remotes_available = []}) ->
    erlang:error(no_name_available);
remote_name(#state{remotes_available = Remotes}) ->
    oneof(Remotes).

precondition(#state{sources = []}, {call, _, disconnect, _Args}) ->
    false;
precondition(#state{sources = Sources}, {call, _, disconnect, [{Remote, _}]}) ->
    is_tuple(lists:keyfind(Remote, 1, Sources));
precondition(S, {call, _, push_object, _Args}) ->
    S#state.sources /= [];
precondition(S, {call, _, Connect, [Remote]}) when Connect == connect_from_v1; Connect == connect_from_v2 ->
    lists:member(Remote, S#state.remotes_available);
precondition(_S, _Call) ->
    true.

%% ====================================================================
%% state generation
%% ====================================================================

initial_state() ->
    % we will be resetting many mecks, which link to this, but we don't
    % want to kill our test process.
    ?debugMsg("initializing state"),
    process_flag(trap_exit, true),
    riak_repl_test_util:kill_and_wait(riak_repl2_rtsink_conn_sup, kill),
    riak_repl2_rtsink_conn_sup:start_link(),
    riak_repl_test_util:kill_and_wait(riak_core_tcp_mon),
    riak_core_tcp_mon:start_link(),
    riak_repl_test_util:abstract_stateful(),
    abstract_ring_manager(),
    abstract_ranch(),
    riak_repl_test_util:abstract_gen_tcp(),
    bug_rt(),
    start_service_manager(),
    riak_repl2_rtsink_conn:register_service(),
    abstract_fake_source(),
    start_fake_rtq(),
    #state{}.

next_state(S, Res, {call, _, connect_from_v1, [Remote]}) ->
    ?debugMsg("connect v1 next state"),
    SrcState = #src_state{pids = Res, version = 1},
    next_state_connect(Remote, SrcState, S);

next_state(S, Res, {call, _, connect_from_v2, [Remote]}) ->
    ?debugMsg("connect v2 next state"),
    SrcState = #src_state{pids = Res, version = 2},
    next_state_connect(Remote, SrcState, S);

next_state(S, _Res, {call, _, disconnect, [{Remote, _}]}) ->
    ?debugMsg("disconnect next state"),
    Sources2 = lists:keydelete(Remote, 1, S#state.sources),
    Avails = [Remote | S#state.remotes_available],
    S#state{sources = Sources2, remotes_available = Avails};

next_state(S, _Res, {call, _, push_object, [{Remote, SrcState}, Binary, PreviouslyRouted]}) ->
    case SrcState#src_state.version of
        1 ->
            S;
        2 ->
            % TODO on version 2, this will actually need logic.
            S
    end;

next_state(S, _Res, {call, _, ack_objects, _Args}) ->
    ?debugMsg("next state ack objects"),
    S.

next_state_connect(Remote, SrcState, State) ->
    Sources = State#state.sources,
    Sources2 = lists:keystore(Remote, 1, Sources, {Remote, SrcState}),
    Avails = lists:delete(Remote, State#state.remotes_available),
    State#state{sources = Sources2, remotes_available = Avails}.

%% ====================================================================
%% postcondition
%% ====================================================================

postcondition(_S, {call, _, connect_from_v1, [_Remote]}, {error, _Reses}) ->
    false;
postcondition(_S, {call, _, connect_from_v1, [_Remote]}, {Source, Sink}) ->
    is_pid(Source) andalso is_pid(Sink);

postcondition(_S, {call, _, disconnect, [_Remote]}, {Source, Sink}) ->
    not ( is_process_alive(Source) orelse is_process_alive(Sink) );

postcondition(_S, {call, _, push_object, [{_Remote, #src_state{version = 1}}, _Binary, _AlreadyRouted]}, {error, timeout}) ->
    true;
postcondition(_S, {call, _, push_object, _Args}, {error, _What}) ->
    false;

postcondition(_S, _C, _R) ->
    ?debugMsg("post condition"),
    true.

%% ====================================================================
%% test callbacks
%% ====================================================================

connect_from_v1(Remote) ->
    ?debugMsg("connect v1"),
    stateful:set(symbolic_clustername, Remote),
    SourceRes = connect_source({1,0}),
    SinkRes = read_rt_bug(),
    case {SourceRes, SinkRes} of
        {{ok, Source}, {ok, Sink}} ->
            {Source, Sink};
        _ ->
            {error, {SourceRes, SinkRes}}
    end.

connect_from_v2(_Remotes) ->
    ?debugMsg("connect v2 test"),
    % TODO make real tests.
    Source = spawn(fun() -> ok end),
    Sink = spawn(fun() -> ok end),
    {Source, Sink}.

disconnect({_Remote, State}) ->
    {Source, Sink} = State#src_state.pids,
    riak_repl_test_util:kill_and_wait(Source),
    riak_repl_test_util:wait_for_pid(Sink),
    {Source, Sink}.

push_object({_Remote, #src_state{version = 2}}, _, _) ->
    % TODO v2 on the way, baby!
    ok;
push_object({Remote, SrcState}, Binary, AlreadyRouted) ->
    {Source, _Sink} = SrcState#src_state.pids,
    ok = fake_source_push_obj(Source, Binary, AlreadyRouted),
    read_fake_rtq_bug().

ack_objects(_) ->
    ok.

%% ====================================================================
%% helpful utility functions
%% ====================================================================

abstract_ranch() ->
    ?debugMsg("abstracting ranch"),
    riak_repl_test_util:reset_meck(ranch),
    meck:expect(ranch, accept_ack, fun(_Listener) -> ok end),
    meck:expect(ranch, start_listener, fun(_IpPort, _MaxListeners, _RanchTCP, RanchOpts, _Module, _SubProtos) ->
        riak_repl_test_util:kill_and_wait(sink_listener),
        ?debugMsg("ranch start listener"),
        IP = proplists:get_value(ip, RanchOpts),
        Port = proplists:get_value(port, RanchOpts),
        Pid = proc_lib:spawn_link(?MODULE, sink_listener, [IP, Port, RanchOpts]),
        register(sink_listener, Pid),
        {ok, Pid}
    end).

abstract_ring_manager() ->
    riak_repl_test_util:reset_meck(riak_core_ring_manager, [passthrough]),
    meck:expect(riak_core_ring_manager, get_my_ring, fun() ->
        {ok, fake_ring}
    end),
    riak_repl_test_util:reset_meck(riak_core_ring, [passthrough]),
    meck:expect(riak_core_ring, get_meta, fun
        (symbolic_clustername, fake_ring) ->
            {ok, stateful:symbolic_clustername()};
        (_Key, fake_ring) ->
            undefined;
        (Key, Ring) ->
            meck:passthrough([Key, Ring])
    end).

sink_listener(Ip, Port, Opts) ->
    ?debugFmt("prelisten arg dump: ~p, ~p, ~p", [Ip, Port, Opts]),
    {ok, Sock} = gen_tcp:listen(Port, [{ip, Ip}, binary, {reuseaddr, true}, {active, false} | Opts]),
    ?debugFmt("Listening on ~p:~p", [Ip, Port]),
    sink_listener(Sock).

sink_listener(ListenSock) ->
    ?debugMsg("preaccept"),
    {ok, Socket} = gen_tcp:accept(ListenSock),
    ?debugMsg("post accept"),
    {ok, Pid} = riak_core_service_mgr:start_link(sink_listener, Socket, gen_tcp, []),
    gen_tcp:controlling_process(Socket, Pid),
    ?debugMsg("post start link"),
    sink_listener(ListenSock).

bug_rt() ->
    ?debugMsg("installing bug on register sink"),
    riak_repl_test_util:reset_meck(riak_repl2_rt, [passthrough]),
    WhoToTell = self(),
    meck:expect(riak_repl2_rt, register_sink, fun(SinkPid) ->
        ?debugFmt("Sending bug to ~p", [WhoToTell]),
        WhoToTell ! {sink_pid, SinkPid},
        meck:passthrough([SinkPid])
    end),
    riak_repl_test_util:kill_and_wait(riak_repl2_rt),
    riak_repl2_rt:start_link().

read_rt_bug() ->
    read_rt_bug(3000).

read_rt_bug(Timeout) ->
    ?debugFmt("reading rt bug until ~p", [Timeout]),
    receive
        {sink_pid, Pid} ->
            {ok, Pid}
    after Timeout ->
        {error, timeout}
    end.

start_service_manager() ->
    ?debugMsg("Starting service manager"),
    riak_repl_test_util:kill_and_wait(riak_core_service_manager),
    riak_core_service_mgr:start_link({"127.0.0.1", ?SINK_PORT}).

abstract_fake_source() ->
    ?debugMsg("abstacting fake source"),
    riak_repl_test_util:reset_meck(fake_source),
    meck:expect(fake_source, connected, fun(Socket, Transport, Endpoint, Proto, Pid, Props) ->
        ?debugFmt("fake source connect fun call!~n"
            "    Socket: ~p~n"
            "    Transport: ~p~n"
            "    Endpoint: ~p~n"
            "    Proto: ~p~n"
            "    Pid: ~p~n"
            "    Props: ~p", [Socket, Transport, Endpoint, Proto, Pid, Props]),
        Transport:controlling_process(Socket, Pid),
        Transport:setopts(Socket, [{active, once}]),
        gen_server:call(Pid, {connected, Socket, Endpoint, Proto})
    end).

start_fake_rtq() ->
    WhoToTell = self(),
    riak_repl_test_util:kill_and_wait(fake_rtq),
    riak_repl_test_util:reset_meck(riak_repl2_rtq, [passthrough]),
    Pid = proc_lib:spawn_link(?MODULE, fake_rtq, [WhoToTell]),
    register(fake_rtq, Pid),
    meck:expect(riak_repl2_rtq, push, fun(NumItems, Bin, Meta) ->
        gen_server:cast(fake_rtq, {push, NumItems, Bin, Meta})
    end),
    {ok, Pid}.

fake_rtq(Bug) ->
    fake_rtq(Bug, []).

fake_rtq(Bug, Queue) ->
    receive
        {'$gen_cast', {push, NumItems, Bin, Meta}} ->
            Bug ! {push, NumItems, Bin, Meta},
            Queue2 = [{NumItems, Bin, Meta} | Queue],
            fake_rtq(Bug, Queue);
        Else ->
            ?debugFmt("I don't even...~p", [Else]),
            ok
    end.

read_fake_rtq_bug() ->
    read_fake_rtq_bug(3000).

read_fake_rtq_bug(Timeout) ->
    receive
        {push, _NumItems, _Bin, _Metas} = Got ->
            {ok, Got}
    after Timeout ->
        {error, timeout}
    end.

connect_source(Version) ->
    ?debugFmt("starting fake source version ~p", [Version]),
    Pid = proc_lib:spawn_link(?MODULE, fake_source_loop, [undefined, Version]),
    TcpOptions = [{keepalive, true}, {nodelay, true}, {packet, 0},
        {active, false}],
    ClientSpec = {{realtime, [Version]}, {TcpOptions, fake_source, Pid}},
    IpPort = {{127,0,0,1}, ?SINK_PORT},
    ?debugFmt("attempting to connect~n"
        "    IpPort: ~p~n"
        "    ClientSpec: ~p", [IpPort, ClientSpec]),
    ConnRes = riak_core_connection:sync_connect(IpPort, ClientSpec),
    ?debugFmt("Connection result: ~p", [ConnRes]),
    {ok, Pid}.

fake_source_push_obj(Source, Binary, AlreadyRouted) ->
    gen_server:call(Source, {push, Binary, AlreadyRouted}).

fake_source_loop(undefined, Version) ->
    ?debugMsg("fake loop, no socket"),
    receive
        {'$gen_call', From, {connected, Socket, _EndPoint, {realtime, Version, Version}}} ->
            ?debugFmt("Connection achieved with valid version: ~p", [Version]),
            gen_server:reply(From, ok),
            fake_source_loop(Socket, Version, 1);
        {'$gen_call', From, Aroo} ->
            ?debugFmt("Cannot handle request: ~p", [Aroo]),
            gen_server:reply(From, {error, badcall}),
            exit({badcall, Aroo});
        What ->
            ?debugFmt("lolwut? ~p", [What]),
            fake_source_loop(undefined, Version)
    end.

fake_source_loop(Socket, Version, Seq) ->
    receive
        {'$gen_call', From, {push, Binary, AlreadyRouted}} when Version == {1,0} ->
            Payload = riak_repl2_rtframe:encode(objects, {Seq, Binary}),
            gen_tcp:send(Socket, Payload),
            gen_server:reply(From, ok),
            fake_source_loop(Socket, Version, Seq + 1);
        {'$gen_call', From, Aroo} ->
            ?debugFmt("Cannot handle request: ~p", [Aroo]),
            gen_server:reply(From, {error, badcall}),
            exit({badcall, Aroo});
        {tcp, Socket, Bin} ->
            inet:setopts(Socket, [{active, once}]),
            fake_source_loop(Socket, Version)
    end.