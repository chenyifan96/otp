%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2018. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%
%%

-module(beam_ssa_opt).
-export([module/2]).

-include("beam_ssa.hrl").
-import(lists, [all/2,append/1,foldl/3,keyfind/3,member/2,reverse/1,reverse/2,
                splitwith/2,takewhile/2,unzip/1]).

-spec module(beam_ssa:b_module(), [compile:option()]) ->
                    {'ok',beam_ssa:b_module()}.

module(#b_module{body=Fs0}=Module, Opts) ->
    Ps = passes(Opts),
    Fs = functions(Fs0, Ps),
    {ok,Module#b_module{body=Fs}}.

functions([F|Fs], Ps) ->
    [function(F, Ps)|functions(Fs, Ps)];
functions([], _Ps) -> [].

-type b_blk() :: beam_ssa:b_blk().
-type b_var() :: beam_ssa:b_var().
-type label() :: beam_ssa:label().

-record(st, {ssa :: beam_ssa:block_map() | [{label(),b_blk()}],
             args :: [b_var()],
             cnt :: label()}).
-define(PASS(N), {N,fun N/1}).

passes(Opts0) ->
    Ps = [?PASS(ssa_opt_split_blocks),
          ?PASS(ssa_opt_element),
          ?PASS(ssa_opt_linearize),
          ?PASS(ssa_opt_record),
          ?PASS(ssa_opt_cse),
          ?PASS(ssa_opt_type),
          ?PASS(ssa_opt_float),
          ?PASS(ssa_opt_live),
          ?PASS(ssa_opt_bsm),
          ?PASS(ssa_opt_bsm_shortcut),
          ?PASS(ssa_opt_misc),
          ?PASS(ssa_opt_blockify),
          ?PASS(ssa_opt_sink),
          ?PASS(ssa_opt_merge_blocks)],
    Negations = [{list_to_atom("no_"++atom_to_list(N)),N} ||
                    {N,_} <- Ps],
    Opts = proplists:substitute_negations(Negations, Opts0),
    [case proplists:get_value(Name, Opts, true) of
         true ->
             P;
         false ->
             {NoName,Name} = keyfind(Name, 2, Negations),
             {NoName,fun(S) -> S end}
     end || {Name,_}=P <- Ps].

function(#b_function{anno=Anno,bs=Blocks0,args=Args,cnt=Count0}=F, Ps) ->
    try
        St = #st{ssa=Blocks0,args=Args,cnt=Count0},
        #st{ssa=Blocks,cnt=Count} = compile:run_sub_passes(Ps, St),
        F#b_function{bs=Blocks,cnt=Count}
    catch
        Class:Error:Stack ->
            #{func_info:={_,Name,Arity}} = Anno,
            io:fwrite("Function: ~w/~w\n", [Name,Arity]),
            erlang:raise(Class, Error, Stack)
    end.

%%%
%%% Trivial sub passes.
%%%

ssa_opt_linearize(#st{ssa=Blocks}=St) ->
    St#st{ssa=beam_ssa:linearize(Blocks)}.

ssa_opt_type(#st{ssa=Linear,args=Args}=St) ->
    St#st{ssa=beam_ssa_type:opt(Linear, Args)}.

ssa_opt_blockify(#st{ssa=Linear}=St) ->
    St#st{ssa=maps:from_list(Linear)}.

%%%
%%% Split blocks before certain instructions to enable more optimizations.
%%%
%%% Splitting before element/2 enables the optimization that swaps
%%% element/2 instructions.
%%%
%%% Splitting before call and make_fun instructions gives more opportunities
%%% for sinking get_tuple_element instructions.
%%%

ssa_opt_split_blocks(#st{ssa=Blocks0,cnt=Count0}=St) ->
    P = fun(#b_set{op={bif,element}}) -> true;
           (#b_set{op=call}) -> true;
           (#b_set{op=make_fun}) -> true;
           (_) -> false
        end,
    {Blocks,Count} = beam_ssa:split_blocks(P, Blocks0, Count0),
    St#st{ssa=Blocks,cnt=Count}.

%%%
%%% Order element/2 calls.
%%%
%%% Order an unbroken chain of element/2 calls for the same tuple
%%% with the same failure label so that the highest element is
%%% retrieved first. That will allow the other element/2 calls to
%%% be replaced with get_tuple_element/3 instructions.
%%%

ssa_opt_element(#st{ssa=Blocks}=St) ->
    %% Collect the information about element instructions in this
    %% function.
    GetEls = collect_element_calls(beam_ssa:linearize(Blocks)),

    %% Collect the element instructions into chains. The
    %% element calls in each chain are ordered in reverse
    %% execution order.
    Chains = collect_chains(GetEls, []),

    %% For each chain, swap the first element call with the
    %% element call with the highest index.
    St#st{ssa=swap_element_calls(Chains, Blocks)}.

collect_element_calls([{L,#b_blk{is=Is0,last=Last}}|Bs]) ->
    case {Is0,Last} of
        {[#b_set{op={bif,element},dst=Element,
                 args=[#b_literal{val=N},#b_var{}=Tuple]},
          #b_set{op=succeeded,dst=Bool,args=[Element]}],
         #b_br{bool=Bool,succ=Succ,fail=Fail}} ->
            Info = {L,Succ,{Tuple,Fail},N},
            [Info|collect_element_calls(Bs)];
        {_,_} ->
            collect_element_calls(Bs)
    end;
collect_element_calls([]) -> [].

collect_chains([{This,_,V,_}=El|Els], [{_,This,V,_}|_]=Chain) ->
    %% Add to the previous chain.
    collect_chains(Els, [El|Chain]);
collect_chains([El|Els], [_,_|_]=Chain) ->
    %% Save the previous chain and start a new chain.
    [Chain|collect_chains(Els, [El])];
collect_chains([El|Els], _Chain) ->
    %% The previous chain is too short; discard it and start a new.
    collect_chains(Els, [El]);
collect_chains([], [_,_|_]=Chain) ->
    %% Save the last chain.
    [Chain];
collect_chains([], _) ->  [].

swap_element_calls([[{L,_,_,N}|_]=Chain|Chains], Blocks0) ->
    Blocks = swap_element_calls_1(Chain, {N,L}, Blocks0),
    swap_element_calls(Chains, Blocks);
swap_element_calls([], Blocks) -> Blocks.

swap_element_calls_1([{L1,_,_,N1}], {N2,L2}, Blocks) when N2 > N1 ->
    %% We have reached the end of the chain, and the first
    %% element instrution to be executed. Its index is lower
    %% than the maximum index found while traversing the chain,
    %% so we will need to swap the instructions.
    #{L1:=Blk1,L2:=Blk2} = Blocks,
    [#b_set{dst=Dst1}=GetEl1,Succ1] = Blk1#b_blk.is,
    [#b_set{dst=Dst2}=GetEl2,Succ2] = Blk2#b_blk.is,
    Is1 = [GetEl2,Succ1#b_set{args=[Dst2]}],
    Is2 = [GetEl1,Succ2#b_set{args=[Dst1]}],
    Blocks#{L1:=Blk1#b_blk{is=Is1},L2:=Blk2#b_blk{is=Is2}};
swap_element_calls_1([{L,_,_,N1}|Els], {N2,_}, Blocks) when N1 > N2 ->
    swap_element_calls_1(Els, {N2,L}, Blocks);
swap_element_calls_1([_|Els], Highest, Blocks) ->
    swap_element_calls_1(Els, Highest, Blocks);
swap_element_calls_1([], _, Blocks) ->
    %% Nothing to do. The element call with highest index
    %% is already the first one to be executed.
    Blocks.

%%%
%%% Record optimization.
%%%
%%% Replace tuple matching with an is_tagged_tuple instruction
%%% when applicable.
%%%

ssa_opt_record(#st{ssa=Linear}=St) ->
    Blocks = maps:from_list(Linear),
    St#st{ssa=record_opt(Linear, Blocks)}.

record_opt([{L,#b_blk{is=Is0,last=Last}=Blk0}|Bs], Blocks) ->
    Is = record_opt_is(Is0, Last, Blocks),
    Blk = Blk0#b_blk{is=Is},
    [{L,Blk}|record_opt(Bs, Blocks)];
record_opt([], _Blocks) -> [].

record_opt_is([#b_set{op={bif,is_tuple},dst=#b_var{name=Bool},
                      args=[Tuple]}=Set],
              Last, Blocks) ->
    case is_tagged_tuple(Tuple, Bool, Last, Blocks) of
        {yes,Size,Tag} ->
            Args = [Tuple,Size,Tag],
            [Set#b_set{op=is_tagged_tuple,args=Args}];
        no ->
            [Set]
    end;
record_opt_is([I|Is], Last, Blocks) ->
    [I|record_opt_is(Is, Last, Blocks)];
record_opt_is([], _Last, _Blocks) -> [].

is_tagged_tuple(#b_var{name=Tuple}, Bool,
                #b_br{bool=#b_var{name=Bool},succ=Succ,fail=Fail},
                Blocks) ->
    SuccBlk = maps:get(Succ, Blocks),
    is_tagged_tuple_1(SuccBlk, Tuple, Fail, Blocks);
is_tagged_tuple(_, _, _, _) -> no.

is_tagged_tuple_1(#b_blk{is=Is,last=Last}, Tuple, Fail, Blocks) ->
    case Is of
        [#b_set{op={bif,tuple_size},dst=#b_var{name=ArityVar},
                args=[#b_var{name=Tuple}]},
         #b_set{op={bif,'=:='},
                dst=#b_var{name=Bool},
                args=[#b_var{name=ArityVar},
                      #b_literal{val=ArityVal}=Arity]}]
        when is_integer(ArityVal) ->
            case Last of
                #b_br{bool=#b_var{name=Bool},succ=Succ,fail=Fail} ->
                    SuccBlk = maps:get(Succ, Blocks),
                    case is_tagged_tuple_2(SuccBlk, Tuple, Fail) of
                        no ->
                            no;
                        {yes,Tag} ->
                            {yes,Arity,Tag}
                    end;
                _ ->
                    no
            end;
        _ ->
            no
    end.

is_tagged_tuple_2(#b_blk{is=Is,
                         last=#b_br{bool=#b_var{name=Bool},fail=Fail}},
                  Tuple, Fail) ->
    is_tagged_tuple_3(Is, Bool, Tuple);
is_tagged_tuple_2(#b_blk{}, _, _) -> no.

is_tagged_tuple_3([#b_set{op=get_tuple_element,
                          dst=#b_var{name=TagVar},
                          args=[#b_var{name=Tuple},#b_literal{val=0}]}|Is],
                  Bool, Tuple) ->
    is_tagged_tuple_4(Is, Bool, TagVar);
is_tagged_tuple_3([_|Is], Bool, Tuple) ->
    is_tagged_tuple_3(Is, Bool, Tuple);
is_tagged_tuple_3([], _, _) -> no.

is_tagged_tuple_4([#b_set{op={bif,'=:='},dst=#b_var{name=Bool},
                          args=[#b_var{name=TagVar},
                                #b_literal{val=TagVal}=Tag]}],
                 Bool, TagVar) when is_atom(TagVal) ->
    {yes,Tag};
is_tagged_tuple_4([_|Is], Bool, TagVar) ->
    is_tagged_tuple_4(Is, Bool, TagVar);
is_tagged_tuple_4([], _, _) -> no.

%%%
%%% Common subexpression elimination (CSE).
%%%
%%% Eliminate repeated evaluation of identical expressions. To avoid
%%% increasing the size of the stack frame, we don't eliminate
%%% subexpressions across instructions that clobber the X registers.
%%%

ssa_opt_cse(#st{ssa=Linear}=St) ->
    M = #{0=>#{}},
    St#st{ssa=cse(Linear, #{}, M)}.

cse([{L,#b_blk{is=Is0,last=Last0}=Blk}|Bs], Sub0, M0) ->
    Es0 = maps:get(L, M0),
    {Is1,Es,Sub} = cse_is(Is0, Es0, Sub0, []),
    Last = sub(Last0, Sub),
    M = cse_successors(Is1, Blk, Es, M0),
    Is = reverse(Is1),
    [{L,Blk#b_blk{is=Is,last=Last}}|cse(Bs, Sub, M)];
cse([], _, _) -> [].

cse_successors([#b_set{op=succeeded,args=[Src]},Bif|_], Blk, EsSucc, M0) ->
    case cse_suitable(Bif) of
        true ->
            %% The previous instruction only has a valid value at the success branch.
            %% We must remove the substitution for Src from the failure branch.
            #b_blk{last=#b_br{succ=Succ,fail=Fail}} = Blk,
            M = cse_successors_1([Succ], EsSucc, M0),
            EsFail = maps:filter(fun(_, Val) -> Val =/= Src end, EsSucc),
            cse_successors_1([Fail], EsFail, M);
        false ->
            %% There can't be any replacement for Src in EsSucc. No need for
            %% any special handling.
            cse_successors_1(beam_ssa:successors(Blk), EsSucc, M0)
    end;
cse_successors(_Is, Blk, Es, M) ->
    cse_successors_1(beam_ssa:successors(Blk), Es, M).

cse_successors_1([L|Ls], Es0, M) ->
    case M of
        #{L:=Es1} ->
            Es = maps:filter(fun(Key, Value) ->
                                     case Es1 of
                                         #{Key:=Value} -> true;
                                         #{} -> false
                                     end
                             end, Es0),
            cse_successors_1(Ls, Es0, M#{L:=Es});
        #{} ->
            cse_successors_1(Ls, Es0, M#{L=>Es0})
    end;
cse_successors_1([], _, M) -> M.

cse_is([#b_set{op=succeeded,dst=Bool,args=[Src]}=I0|Is], Es, Sub0, Acc) ->
    I = sub(I0, Sub0),
    case I of
        #b_set{args=[Src]} ->
            cse_is(Is, Es, Sub0, [I|Acc]);
        #b_set{} ->
            %% The previous instruction has been eliminated. Eliminate the
            %% 'succeeded' instruction too.
            Sub = Sub0#{Bool=>#b_literal{val=true}},
            cse_is(Is, Es, Sub, Acc)
    end;
cse_is([#b_set{dst=Dst}=I0|Is], Es0, Sub0, Acc) ->
    I = sub(I0, Sub0),
    case beam_ssa:clobbers_xregs(I) of
        true ->
            %% Retaining the expressions map across calls and other
            %% clobbering instructions would work, but it would cause
            %% the common subexpressions to be saved to Y registers,
            %% which would probably increase the size of the stack
            %% frame.
            cse_is(Is, #{}, Sub0, [I|Acc]);
        false ->
            case cse_expr(I) of
                none ->
                    %% Not suitable for CSE.
                    cse_is(Is, Es0, Sub0, [I|Acc]);
                {ok,ExprKey} ->
                    case Es0 of
                        #{ExprKey:=Src} ->
                            Sub = Sub0#{Dst=>Src},
                            cse_is(Is, Es0, Sub, Acc);
                        #{} ->
                            Es = Es0#{ExprKey=>Dst},
                            cse_is(Is, Es, Sub0, [I|Acc])
                    end
            end
    end;
cse_is([], Es, Sub, Acc) ->
    {Acc,Es,Sub}.

cse_expr(#b_set{op=Op,args=Args}=I) ->
    case cse_suitable(I) of
        true -> {ok,{Op,Args}};
        false -> none
    end.

cse_suitable(#b_set{op=get_hd}) -> true;
cse_suitable(#b_set{op=get_tl}) -> true;
cse_suitable(#b_set{op=put_list}) -> true;
cse_suitable(#b_set{op=put_tuple}) -> true;
cse_suitable(#b_set{op={bif,Name},args=Args}) ->
    %% Doing CSE for comparison operators would prevent
    %% creation of 'test' instructions.
    Arity = length(Args),
    not (erl_internal:new_type_test(Name, Arity) orelse
         erl_internal:comp_op(Name, Arity) orelse
         erl_internal:bool_op(Name, Arity));
cse_suitable(#b_set{}) -> false.

%%%
%%% Using floating point instructions.
%%%
%%% Use the special floating points version of arithmetic
%%% instructions, if the operands are known to be floats or the result
%%% of the operation will be a float.
%%%
%%% The float instructions were never used in guards before, so we
%%% will take special care to keep not using them in guards.  Using
%%% them in guards would require a new version of the 'fconv'
%%% instruction that would take a failure label.  Since it is unlikely
%%% that using float instructions in guards would be benefical, why
%%% bother implementing a new instruction?  Also, implementing float
%%% instructions in guards in HiPE could turn out to be a lot of work.
%%%

-record(fs,
        {s=undefined :: 'undefined' | 'cleared',
         regs=#{} :: #{beam_ssa:b_var():=beam_ssa:b_var()},
         fail=none :: 'none' | beam_ssa:label(),
         ren=#{} :: #{beam_ssa:label():=beam_ssa:label()},
         non_guards :: gb_sets:set(beam_ssa:label())
        }).

ssa_opt_float(#st{ssa=Linear0,cnt=Count0}=St) ->
    NonGuards0 = float_non_guards(Linear0),
    NonGuards = gb_sets:from_list(NonGuards0),
    Fs = #fs{non_guards=NonGuards},
    {Linear,Count} = float_opt(Linear0, Count0, Fs),
    St#st{ssa=Linear,cnt=Count}.

float_non_guards([{L,#b_blk{is=Is}}|Bs]) ->
    case Is of
        [#b_set{op=landingpad}|_] ->
            [L|float_non_guards(Bs)];
        _ ->
            float_non_guards(Bs)
    end;
float_non_guards([]) -> [?BADARG_BLOCK].

float_opt([{L,Blk0}|Bs], Count, Fs) ->
    Blk = float_rename_phis(Blk0, Fs),
    case float_need_flush(Blk, Fs) of
        true ->
            float_flush(L, Blk, Bs, Count, Fs);
        false ->
            float_opt_1(L, Blk, Bs, Count, Fs)
    end;
float_opt([], Count, _Fs) ->
    {[],Count}.

float_opt_1(L, #b_blk{last=#b_br{fail=F}}=Blk, Bs0,
            Count0, #fs{non_guards=NonGuards}=Fs) ->
    case gb_sets:is_member(F, NonGuards) of
        true ->
            %% This block is not inside a guard.
            %% We can do the optimization.
            float_opt_2(L, Blk, Bs0, Count0, Fs);
        false ->
            %% This block is inside a guard. Don't do
            %% any floating point optimizations.
            {Bs,Count} = float_opt(Bs0, Count0, Fs),
            {[{L,Blk}|Bs],Count}
    end;
float_opt_1(L, Blk, Bs, Count, Fs) ->
    float_opt_2(L, Blk, Bs, Count, Fs).

float_opt_2(L, #b_blk{is=Is0}=Blk0, Bs0, Count0, Fs0) ->
    case float_opt_is(Is0, Fs0, Count0, []) of
        {Is1,Fs1,Count1} ->
            Fs = float_fail_label(Blk0, Fs1),
            Split = float_split_conv(Is1, Blk0),
            {Blks0,Count2} = float_number(Split, L, Count1),
            {Blks,Count3} = float_conv(Blks0, Fs#fs.fail, Count2),
            {Bs,Count} = float_opt(Bs0, Count3, Fs),
            {Blks++Bs,Count};
        none ->
            {Bs,Count} = float_opt(Bs0, Count0, Fs0),
            {[{L,Blk0}|Bs],Count}
    end.

%% Split {float,convert} instructions into individual blocks.
float_split_conv(Is0, Blk) ->
    Br = #b_br{bool=#b_literal{val=true},succ=0,fail=0},
    case splitwith(fun(#b_set{op=Op}) ->
                           Op =/= {float,convert}
                   end, Is0) of
        {Is,[]} ->
            [Blk#b_blk{is=Is}];
        {[_|_]=Is1,[#b_set{op={float,convert}}=Conv|Is2]} ->
            [#b_blk{is=Is1,last=Br},
             #b_blk{is=[Conv],last=Br}|float_split_conv(Is2, Blk)];
        {[],[#b_set{op={float,convert}}=Conv|Is1]} ->
            [#b_blk{is=[Conv],last=Br}|float_split_conv(Is1, Blk)]
    end.

%% Number the blocks that were split.
float_number([B|Bs0], FirstL, Count0) ->
    {Bs,Count} = float_number(Bs0, Count0),
    {[{FirstL,B}|Bs],Count}.

float_number([B|Bs0], Count0) ->
    {Bs,Count} = float_number(Bs0, Count0+1),
    {[{Count0,B}|Bs],Count};
float_number([], Count) ->
    {[],Count}.

%% Insert 'succeeded' instructions after each {float,convert}
%% instruction.
float_conv([{L,#b_blk{is=Is0}=Blk0}|Bs0], Fail, Count0) ->
    case Is0 of
        [#b_set{op={float,convert}}=Conv] ->
            {Bool0,Count1} = new_reg('@ssa_bool', Count0),
            Bool = #b_var{name=Bool0},
            Succeeded = #b_set{op=succeeded,dst=Bool,
                               args=[Conv#b_set.dst]},
            Is = [Conv,Succeeded],
            [{NextL,_}|_] = Bs0,
            Br = #b_br{bool=Bool,succ=NextL,fail=Fail},
            Blk = Blk0#b_blk{is=Is,last=Br},
            {Bs,Count} = float_conv(Bs0, Fail, Count1),
            {[{L,Blk}|Bs],Count};
        [_|_] ->
            case Bs0 of
                [{NextL,_}|_] ->
                    Br = #b_br{bool=#b_literal{val=true},
                               succ=NextL,fail=NextL},
                    Blk = Blk0#b_blk{last=Br},
                    {Bs,Count} = float_conv(Bs0, Fail, Count0),
                    {[{L,Blk}|Bs],Count};
                [] ->
                    {[{L,Blk0}],Count0}
            end
    end.

float_need_flush(#b_blk{is=Is}, #fs{s=cleared}) ->
    case Is of
        [#b_set{anno=#{float_op:=_}}|_] ->
            false;
        _ ->
            true
    end;
float_need_flush(_, _) -> false.

float_opt_is([#b_set{op=succeeded,args=[Src]}=I0],
             #fs{regs=Rs}=Fs, Count, Acc) ->
    case Rs of
        #{Src:=Fr} ->
            I = I0#b_set{args=[Fr]},
            {reverse(Acc, [I]),Fs,Count};
        #{} ->
            {reverse(Acc, [I0]),Fs,Count}
    end;
float_opt_is([#b_set{anno=Anno0}=I0|Is0], Fs0, Count0, Acc) ->
    case Anno0 of
        #{float_op:=FTypes} ->
            Anno = maps:remove(float_op, Anno0),
            I1 = I0#b_set{anno=Anno},
            {Is,Fs,Count} = float_make_op(I1, FTypes, Fs0, Count0),
            float_opt_is(Is0, Fs, Count, reverse(Is, Acc));
        #{} ->
            float_opt_is(Is0, Fs0#fs{regs=#{}}, Count0, [I0|Acc])
    end;
float_opt_is([], Fs, _Count, _Acc) ->
    #fs{s=undefined} = Fs,                      %Assertion.
    none.

float_rename_phis(#b_blk{is=Is}=Blk, #fs{ren=Ren}) ->
    if
        map_size(Ren) =:= 0 ->
            Blk;
        true ->
            Blk#b_blk{is=float_rename_phis_1(Is, Ren)}
    end.

float_rename_phis_1([#b_set{op=phi,args=Args0}=I|Is], Ren) ->
    Args = [float_phi_arg(Arg, Ren) || Arg <- Args0],
    [I#b_set{args=Args}|float_rename_phis_1(Is, Ren)];
float_rename_phis_1(Is, _) -> Is.

float_phi_arg({Var,OldLbl}, Ren) ->
    case Ren of
        #{OldLbl:=NewLbl} ->
            {Var,NewLbl};
        #{} ->
            {Var,OldLbl}
    end.

float_make_op(#b_set{op={bif,Op},dst=Dst,args=As0}=I0,
              Ts, #fs{s=S,regs=Rs0}=Fs, Count0) ->
    {As1,Rs1,Count1} = float_load(As0, Ts, Rs0, Count0, []),
    {As,Is0} = unzip(As1),
    {Fr,Count2} = new_reg('@fr', Count1),
    FrDst = #b_var{name=Fr},
    I = I0#b_set{op={float,Op},dst=FrDst,args=As},
    Rs = Rs1#{Dst=>FrDst},
    Is = append(Is0) ++ [I],
    case S of
        undefined ->
            {Ignore,Count} = new_reg('@ssa_ignore', Count2),
            C = #b_set{op={float,clearerror},dst=#b_var{name=Ignore}},
            {[C|Is],Fs#fs{s=cleared,regs=Rs},Count};
        cleared ->
            {Is,Fs#fs{regs=Rs},Count2}
    end.

float_load([A|As], [T|Ts], Rs0, Count0, Acc) ->
    {Load,Rs,Count} = float_reg_arg(A, T, Rs0, Count0),
    float_load(As, Ts, Rs, Count, [Load|Acc]);
float_load([], [], Rs, Count, Acc) ->
    {reverse(Acc),Rs,Count}.

float_reg_arg(A, T, Rs, Count0) ->
    case Rs of
        #{A:=Fr} ->
            {{Fr,[]},Rs,Count0};
        #{} ->
            {Fr,Count} = new_float_copy_reg(Count0),
            Dst = #b_var{name=Fr},
            I = float_load_reg(T, A, Dst),
            {{Dst,[I]},Rs#{A=>Dst},Count}
    end.

float_load_reg(convert, #b_var{}=Src, Dst) ->
    #b_set{op={float,convert},dst=Dst,args=[Src]};
float_load_reg(convert, #b_literal{val=Val}=Src, Dst) ->
    try float(Val) of
        F ->
            #b_set{op={float,put},dst=Dst,args=[#b_literal{val=F}]}
    catch
        error:_ ->
            %% Let the exception happen at runtime.
            #b_set{op={float,convert},dst=Dst,args=[Src]}
    end;
float_load_reg(float, Src, Dst) ->
    #b_set{op={float,put},dst=Dst,args=[Src]}.

new_float_copy_reg(Count) ->
    new_reg('@fr_copy', Count).

new_reg(Base, Count) ->
    Fr = {Base,Count},
    {Fr,Count+1}.

float_flush(L, Blk, Bs0, Count0, #fs{s=cleared,fail=Fail,ren=Ren0}=Fs0) ->
    {Bool0,Count1} = new_reg('@ssa_bool', Count0),
    Bool = #b_var{name=Bool0},

    %% Insert two blocks before the current block. First allocate
    %% block numbers.
    FirstL = L,                                  %For checkerror.
    MiddleL = Count1,                            %For flushed float regs.
    LastL = Count1 + 1,                          %For original block.
    Count2 = Count1 + 2,

    %% Build the block with the checkerror instruction.
    CheckIs = [#b_set{op={float,checkerror},dst=Bool}],
    FirstBlk = #b_blk{is=CheckIs,last=#b_br{bool=Bool,succ=MiddleL,fail=Fail}},

    %% Build the block that flushes all registers. Note that this must be a
    %% separate block in case the original block begins with a phi instruction,
    %% to avoid embedding a phi instruction in the middle of a block.
    FlushIs = float_flush_regs(Fs0),
    MiddleBlk = #b_blk{is=FlushIs,last=#b_br{bool=#b_literal{val=true},
                                             succ=LastL,fail=LastL}},

    %% The last block is the original unmodified block.
    LastBlk = Blk,

    %% Update state and blocks.
    Ren = Ren0#{L=>LastL},
    Fs = Fs0#fs{s=undefined,regs=#{},fail=none,ren=Ren},
    Bs1 = [{FirstL,FirstBlk},{MiddleL,MiddleBlk},{LastL,LastBlk}|Bs0],
    float_opt(Bs1, Count2, Fs).

float_fail_label(#b_blk{last=Last}, Fs) ->
    case Last of
        #b_br{bool=#b_var{},fail=Fail} ->
            Fs#fs{fail=Fail};
        _ ->
            Fs
    end.

float_flush_regs(#fs{regs=Rs}) ->
    maps:fold(fun(_, #b_var{name={'@fr_copy',_}}, Acc) ->
                      Acc;
                 (Dst, Fr, Acc) ->
                      [#b_set{op={float,get},dst=Dst,args=[Fr]}|Acc]
              end, [], Rs).

%%%
%%% Live optimization.
%%%
%%% Optimize instructions whose values are not used. They could be
%%% removed if they have no side effects, or in a few cases replaced
%%% with a cheaper instructions
%%%

ssa_opt_live(#st{ssa=Linear}=St) ->
    St#st{ssa=live_opt(reverse(Linear), #{}, [])}.

live_opt([{L,Blk0}|Bs], LiveMap0, Acc) ->
    Successors = beam_ssa:successors(Blk0),
    Live0 = live_opt_succ(Successors, L, LiveMap0),
    {Blk,Live} = live_opt_blk(Blk0, Live0),
    LiveMap = live_opt_phis(Blk#b_blk.is, L, Live, LiveMap0),
    live_opt(Bs, LiveMap, [{L,Blk}|Acc]);
live_opt([], _, Acc) -> Acc.

live_opt_succ([S|Ss], L, LiveMap) ->
    Live0 = live_opt_succ(Ss, L, LiveMap),
    Key = {S,L},
    case LiveMap of
        #{Key:=Live} ->
            gb_sets:union(Live, Live0);
        #{S:=Live} ->
            gb_sets:union(Live, Live0);
        #{} ->
            Live0
    end;
live_opt_succ([], _, _) ->
    gb_sets:empty().

live_opt_phis(Is, L, Live0, LiveMap0) ->
    LiveMap = LiveMap0#{L=>Live0},
    Phis = takewhile(fun(#b_set{op=Op}) -> Op =:= phi end, Is),
    case Phis of
        [] ->
            LiveMap;
        [_|_] ->
            PhiArgs = append([Args || #b_set{args=Args} <- Phis]),
            PhiVars = [{P,V} || {#b_var{name=V},P} <- PhiArgs],
            PhiLive0 = rel2fam(PhiVars),
            PhiLive = [{{L,P},gb_sets:union(gb_sets:from_list(Vs), Live0)} ||
                          {P,Vs} <- PhiLive0],
            maps:merge(LiveMap, maps:from_list(PhiLive))
    end.

live_opt_blk(#b_blk{is=Is0,last=Last}=Blk, Live0) ->
    Live1 = gb_sets:union(Live0, gb_sets:from_ordset(beam_ssa:used(Last))),
    {Is,Live} = live_opt_is(reverse(Is0), Live1, []),
    {Blk#b_blk{is=Is},Live}.

live_opt_is([#b_set{op=phi,dst=#b_var{name=Dst}}=I|Is], Live, Acc) ->
    case gb_sets:is_member(Dst, Live) of
        true ->
            live_opt_is(Is, Live, [I|Acc]);
        false ->
            live_opt_is(Is, Live, Acc)
    end;
live_opt_is([#b_set{op=succeeded,dst=#b_var{name=SuccDst}=SuccDstVar,
                    args=[#b_var{name=Dst}]}=SuccI,
             #b_set{dst=#b_var{name=Dst}}=I|Is], Live0, Acc) ->
    case gb_sets:is_member(Dst, Live0) of
        true ->
            case gb_sets:is_member(SuccDst, Live0) of
                true ->
                    Live1 = gb_sets:add(Dst, Live0),
                    Live = gb_sets:delete_any(SuccDst, Live1),
                    live_opt_is([I|Is], Live, [SuccI|Acc]);
                false ->
                    live_opt_is([I|Is], Live0, Acc)
            end;
        false ->
            case live_opt_unused(I) of
                {replace,NewI0} ->
                    NewI = NewI0#b_set{dst=SuccDstVar},
                    live_opt_is([NewI|Is], Live0, Acc);
                keep ->
                    case gb_sets:is_member(SuccDst, Live0) of
                        true ->
                            Live1 = gb_sets:add(Dst, Live0),
                            Live = gb_sets:delete_any(SuccDst, Live1),
                            live_opt_is([I|Is], Live, [SuccI|Acc]);
                        false ->
                            live_opt_is([I|Is], Live0, Acc)
                    end
            end
    end;
live_opt_is([#b_set{op=Op,dst=#b_var{name=Dst}}=I|Is], Live0, Acc) ->
    case gb_sets:is_member(Dst, Live0) of
        true ->
            Live1 = gb_sets:union(Live0, gb_sets:from_ordset(beam_ssa:used(I))),
            Live = gb_sets:delete_any(Dst, Live1),
            live_opt_is(Is, Live, [I|Acc]);
        false ->
            case is_pure(Op) of
                true ->
                    live_opt_is(Is, Live0, Acc);
                false ->
                    Live = gb_sets:union(Live0, gb_sets:from_ordset(beam_ssa:used(I))),
                    live_opt_is(Is, Live, [I|Acc])
            end
    end;
live_opt_is([], Live, Acc) ->
    {Acc,Live}.

is_pure({bif,_}) -> true;
is_pure({float,get}) -> true;
is_pure(bs_extract) -> true;
is_pure(extract) -> true;
is_pure(get_hd) -> true;
is_pure(get_tl) -> true;
is_pure(get_tuple_element) -> true;
is_pure(is_nonempty_list) -> true;
is_pure(is_tagged_tuple) -> true;
is_pure(put_list) -> true;
is_pure(put_tuple) -> true;
is_pure(_) -> false.

live_opt_unused(#b_set{op=get_map_element}=Set) ->
    {replace,Set#b_set{op=has_map_field}};
live_opt_unused(_) -> keep.

%%%
%%% Optimize binary matching instructions.
%%%

ssa_opt_bsm(#st{ssa=Linear}=St) ->
    Extracted0 = bsm_extracted(Linear),
    Extracted = cerl_sets:from_list(Extracted0),
    St#st{ssa=bsm_skip(Linear, Extracted)}.

bsm_skip([{L,#b_blk{is=Is0}=Blk}|Bs], Extracted) ->
    Is = bsm_skip_is(Is0, Extracted),
    [{L,Blk#b_blk{is=Is}}|bsm_skip(Bs, Extracted)];
bsm_skip([], _) -> [].

bsm_skip_is([I0|Is], Extracted) ->
    case I0 of
        #b_set{op=bs_match,args=[#b_literal{val=string}|_]} ->
            [I0|bsm_skip_is(Is, Extracted)];
        #b_set{op=bs_match,dst=Ctx,args=[Type,PrevCtx|Args0]} ->
            I = case cerl_sets:is_element(Ctx, Extracted) of
                    true ->
                        I0;
                    false ->
                        %% The value is never extracted.
                        Args = [#b_literal{val=skip},PrevCtx,Type|Args0],
                        I0#b_set{args=Args}
                end,
            [I|Is];
        #b_set{} ->
            [I0|bsm_skip_is(Is, Extracted)]
    end;
bsm_skip_is([], _) -> [].

bsm_extracted([{_,#b_blk{is=Is}}|Bs]) ->
    case Is of
        [#b_set{op=bs_extract,args=[Ctx]}|_] ->
            [Ctx|bsm_extracted(Bs)];
        _ ->
            bsm_extracted(Bs)
    end;
bsm_extracted([]) -> [].

%%%
%%% Short-cutting binary matching instructions.
%%%

ssa_opt_bsm_shortcut(#st{ssa=Linear}=St) ->
    Positions = bsm_positions(Linear, #{}),
    case map_size(Positions) of
        0 ->
            %% No binary matching instructions.
            St;
        _ ->
            St#st{ssa=bsm_shortcut(Linear, Positions)}
    end.

bsm_positions([{L,#b_blk{is=Is,last=Last}}|Bs], PosMap0) ->
    PosMap = bsm_positions_is(Is, PosMap0),
    case {Is,Last} of
        {[#b_set{op=bs_test_tail,dst=Bool,args=[Ctx,#b_literal{val=Bits0}]}],
         #b_br{bool=Bool,fail=Fail}} ->
            Bits = Bits0 + maps:get(Ctx, PosMap0),
            bsm_positions(Bs, PosMap#{L=>{Bits,Fail}});
        {_,_} ->
            bsm_positions(Bs, PosMap)
    end;
bsm_positions([], PosMap) -> PosMap.

bsm_positions_is([#b_set{op=bs_start_match,dst=New}|Is], PosMap0) ->
    PosMap = PosMap0#{New=>0},
    bsm_positions_is(Is, PosMap);
bsm_positions_is([#b_set{op=bs_match,dst=New,args=Args}|Is], PosMap0) ->
    [_,Old|_] = Args,
    #{Old:=Bits0} = PosMap0,
    Bits = bsm_update_bits(Args, Bits0),
    PosMap = PosMap0#{New=>Bits},
    bsm_positions_is(Is, PosMap);
bsm_positions_is([_|Is], PosMap) ->
    bsm_positions_is(Is, PosMap);
bsm_positions_is([], PosMap) -> PosMap.

bsm_update_bits([#b_literal{val=string},_,#b_literal{val=String}], Bits) ->
    Bits + bit_size(String);
bsm_update_bits([#b_literal{val=utf8}|_], Bits) ->
    Bits + 8;
bsm_update_bits([#b_literal{val=utf16}|_], Bits) ->
    Bits + 16;
bsm_update_bits([#b_literal{val=utf32}|_], Bits) ->
    Bits + 32;
bsm_update_bits([_,_,_,#b_literal{val=Sz},#b_literal{val=U}], Bits)
  when is_integer(Sz) ->
    Bits + Sz*U;
bsm_update_bits(_, Bits) -> Bits.

bsm_shortcut([{L,#b_blk{is=Is,last=Last0}=Blk}|Bs], PosMap) ->
    case {Is,Last0} of
        {[#b_set{op=bs_match,dst=New,args=[_,Old|_]},
          #b_set{op=succeeded,dst=Bool,args=[New]}],
         #b_br{bool=Bool,fail=Fail}} ->
            case PosMap of
                #{Old:=Bits,Fail:={TailBits,NextFail}} when Bits > TailBits ->
                    Last = Last0#b_br{fail=NextFail},
                    [{L,Blk#b_blk{last=Last}}|bsm_shortcut(Bs, PosMap)];
                #{} ->
                    [{L,Blk}|bsm_shortcut(Bs, PosMap)]
            end;
        {_,_} ->
            [{L,Blk}|bsm_shortcut(Bs, PosMap)]
    end;
bsm_shortcut([], _PosMap) -> [].

%%%
%%% Miscellanous optimizations in execution order.
%%%

ssa_opt_misc(#st{ssa=Linear}=St) ->
    St#st{ssa=misc_opt(Linear, #{})}.

misc_opt([{L,#b_blk{is=Is0,last=Last0}=Blk0}|Bs], Sub0) ->
    {Is,Sub} = misc_opt_is(Is0, Sub0, []),
    Last = sub(Last0, Sub),
    Blk = Blk0#b_blk{is=Is,last=Last},
    [{L,Blk}|misc_opt(Bs, Sub)];
misc_opt([], _) -> [].

misc_opt_is([#b_set{op=phi}=I0|Is], Sub0, Acc) ->
    #b_set{dst=Dst,args=Args} = I = sub(I0, Sub0),
    case all_same(Args) of
        true ->
            %% Eliminate the phi node if there is just one source
            %% value or if the values are identical.
            [{Val,_}|_] = Args,
            Sub = Sub0#{Dst=>Val},
            misc_opt_is(Is, Sub, Acc);
        false ->
            misc_opt_is(Is, Sub0, [I|Acc])
    end;
misc_opt_is([#b_set{}=I0|Is], Sub, Acc) ->
    #b_set{op=Op,dst=Dst,args=Args} = I = sub(I0, Sub),
    case make_literal(Op, Args) of
        #b_literal{}=Literal ->
            misc_opt_is(Is, Sub#{Dst=>Literal}, Acc);
        error ->
            misc_opt_is(Is, Sub, [I|Acc])
    end;
misc_opt_is([], Sub, Acc) ->
    {reverse(Acc),Sub}.

all_same([{H,_}|T]) ->
    all(fun({E,_}) -> E =:= H end, T).

make_literal(put_tuple, Args) ->
    case make_literal_list(Args, []) of
        error ->
            error;
        List ->
            #b_literal{val=list_to_tuple(List)}
    end;
make_literal(put_list, [#b_literal{val=H},#b_literal{val=T}]) ->
    #b_literal{val=[H|T]};
make_literal(_, _) -> error.

make_literal_list([#b_literal{val=H}|T], Acc) ->
    make_literal_list(T, [H|Acc]);
make_literal_list([_|_], _) ->
    error;
make_literal_list([], Acc) ->
    reverse(Acc).

%%%
%%% Merge blocks.
%%%

ssa_opt_merge_blocks(#st{ssa=Blocks}=St) ->
    Preds = beam_ssa:predecessors(Blocks),
    St#st{ssa=merge_blocks_1(beam_ssa:rpo(Blocks), Preds, Blocks)}.

merge_blocks_1([L|Ls], Preds0, Blocks0) ->
    case Preds0 of
        #{L:=[P]} ->
            #{P:=Blk0,L:=Blk1} = Blocks0,
            case is_merge_allowed(L, Blk0, Blk1) of
                true ->
                    #b_blk{is=Is0} = Blk0,
                    #b_blk{is=Is1} = Blk1,
                    Is = Is0 ++ Is1,
                    Blk = Blk1#b_blk{is=Is},
                    Blocks1 = maps:remove(L, Blocks0),
                    Blocks2 = maps:put(P, Blk, Blocks1),
                    Successors = beam_ssa:successors(Blk),
                    Blocks = beam_ssa:update_phi_labels(Successors, L, P, Blocks2),
                    Preds = merge_update_preds(Successors, L, P, Preds0),
                    merge_blocks_1(Ls, Preds, Blocks);
                false ->
                    merge_blocks_1(Ls, Preds0, Blocks0)
            end;
        #{} ->
            merge_blocks_1(Ls, Preds0, Blocks0)
    end;
merge_blocks_1([], _Preds, Blocks) -> Blocks.

merge_update_preds([L|Ls], From, To, Preds0) ->
    Ps = [rename_label(P, From, To) || P <- maps:get(L, Preds0)],
    Preds = maps:put(L, Ps, Preds0),
    merge_update_preds(Ls, From, To, Preds);
merge_update_preds([], _, _, Preds) -> Preds.

rename_label(From, From, To) -> To;
rename_label(Lbl, _, _) -> Lbl.

is_merge_allowed(_, _, #b_blk{is=[#b_set{op=peek_message}|_]}) ->
    false;
is_merge_allowed(L, Blk0, #b_blk{}) ->
    case beam_ssa:successors(Blk0) of
        [L] -> true;
        [_|_] -> false
    end.

%%%
%%% When a tuple is matched, the pattern matching compiler generates a
%%% get_tuple_element instruction for every tuple element that will
%%% ever be used in the rest of the function. That often forces the
%%% extracted tuple elements to be stored in Y registers until it's
%%% time to use them. It could also mean that there could be execution
%%% paths that will never use the extracted elements.
%%%
%%% This optimization will sink get_tuple_element instructions, that
%%% is, move them forward in the execution stream to the last possible
%%% block there they will still dominate all uses. That may reduce the
%%% size of stack frames, reduce register shuffling, and avoid
%%% extracting tuple elements on execution paths that never use the
%%% extracted values.
%%%

ssa_opt_sink(#st{ssa=Blocks0}=St) ->
    Linear = beam_ssa:linearize(Blocks0),

    %% Create a map with all variables that define get_tuple_element
    %% instructions. The variable name map to the block it is defined in.
    Defs = maps:from_list(def_blocks(Linear)),

    %% Now find all the blocks that use variables defined by get_tuple_element
    %% instructions.
    Used = used_blocks(Linear, Defs, []),

    %% Calculate dominators.
    Dom0 = beam_ssa:dominators(Blocks0),

    %% It is not safe to move get_tuple_element instructions to blocks
    %% that begin with certain instructions. It is also unsafe to move
    %% the instructions into any part of a receive. To avoid such
    %% unsafe moves, pretend that the unsuitable blocks are not
    %% dominators.
    Unsuitable = unsuitable(Linear, Blocks0),
    Dom = case gb_sets:is_empty(Unsuitable) of
              true ->
                  Dom0;
              false ->
                  F = fun(_, DomBy) ->
                              [L || L <- DomBy,
                                    not gb_sets:is_element(L, Unsuitable)]
                      end,
                  maps:map(F, Dom0)
          end,

    %% Calculate new positions for get_tuple_element instructions. The new
    %% position is a block that dominates all uses of the variable.
    DefLoc = new_def_locations(Used, Defs, Dom),

    %% Now move all suitable get_tuple_element instructions to their
    %% new blocks.
    Blocks = foldl(fun({V,To}, A) ->
                           From = maps:get(V, Defs),
                           move_defs(V, From, To, A)
                   end, Blocks0, DefLoc),
    St#st{ssa=Blocks}.

def_blocks([{L,#b_blk{is=Is}}|Bs]) ->
    def_blocks_is(Is, L, def_blocks(Bs));
def_blocks([]) -> [].

def_blocks_is([#b_set{op=get_tuple_element,dst=#b_var{name=Dst}}|Is], L, Acc) ->
    def_blocks_is(Is, L, [{Dst,L}|Acc]);
def_blocks_is([_|Is], L, Acc) ->
    def_blocks_is(Is, L, Acc);
def_blocks_is([], _, Acc) -> Acc.

used_blocks([{L,Blk}|Bs], Def, Acc0) ->
    Used = beam_ssa:used(Blk),
    Acc = [{V,L} || V <- Used, maps:is_key(V, Def)] ++ Acc0,
    used_blocks(Bs, Def, Acc);
used_blocks([], _Def, Acc) ->
    rel2fam(Acc).

%% unsuitable(Linear, Blocks) -> Unsuitable.
%%  Return an ordset of block labels for the blocks that are not
%%  suitable for sinking of get_tuple_element instructions.

unsuitable(Linear, Blocks) ->
    Predecessors = beam_ssa:predecessors(Blocks),
    Unsuitable0 = unsuitable_1(Linear),
    Unsuitable1 = unsuitable_recv(Linear, Blocks, Predecessors),
    gb_sets:from_list(Unsuitable0 ++ Unsuitable1).

unsuitable_1([{L,#b_blk{is=[#b_set{op=Op}|_]}}|Bs]) ->
    Unsuitable = case Op of
                     bs_extract -> true;
                     bs_put -> true;
                     {float,_} -> true;
                     landingpad -> true;
                     peek_message -> true;
                     wait_timeout -> true;
                     _ -> false
                 end,
    case Unsuitable of
        true ->
            [L|unsuitable_1(Bs)];
        false ->
            unsuitable_1(Bs)
    end;
unsuitable_1([{_,#b_blk{}}|Bs]) ->
    unsuitable_1(Bs);
unsuitable_1([]) -> [].

unsuitable_recv([{L,#b_blk{is=[#b_set{op=Op}|_]}}|Bs], Blocks, Predecessors) ->
    Ls = case Op of
             remove_message ->
                 unsuitable_loop(L, Blocks, Predecessors);
             recv_next ->
                 unsuitable_loop(L, Blocks, Predecessors);
             _ ->
                 []
         end,
    Ls ++ unsuitable_recv(Bs, Blocks, Predecessors);
unsuitable_recv([_|Bs], Blocks, Predecessors) ->
    unsuitable_recv(Bs, Blocks, Predecessors);
unsuitable_recv([], _, _) -> [].

unsuitable_loop(L, Blocks, Predecessors) ->
    unsuitable_loop(L, Blocks, Predecessors, []).

unsuitable_loop(L, Blocks, Predecessors, Acc) ->
    Ps = maps:get(L, Predecessors),
    unsuitable_loop_1(Ps, Blocks, Predecessors, Acc).

unsuitable_loop_1([P|Ps], Blocks, Predecessors, Acc0) ->
    case maps:get(P, Blocks) of
        #b_blk{is=[#b_set{op=peek_message}|_]} ->
            unsuitable_loop_1(Ps, Blocks, Predecessors, Acc0);
        #b_blk{} ->
            case ordsets:is_element(P, Acc0) of
                false ->
                    Acc1 = ordsets:add_element(P, Acc0),
                    Acc = unsuitable_loop(P, Blocks, Predecessors, Acc1),
                    unsuitable_loop_1(Ps, Blocks, Predecessors, Acc);
                true ->
                    unsuitable_loop_1(Ps, Blocks, Predecessors, Acc0)
            end
    end;
unsuitable_loop_1([], _, _, Acc) -> Acc.

%% new_def_locations([{Variable,[UsedInBlock]}|Vs], Defs, Dominators) ->
%%          [{Variable,NewDefinitionBlock}]
%%  Calculate new locations for get_tuple_element instructions. For each
%%  variable, the new location is a block that dominates all uses of
%%  variable and as near to the uses of as possible. If no such block
%%  distinct from the block where the instruction currently is, the
%%  variable will not be included in the result list.

new_def_locations([{V,UsedIn}|Vs], Defs, Dom) ->
    DefIn = maps:get(V, Defs),
    case common_dom(UsedIn, DefIn, Dom) of
        [] ->
            new_def_locations(Vs, Defs, Dom);
        [_|_]=BetterDef ->
            L = most_dominated(BetterDef, Dom),
            [{V,L}|new_def_locations(Vs, Defs, Dom)]
    end;
new_def_locations([], _, _) -> [].

common_dom([L|Ls], DefIn, Dom) ->
    DomBy0 = maps:get(L, Dom),
    DomBy = ordsets:subtract(DomBy0, maps:get(DefIn, Dom)),
    common_dom_1(Ls, Dom, DomBy).

common_dom_1(_, _, []) ->
    [];
common_dom_1([L|Ls], Dom, [_|_]=DomBy0) ->
    DomBy1 = maps:get(L, Dom),
    DomBy = ordsets:intersection(DomBy0, DomBy1),
    common_dom_1(Ls, Dom, DomBy);
common_dom_1([], _, DomBy) -> DomBy.

most_dominated([L|Ls], Dom) ->
    most_dominated(Ls, L, maps:get(L, Dom), Dom).

most_dominated([L|Ls], L0, DomBy, Dom) ->
    case member(L, DomBy) of
        true ->
            most_dominated(Ls, L0, DomBy, Dom);
        false ->
            most_dominated(Ls, L, maps:get(L, Dom), Dom)
    end;
most_dominated([], L, _, _) -> L.


%% Move get_tuple_element instructions to their new locations.

move_defs(V, From, To, Blocks) ->
    #{From:=FromBlk0,To:=ToBlk0} = Blocks,
    {Def,FromBlk} = remove_def(V, FromBlk0),
    try insert_def(V, Def, ToBlk0) of
        ToBlk ->
            %%io:format("~p: ~p => ~p\n", [V,From,To]),
            Blocks#{From:=FromBlk,To:=ToBlk}
    catch
        throw:not_possible ->
            Blocks
    end.

remove_def(V, #b_blk{is=Is0}=Blk) ->
    {Def,Is} = remove_def_is(Is0, V, []),
    {Def,Blk#b_blk{is=Is}}.

remove_def_is([#b_set{dst=#b_var{name=Dst}}=Def|Is], Dst, Acc) ->
    {Def,reverse(Acc, Is)};
remove_def_is([I|Is], Dst, Acc) ->
    remove_def_is(Is, Dst, [I|Acc]).

insert_def(V, Def, #b_blk{is=Is0}=Blk) ->
    Is = insert_def_is(Is0, V, Def),
    Blk#b_blk{is=Is}.

insert_def_is([#b_set{op=phi}=I|Is], V, Def) ->
    case member(V, beam_ssa:used(I)) of
        true ->
            throw(not_possible);
        false ->
            [I|insert_def_is(Is, V, Def)]
    end;
insert_def_is([#b_set{op=Op}=I|Is]=Is0, V, Def) ->
    Action0 = case Op of
                  call -> beyond;
                  'catch_end' -> beyond;
                  set_tuple_element -> beyond;
                  timeout -> beyond;
                  _ -> here
              end,
    Action = case Is of
                 [#b_set{op=succeeded}|_] -> here;
                 _ -> Action0
             end,
    case Action of
        beyond ->
            case member(V, beam_ssa:used(I)) of
                true ->
                    %% The variable is used by this instruction. We must
                    %% place the definition before this instruction.
                    [Def|Is0];
                false ->
                    %% Place it beyond the current instruction.
                    [I|insert_def_is(Is, V, Def)]
            end;
        here ->
            [Def|Is0]
    end;
insert_def_is([], _V, Def) ->
    [Def].


%%%
%%% Common utilities.
%%%

rel2fam(S0) ->
    S1 = sofs:relation(S0),
    S = sofs:rel2fam(S1),
    sofs:to_external(S).

sub(#b_set{op=phi,args=Args}=I, Sub) ->
    I#b_set{args=[{sub_arg(A, Sub),P} || {A,P} <- Args]};
sub(#b_set{args=Args}=I, Sub) ->
    I#b_set{args=[sub_arg(A, Sub) || A <- Args]};
sub(#b_br{bool=#b_var{}=Old}=Br, Sub) ->
    New = sub_arg(Old, Sub),
    Br#b_br{bool=New};
sub(#b_switch{arg=#b_var{}=Old}=Sw, Sub) ->
    New = sub_arg(Old, Sub),
    Sw#b_switch{arg=New};
sub(#b_ret{arg=#b_var{}=Old}=Ret, Sub) ->
    New = sub_arg(Old, Sub),
    Ret#b_ret{arg=New};
sub(Last, _) -> Last.

sub_arg(#b_remote{mod=Mod,name=Name}=Rem, Sub) ->
    Rem#b_remote{mod=sub_arg(Mod, Sub),name=sub_arg(Name, Sub)};
sub_arg(Old, Sub) ->
    case Sub of
        #{Old:=New} -> New;
        #{} -> Old
    end.
