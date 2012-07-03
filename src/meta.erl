-module(meta).

-export([reify_type/2,
         meta_error/1]).

-export([parse_transform/2,
         format_error/1]).

-include("../include/meta_syntax.hrl").

-record(info,
        {meta = [],
         imports = dict:new(),
         types = dict:new(),
         records = dict:new(),
         funs = dict:new()}).

-define(REMOTE_CALL(Ln, Mod, Name, Args),
        #call{line = Ln,
              function = #remote
              {module = #atom{name = Mod},
               name = #atom{name = Name}},
              args = Args}).
-define(LOCAL_CALL(Ln, Name, Args),
        #call{line = Ln,
              function = #atom{name = Name},
              args = Args}).
-define(META_CALL(Ln, Name, Args), ?REMOTE_CALL(Ln, meta, Name, Args)).
-define(LN(Ln), ?META_CALL(Ln, line, [])).
-define(QUOTE(Ln, Var), ?META_CALL(Ln, quote, [Var])).

-define(REIFY(Ln, Name), ?META_CALL(Ln, reify, [Name])).
-define(REIFYTYPE(Ln, Name), ?META_CALL(Ln, reify_type, [Name])).
-define(REIFY_ALL_TYPES(Ln), ?META_CALL(Ln, reify_types, [])).
-define(REIFY_ALL(Ln), ?META_CALL(Ln, reify, [])).

-define(SPLICE(Ln, Var), ?META_CALL(Ln, splice, Var)).


%%%
%%% API
%%%
reify_type(Name, #info{types = Ts}) ->
    fetch(Name, Ts, reify_unknown_record_type).

    

parse_transform(Forms, _Options) ->
    %%io:format("~p", [Forms]),
    {Forms1, Info} = traverse(fun info/2, #info{}, Forms),
    %%io:format("~p", [Info]),
    Funs = [K || {K,_V} <- dict:to_list(Info#info.funs)],
    {_, Info1} = safe_mapfoldl(fun process_fun/2, Info, Funs),
    %% io:format("~p", [Info1]),
    Forms2 = lists:map(insert(Info1), Forms1),
    %%io:format("~p", [Forms2]),
    %%io:format("~s~n", [erl_prettypr:format(erl_syntax:form_list(Forms2))]),
    Forms2.


%%
%% meta:quote/1 handling
%%
process_fun(Fun, #info{funs = Fs} = Info) ->
    {Def, State} = dict:fetch(Fun, Fs),
    if
        State =:= processed ->
            {Def, Info};
        State =:= raw ->
            {Def1, #info{funs = Fs1} = Info1} = meta(Def, Info),
            Fs2 = dict:store(Fun, {Def1, processed}, Fs1),
            {Def1, Info1#info{funs = Fs2}}
    end.

insert(#info{funs = Fs}) ->
    fun(#function{name = Name, arity = Arity}) ->
            Fun = {Name, Arity},
            case dict:fetch(Fun, Fs) of
                {Def, processed} ->
                    Def;
                {error, _} = Err ->
                    Err
            end;
       (Form) ->
            Form
    end.

meta(?LN(Ln), Info) ->
    {{integer, Ln, Ln}, Info};
meta(?LOCAL_CALL(Ln, Name, Args) = Form, #info{meta = Ms} = Info) ->
    Fn = {Name, length(Args)},
    case lists:member(Fn, Ms) of
        true ->
            {Args1, Info1} = traverse(fun meta/2, Info, Args),
            eval_splice(Ln, [?LOCAL_CALL(Ln, Name, Args1)], Info1);
        false ->
            traverse(fun meta/2, Info, Form)
    end;
meta(?QUOTE(_, Quote), Info) ->
    {Ast, Info1} = term_to_ast(Quote, Info),
    {erl_syntax:revert(Ast), Info1};
meta(#attribute{} = Form, Info) ->
    {Form, Info};
meta(?SPLICE(Ln, Splice), Info) ->
    {Splice1, Info1} = traverse(fun meta/2, Info, Splice),
    eval_splice(Ln, Splice1, Info1);

meta(?REIFY(Ln, {'fun', _, {function, Name, Arity}}),
      #info{funs = Fs} = Info) ->
    Key = {Name, Arity},
    case dict:find(Key, Fs) of
        {ok, _} ->
            {Def, Info1} = process_fun(Key, Info),
            {Ast, Info2} = term_to_ast(Def, Info1),
            {erl_syntax:revert(Ast), Info2};
        error ->
            meta_error(Ln, {reify_unknown_function, Key})
    end;
meta(?REIFY(Ln, {record, _, Name, []}),
      #info{records = Rs} = Info) ->
    fetch(Ln, Name, Rs, reify_unknown_record, Info);             
meta(?REIFYTYPE(Ln, #call{function = #atom{name = Name}, args = _Args}),
      #info{types = Ts} = Info) ->
    fetch(Ln, Name, Ts, reify_unknown_type, Info);             
meta(?REIFYTYPE(Ln, {record, _, Name, []}),
      #info{types = Ts} = Info) ->
    Key = {record, Name},
    fetch(Ln, Key, Ts, reify_unknown_record_type, Info);
meta(?REIFYTYPE(Ln, {'fun', _, {function, Name, Arity}}),
      #info{types = Ts} = Info) ->
    Key = {Name, Arity},
    fetch(Ln, Key, Ts, reify_unknown_function_spec, Info);
meta(?REIFY_ALL_TYPES(_Ln), Info) ->
    {erl_parse:abstract(Info#info.types), Info};
meta(?REIFY_ALL(_Ln), Info) ->
    {erl_parse:abstract(Info), Info};


meta(Form, Info) ->
    traverse(fun meta/2, Info, Form).




term_to_ast(?QUOTE(Ln, _), _) ->
    meta_error(Ln, nested_quote);
term_to_ast(?SPLICE(_Ln, [Splice]), Info) ->
    traverse(fun meta/2, Info, Splice);
term_to_ast(Ls, Info) when is_list(Ls) ->
    {Ls1, _} = traverse(fun term_to_ast/2, Info, Ls),
    {erl_syntax:list(Ls1), Info};
term_to_ast(T, Info) when is_tuple(T) ->
    %% tuple_to_ast(T, Info);
    Ls = tuple_to_list(T),
    {Ls1, Info1} = traverse(fun term_to_ast/2, Info, Ls),
    {erl_syntax:tuple(Ls1), Info1};
term_to_ast(I, Info) when is_integer(I) ->
    {erl_syntax:integer(I), Info};
term_to_ast(F, Info) when is_float(F) ->
    {erl_syntax:float(F), Info};
term_to_ast(A, Info) when is_atom(A) ->
    {erl_syntax:atom(A), Info}.    


fetch(Name, Dict, Error) ->
    case dict:find(Name, Dict) of
        {ok, Def} ->
            Def;
        error ->
            meta_error(get_line, {Error, Name})
    end.

fetch(Line, Name, Dict, Error, Info) ->
    case dict:find(Name, Dict) of
        {ok, Def} ->
            {Ast, Info1} = term_to_ast(Def, Info),
            {erl_syntax:revert(Ast), Info1};
        error ->
            meta_error(Line, {Error, Name})
    end.

%%
%% Various info gathering for subsequent use
%%
info(#attribute{name = meta, arg = Meta} = Form,
     #info{meta = Ms} = Info) ->
    Info1 = Info#info{meta = Ms ++ Meta},
    {Form, Info1};
info(#attribute{name = import, arg = {Mod, Fs}} = Form,
     #info{imports = Is} = Info) ->
    Is1 = lists:foldl(fun(F,D) -> dict:store(F, {Mod,F}, D) end, Is, Fs),
    Info1 = Info#info{imports = Is1},
    {Form, Info1};
info(#attribute{name = record, arg = {Name, _} = Def} = Form,
     #info{records = Rs} = Info) ->
    Rs1 = dict:store(Name, Def, Rs),
    Info1 = Info#info{records = Rs1},
    {Form, Info1};
info(#attribute{name = type, arg = Def} = Form,
     #info{types = Ts} = Info) ->
    Name = element(1, Def),
    Ts1 = dict:store(Name, Def, Ts),
    Info1 = Info#info{types = Ts1},
    {Form, Info1};
info(#attribute{name = spec, arg = Def} = Form,
     #info{types = Ts} = Info) ->
    Name = element(1, Def),
    Ts1 = dict:store(Name, Def, Ts),
    Info1 = Info#info{types = Ts1},
    {Form, Info1};
info(#function{name = Name, arity = Arity} = Form,
     #info{funs = Fs} = Info) ->
    Key = {Name,Arity},
    Value = {Form, raw},
    Info1 = Info#info{funs = dict:store(Key, Value, Fs)},
    Form1 = Form#function{clauses = undefined},
    {Form1, Info1};
info(Form, Info) ->
    traverse(fun info/2, Info, Form).
    

eval_splice(Ln, Splice, Info) ->
    Bs = erl_eval:new_bindings(),
    Local = {eval, local_handler(Ln, Info)},
    try
        {value, Val, _} = erl_eval:exprs(Splice, Bs, Local),
        Expr = erl_syntax:revert(Val),
        erl_lint:exprs([Expr], []),
        {Expr, Info}
    catch
        error:{get_line, Error} ->
            meta_error(Ln, Error);
        error:{unbound, Var} ->
            meta_error(Ln, splice_external_var, Var);
        error:{badarity, _} ->
            meta_error(Ln, splice_badarity);
        error:{badfun, _} ->
            meta_error(Ln, splice_badfun);
        error:{badarg, Arg} ->
            meta_error(Ln, splice_badarg, Arg);
        error:undef ->
            meta_error(Ln, splice_unknown_external_function)
        %% error:_ ->
        %%     meta_error(Ln, invalid_splice)
    end.

local_handler(Ln, Info) ->
    fun(Name, Args, Bs) ->
            #info{imports = Is, funs = Fs} = Info,
            Fn = {Name, length(Args)},
            case dict:find(Fn, Is) of
                {ok, {Mod,{Fun,_}}} ->
                    M = erl_syntax:atom(Mod),
                    F = erl_syntax:atom(Fun),
                    A = erl_syntax:application(M, F, Args),
                    Call = erl_syntax:revert(A),
                    Local = {eval, local_handler(Ln, Info)},
                    erl_eval:expr(Call, Bs, Local);      
                error ->
                    case dict:is_key(Fn, Fs) of
                        true ->
                            {#function{clauses = Cs}, #info{} = Info1} = process_fun(Fn, Info),
                            F = erl_syntax:fun_expr(Cs),
                            A = erl_syntax:application(F, Args),
                            Call = erl_syntax:revert(A),
                            Local = {eval, local_handler(Ln, Info1)},
                            erl_eval:expr(Call, Bs, Local);
                        false ->
                            meta_error(Ln, {splice_unknown_function, Fn})
                    end
            end
    end.  


%%
%% Recursive traversal a-la mapfoldl
%%
traverse(Fun, Acc, Form) when is_tuple(Form) ->
    Fs = tuple_to_list(Form),
    {Fs1, Acc1} = traverse(Fun, Acc, Fs),
    {list_to_tuple(Fs1), Acc1};
traverse(Fun, Acc, Fs) when is_list(Fs) ->
    lists:mapfoldl(Fun, Acc, Fs);
traverse(_Fun, Acc, Smt) ->
    {Smt, Acc}.

safe_mapfoldl(Fun, Info, Fns) ->
    Do = fun(Fn, #info{funs = Fs} = I) ->
                 try
                     Fun(Fn, I)
                 catch
                     throw:{Line, Reason} ->
                         E = {error, {Line, ?MODULE, Reason}},
                         {E, I#info{funs = dict:store(Fn, E, Fs)}}
                 end
         end,    
    lists:mapfoldl(Do, Info, Fns).


meta_error(Error) ->
    throw({get_line, Error}).

meta_error(Line, Error) ->
    throw({Line, Error}).

meta_error(Line, Error, Arg) ->
    throw({Line, {Error, Arg}}).




%%
%% Formats error messages for compiler 
%%
format_error(nested_quote) ->
    "meta:quote/1 is not allowed within another meta:quote/1";
format_error(nested_splice) ->
    "meta:splice/1 is not allowed within meta:quote/1";
format_error({reify_unknown_function, {Name, Arity}}) ->
    format("attempt to reify unknown function '~s/~b'", [Name, Arity]);
format_error({reify_unknown_record, Name}) ->
    format("attempt to reify unknown record '~s'", [Name]);
format_error({reify_unknown_type, Name}) ->
    format("attempt to reify unknown type '~s'", [Name]);
format_error({reify_unknown_record_type, Name}) ->
    format("attempt to reify unknown record type '~s'", [Name]);
format_error({reify_unknown_function_spec, {Name, Arity}}) ->
    format("attempt to reify unknown function -spec '~s/~b'", [Name, Arity]);
format_error(invalid_splice) ->
    "invalid expression in meta:splice/1";
format_error({splice_external_var, Var}) ->
    format("Variable '~s' is outside of scope of meta:splice/1", [Var]);
format_error(splice_badarity) ->
    "'badarity' call in 'meta:splice'";
format_error(splice_badfun) ->
    "'badfun' call in 'meta:splice'";
format_error({splice_badarg, Arg}) ->
    format("'badarg' in 'meta:splice': ~p", [Arg]);
format_error(splice_unknown_external_function) ->
    "Unknown remote function call in 'splice'";
format_error({splice_unknown_function, {Name,Arity}}) ->
    format("Unknown local function '~s/~b' used in 'meta:splice/1'", [Name,Arity]).
    
format(Format, Args) ->
    io_lib:format(Format, Args).