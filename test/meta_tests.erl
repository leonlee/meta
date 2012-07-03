%%%-------------------------------------------------------------------
%%% @author Eduard Sergeev <eduard.sergeev@gmail.com>
%%% @copyright (C) 2012, Eduard Sergeev
%%% @doc
%%%
%%% @end
%%% Created :  2 Jul 2012 by <eduard.sergeev@gmail.com>
%%%-------------------------------------------------------------------
-module(meta_tests).

-include("../include/meta.hrl").

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

%%
%% meta:quote tests
%%
q1() ->
    [meta:quote(1),
     meta:quote(1.1),
     meta:quote(true),
     meta:quote(atom),
     meta:quote(<<"Bin">>),
     meta:quote({1,{[2,3],true}})].

q2() ->
    [meta:quote(fun() -> 42 end),
     meta:quote(fun q1/0),
     meta:quote(fun(A) -> A + 1 end)].

quote_test_() ->
    [{"Basic type quotes",
      ?_assert(lists:all(fun is_valid_quote/1, q1()))},
     {"Function type quotes",
      ?_assert(lists:all(fun is_valid_quote/1, q2()))}].

splice_test_() ->
    [{"Basic type splices",
      ?_test(
         [meta:splice(hd(q1())),
          meta:splice(lists:nth(2, q1())),
          meta:splice(lists:nth(3, q1())),
          meta:splice(lists:nth(4, q1())),
          meta:splice(lists:nth(5, q1())),
          meta:splice(lists:last(q1()))])},
     {"Function type slices",
      ?_test(
         begin
             F1 = meta:splice(hd(q2())),
             ?assertEqual(42, F1()),
             F2 = meta:splice(lists:nth(2, q2())),
             ?assertEqual(q1(), F2()),
             F3 = meta:splice(lists:nth(3, q2())),
             ?assertEqual(3, F3(2))
         end)}].
       
quote_splice_test_() ->
    [{"Simple type quote with splice argiment",
      ?_test(
         begin
             A = meta:quote(1), Q1 = meta:quote(meta:splice(A) + 2), Q2 = meta:quote(1 + 2),
             ?assertEqual(Q2, Q1)
         end)}].
    

%%
%% Utilities
%%
is_valid_quote(QExpr) ->
    try
        erl_lint:exprs([QExpr], []),
        true
    catch error:_ ->
            false
    end.