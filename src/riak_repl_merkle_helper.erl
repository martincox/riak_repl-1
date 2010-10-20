%% Riak EnterpriseDS
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.

%%
%% 'merkle' tree helper process.
%% Must exit after returning an {Ref, {error, Blah}} or {Ref, merkle_built}.
%%
%%
-module(riak_repl_merkle_helper).
-behaviour(gen_server).

%% API
-export([start_link/1,
         make_merkle/3,
         cancel/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("riak_repl.hrl").

-record(state, {owner_fsm,
                ref,
                merkle_pid,
                folder_pid,
                filename,
                buf=[],
                size=0}).
                
%% ===================================================================
%% Public API
%% ===================================================================

start_link(OwnerFsm) ->
    gen_server:start_link(?MODULE, [OwnerFsm], []).

make_merkle(Pid, Partition, Filename) ->
    gen_server:call(Pid, {make_merkle, Partition, Filename}).

cancel(undefined) ->
    ok;
cancel(Pid) ->
    gen_server:call(Pid, cancel).

%% ====================================================================
%% gen_server callbacks
%% ====================================================================

init([OwnerFsm]) ->
    process_flag(trap_exit, true),
    {ok, #state{owner_fsm = OwnerFsm}}.
    
handle_call(cancel, _From, State) ->
    case State#state.merkle_pid of
        undefined ->
            ok;
        Pid when is_pid(Pid) ->
            couch_merkle:close(Pid)
    end,
    {stop, normal, ok, State};
handle_call({make_merkle, Partition, FileName}, _From, State) ->
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    OwnerNode = riak_core_ring:index_owner(Ring, Partition),
    case lists:member(OwnerNode, riak_core_node_watcher:nodes(riak_kv)) of
        true ->
            {ok, DMerkle} = couch_merkle:open(FileName),
            Self = self(),
            Worker = fun() ->
                             %% Spend as little time on the vnode as possible,
                             %% accept there could be a potentially huge message queue
                             Folder = fun(K, V, MPid) -> 
                                              gen_server:cast(MPid, {K, erlang:phash2(V)}),
                                              MPid
                                      end,
                             riak_kv_vnode:fold({Partition,OwnerNode}, Folder, Self),
                             gen_server:cast(Self, finish)
                     end,
            FolderPid = spawn_link(Worker),
            Ref = make_ref(),
            NewState = State#state{ref = Ref, 
                                   merkle_pid = DMerkle, 
                                   folder_pid = FolderPid,
                                   filename = FileName},
            {reply, {ok, Ref}, NewState};
        false ->
            {stop, normal, {error, node_not_available}, State}
    end.

handle_cast({K, H}, State) ->
    PackedKey = riak_repl_util:binpack_bkey(K),
    NewSize = State#state.size+size(PackedKey)+4,
    NewBuf = [{PackedKey, H}|State#state.buf],
    case NewSize >= ?MERKLE_BUFSZ of 
        true ->
            couch_merkle:update_many(State#state.merkle_pid, NewBuf),
            {noreply, State#state{buf = [], size = 0}};
        false ->
            {noreply, State#state{buf = NewBuf, size = NewSize}}
    end;
handle_cast(finish, State) ->
    couch_merkle:update_many(State#state.merkle_pid, State#state.buf),
    %% Close couch - beware, the close call is a cast so the process
    %% may still be alive for a while.  Add a monitor and directly
    %% receive the message - it should only be for a short time
    %% and nothing else 
    _Mref = erlang:monitor(process, State#state.merkle_pid),
    couch_merkle:close(State#state.merkle_pid),
    {noreply, State}.

handle_info({'EXIT', Pid,  Reason}, State) when Pid =:= State#state.merkle_pid ->
    case Reason of 
        normal ->
            {noreply, State};
        _ ->
            gen_fsm:send_event(State#state.owner_fsm, 
                               {State#state.ref, {error, {merkle_died, Reason}}}),
            {stop, normal, State}
    end;
handle_info({'EXIT', Pid,  Reason}, State) when Pid =:= State#state.folder_pid ->
    case Reason of
        normal ->
            {noreply, State};
        _ ->
            gen_fsm:send_event(State#state.owner_fsm, 
                               {State#state.ref, {error, {folder_died, Reason}}}),
            {stop, normal, State}
    end;
handle_info({'DOWN', _Mref, process, Pid, Exit}, State=#state{merkle_pid = Pid}) ->
    case Exit of
        normal ->
            Msg = {State#state.ref, merkle_built};
        _ ->
            Msg = {State#state.ref, {error, {merkle_failed, Exit}}}
    end,
    gen_fsm:send_event(State#state.owner_fsm, Msg),        
    {stop, normal, State#state{buf = [], size = 0}}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ====================================================================
%% Internal functions
%% ====================================================================
