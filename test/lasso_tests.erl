%%% EUnit tests for lasso: unit coverage and regression cases.
-module(lasso_tests).

-include_lib("eunit/include/eunit.hrl").
-include("lasso.hrl").

%%%===================================================================
%%% Helpers
%%%===================================================================

%% Round-trip a binary through a rope, asserting invariants hold.
rope(Bin) ->
    R = lasso:from_binary(Bin),
    ?assertEqual(ok, lasso:validate(R)),
    ?assertEqual(Bin, lasso:to_binary(R)),
    R.

%% Count the leaves in a rope (white-box, for the coalescing checks).
leaf_count(empty)                       -> 0;
leaf_count(#leaf{})                     -> 1;
leaf_count(#node{left = L, right = R})  -> leaf_count(L) + leaf_count(R).

%%%===================================================================
%%% Construction / conversion
%%%===================================================================

empty_test() ->
    R = lasso:new(),
    ?assertEqual(<<>>, lasso:to_binary(R)),
    ?assertEqual(0, lasso:length(R)),
    ?assertEqual(0, lasso:bytes(R)),
    ?assert(lasso:is_empty(R)),
    ?assertEqual(1, lasso:line_count(R)),
    ?assertEqual(ok, lasso:validate(R)).

from_empty_binary_test() ->
    ?assertEqual(<<>>, lasso:to_binary(rope(<<>>))).

roundtrip_ascii_test() ->
    _ = rope(<<"the quick brown fox">>).

roundtrip_multibyte_test() ->
    _ = rope(<<"héllo"/utf8>>),
    _ = rope(<<"日本語"/utf8>>),
    _ = rope(<<"a🌵b🤠c"/utf8>>),
    _ = rope(<<"café \x{0301} combining"/utf8>>).

length_counts_codepoints_test() ->
    ?assertEqual(3, lasso:length(rope(<<"日本語"/utf8>>))),
    ?assertEqual(9, lasso:bytes(rope(<<"日本語"/utf8>>))),
    ?assertEqual(5, lasso:length(rope(<<"héllo"/utf8>>))),
    ?assertEqual(6, lasso:bytes(rope(<<"héllo"/utf8>>))).

invalid_utf8_rejected_test() ->
    ?assertError(badarg, lasso:from_binary(<<255, 254>>)),
    ?assertError(badarg, lasso:from_binary(<<"ok", 16#C3>>)),
    ?assertError(badarg, lasso:from_binary(not_a_binary)).

to_list_test() ->
    ?assertEqual("日本語", lasso:to_list(rope(<<"日本語"/utf8>>))).

large_binary_chunks_test() ->
    Bin = binary:copy(<<"abcdefghij">>, 500),   %% 5000 bytes
    R = rope(Bin),
    ?assertEqual(5000, lasso:length(R)),
    %% chunked into >1 leaf, but not shredded
    ?assert(leaf_count(R) >= 4),
    ?assert(leaf_count(R) =< 5000 div (?TARGET_LEAF div 2)).

%%%===================================================================
%%% Editing
%%%===================================================================

insert_head_mid_tail_test() ->
    R = rope(<<"héllo"/utf8>>),
    ?assertEqual(<<"XXhéllo"/utf8>>, lasso:to_binary(lasso:insert(R, 0, <<"XX">>))),
    ?assertEqual(<<"héXXllo"/utf8>>, lasso:to_binary(lasso:insert(R, 2, <<"XX">>))),
    ?assertEqual(<<"hélloXX"/utf8>>, lasso:to_binary(lasso:insert(R, 5, <<"XX">>))).

insert_rope_test() ->
    A = rope(<<"日本"/utf8>>),
    B = rope(<<"語!"/utf8>>),
    ?assertEqual(<<"日本語!"/utf8>>, lasso:to_binary(lasso:insert(A, 2, B))).

insert_out_of_range_test() ->
    R = rope(<<"abc">>),
    ?assertError(badarg, lasso:insert(R, 4, <<"x">>)),
    ?assertError(badarg, lasso:insert(R, -1, <<"x">>)).

delete_spanning_leaves_test() ->
    Bin = binary:copy(<<"0123456789">>, 300),   %% 3000 bytes, many leaves
    R = rope(Bin),
    R2 = lasso:delete(R, 5, 2990),
    ?assertEqual(ok, lasso:validate(R2)),
    ?assertEqual(10, lasso:length(R2)),
    ?assertEqual(<<"01234", "56789">>, lasso:to_binary(R2)).

delete_nothing_test() ->
    R = rope(<<"abc">>),
    ?assertEqual(<<"abc">>, lasso:to_binary(lasso:delete(R, 1, 0))).

delete_all_test() ->
    R = rope(<<"héllo"/utf8>>),
    ?assertEqual(<<>>, lasso:to_binary(lasso:delete(R, 0, 5))).

delete_out_of_range_test() ->
    R = rope(<<"abc">>),
    ?assertError(badarg, lasso:delete(R, 2, 2)),
    ?assertError(badarg, lasso:delete(R, -1, 1)).

split_every_index_test() ->
    Bin = <<"a日b語c"/utf8>>,
    R = rope(Bin),
    N = lasso:length(R),
    [begin
         {L, Rt} = lasso:split(R, I),
         ?assertEqual(ok, lasso:validate(L)),
         ?assertEqual(ok, lasso:validate(Rt)),
         ?assertEqual(Bin, lasso:to_binary(lasso:concat(L, Rt))),
         ?assertEqual(I, lasso:length(L))
     end || I <- lists:seq(0, N)].

concat_test() ->
    ?assertEqual(<<"日本語"/utf8>>,
                 lasso:to_binary(lasso:concat(rope(<<"日"/utf8>>), rope(<<"本語"/utf8>>)))),
    ?assertEqual(<<"x">>, lasso:to_binary(lasso:concat(lasso:new(), rope(<<"x">>)))).

slice_test() ->
    R = rope(<<"a日b語c"/utf8>>),
    ?assertEqual(<<"日b語"/utf8>>, lasso:sub_binary(R, 1, 3)),
    ?assertEqual(<<>>, lasso:sub_binary(R, 2, 0)),
    ?assertError(badarg, lasso:slice(R, 3, 5)).

at_test() ->
    R = rope(<<"a日b"/utf8>>),
    ?assertEqual($a, lasso:at(R, 0)),
    ?assertEqual(16#65E5, lasso:at(R, 1)),
    ?assertEqual($b, lasso:at(R, 2)).

%%%===================================================================
%%% Line model  (0-based; trailing \n -> final empty line)
%%%===================================================================

line_count_test() ->
    ?assertEqual(1, lasso:line_count(rope(<<>>))),
    ?assertEqual(1, lasso:line_count(rope(<<"no newline">>))),
    ?assertEqual(3, lasso:line_count(rope(<<"a\nb\n">>))),
    ?assertEqual(2, lasso:line_count(rope(<<"a\nb">>))),
    ?assertEqual(4, lasso:line_count(rope(<<"\n\n\n">>))).

offset_of_line_test() ->
    R = rope(<<"a\nbb\nccc\n">>),
    ?assertEqual(0, lasso:offset_of_line(R, 0)),
    ?assertEqual(2, lasso:offset_of_line(R, 1)),
    ?assertEqual(5, lasso:offset_of_line(R, 2)),
    ?assertEqual(9, lasso:offset_of_line(R, 3)),   %% final empty line
    ?assertError(badarg, lasso:offset_of_line(R, 4)).

line_at_test() ->
    R = rope(<<"a\nbb\nccc\n">>),
    ?assertEqual(<<"a">>,   lasso:line_at(R, 0)),
    ?assertEqual(<<"bb">>,  lasso:line_at(R, 1)),
    ?assertEqual(<<"ccc">>, lasso:line_at(R, 2)),
    ?assertEqual(<<>>,      lasso:line_at(R, 3)),
    R2 = rope(<<"only">>),
    ?assertEqual(<<"only">>, lasso:line_at(R2, 0)).

line_at_multibyte_test() ->
    R = rope(<<"héllo\nwörld\n"/utf8>>),
    ?assertEqual(<<"héllo"/utf8>>, lasso:line_at(R, 0)),
    ?assertEqual(<<"wörld"/utf8>>, lasso:line_at(R, 1)),
    ?assertEqual(<<>>, lasso:line_at(R, 2)).

consecutive_newlines_test() ->
    R = rope(<<"\n\n">>),
    ?assertEqual(3, lasso:line_count(R)),
    ?assertEqual(<<>>, lasso:line_at(R, 0)),
    ?assertEqual(<<>>, lasso:line_at(R, 1)),
    ?assertEqual(<<>>, lasso:line_at(R, 2)),
    ?assertEqual(0, lasso:offset_of_line(R, 0)),
    ?assertEqual(1, lasso:offset_of_line(R, 1)),
    ?assertEqual(2, lasso:offset_of_line(R, 2)).

line_of_offset_test() ->
    R = rope(<<"a\nbb\nccc\n">>),
    ?assertEqual(0, lasso:line_of_offset(R, 0)),
    ?assertEqual(0, lasso:line_of_offset(R, 1)),
    ?assertEqual(1, lasso:line_of_offset(R, 2)),   %% just past first \n
    ?assertEqual(1, lasso:line_of_offset(R, 4)),
    ?assertEqual(2, lasso:line_of_offset(R, 5)),
    ?assertEqual(3, lasso:line_of_offset(R, 9)).

index_to_line_col_test() ->
    R = rope(<<"héllo\nwörld\n"/utf8>>),
    ?assertEqual({0, 0}, lasso:index_to_line_col(R, 0)),
    ?assertEqual({0, 5}, lasso:index_to_line_col(R, 5)),   %% the \n itself
    ?assertEqual({1, 0}, lasso:index_to_line_col(R, 6)),
    ?assertEqual({1, 2}, lasso:index_to_line_col(R, 8)),
    ?assertEqual({2, 0}, lasso:index_to_line_col(R, 12)).

line_col_to_index_test() ->
    R = rope(<<"héllo\nwörld\n"/utf8>>),
    ?assertEqual(0, lasso:line_col_to_index(R, 0, 0)),
    ?assertEqual(8, lasso:line_col_to_index(R, 1, 2)),
    ?assertEqual(11, lasso:line_col_to_index(R, 1, 5)),   %% end of "wörld"
    ?assertError(badarg, lasso:line_col_to_index(R, 1, 6)),
    ?assertEqual(12, lasso:line_col_to_index(R, 2, 0)).

roundtrip_line_col_test() ->
    R = rope(<<"one\ntwo\nthree\nfour">>),
    N = lasso:length(R),
    [begin
         {L, C} = lasso:index_to_line_col(R, I),
         ?assertEqual(I, lasso:line_col_to_index(R, L, C))
     end || I <- lists:seq(0, N)].

%%%===================================================================
%%% Coalescing regression: repeated tiny edits must not shred the rope
%%%===================================================================

%%%===================================================================
%%% Deep multi-leaf coverage: the line-aware code must be exercised on a
%%% rope that is many leaves tall, not a single leaf.
%%%===================================================================

deep_multileaf_lines_test() ->
    Lines = [line_body(N) || N <- lists:seq(0, 299)],
    Bin = iolist_to_binary([[L, $\n] || L <- Lines]),
    ?assert(byte_size(Bin) > 12000),
    R = rope(Bin),
    RefLines = binary:split(Bin, <<"\n">>, [global]),
    ?assertEqual(length(RefLines), lasso:line_count(R)),
    lists:foldl(
      fun(RefLine, {Idx, CpOffset}) ->
          ?assertEqual(RefLine, lasso:line_at(R, Idx)),
          ?assertEqual(CpOffset, lasso:offset_of_line(R, Idx)),
          ?assertEqual({Idx, 0}, lasso:index_to_line_col(R, CpOffset)),
          ?assertEqual(CpOffset, lasso:line_col_to_index(R, Idx, 0)),
          Mid = length(lasso_cps(RefLine)) div 2,
          ?assertEqual(CpOffset + Mid, lasso:line_col_to_index(R, Idx, Mid)),
          ?assertEqual({Idx, Mid}, lasso:index_to_line_col(R, CpOffset + Mid)),
          {Idx + 1, CpOffset + length(lasso_cps(RefLine)) + 1}
      end, {0, 0}, lists:droplast(RefLines)).

line_body(N) ->
    Base = list_to_binary(lists:duplicate(35 + N rem 20, $a + N rem 26)),
    case N rem 3 of
        0 -> <<Base/binary, "日本語ちゃん"/utf8>>;
        1 -> <<"🌵", Base/binary, "🤠"/utf8>>;
        2 -> <<Base/binary, " café"/utf8>>
    end.

lasso_cps(Bin) -> unicode:characters_to_list(Bin).

no_leaf_shredding_test() ->
    R = lists:foldl(
          fun(_, Acc) -> lasso:insert(Acc, lasso:length(Acc) div 2, <<"x">>) end,
          lasso:new(),
          lists:seq(1, 4000)),
    ?assertEqual(ok, lasso:validate(R)),
    ?assertEqual(4000, lasso:length(R)),
    %% average leaf must stay chunky - well under one leaf per few bytes
    ?assert(leaf_count(R) =< 4000 div (?TARGET_LEAF div 4)).
