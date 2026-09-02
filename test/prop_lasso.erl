%%% PropEr model-based tests for lasso.
%%%
%%% A random sequence of edits is applied to both a rope and a plain `binary()'
%%% reference; after every step the rope must agree with the reference on its
%%% bytes, codepoint length, line structure and per-index line/column mapping,
%%% and must pass `lasso:validate/1'.
%%%
%%% The text generator deliberately mixes ASCII, Latin-1 accents, CJK,
%%% astral-plane emoji and newlines: an ASCII-only generator would pass while
%%% every codepoint-counting path was silently wrong.
-module(prop_lasso).

-include_lib("proper/include/proper.hrl").
-include("lasso.hrl").

-export([prop_rope_matches_binary/0, prop_no_leaf_shredding/0]).

%%%===================================================================
%%% Generators
%%%===================================================================

utf8_char() ->
    frequency([
        {5, choose($a, $z)},
        {2, elements([16#E9, 16#F6, 16#FC, 16#E0])},      %% é ö ü à  (2 bytes)
        {3, elements([16#65E5, 16#672C, 16#8A9E])},        %% 日 本 語 (3 bytes)
        {2, elements([16#1F335, 16#1F920, 16#1F600])},     %% 🌵 🤠 😀 (4 bytes)
        {2, $\n}
    ]).

utf8_text() ->
    ?LET(Cps, list(utf8_char()), unicode:characters_to_binary(Cps)).

op() ->
    oneof([
        {insert, nat(), utf8_text()},
        {delete, nat(), nat()},
        {split_concat, nat()}
    ]).

%%%===================================================================
%%% Properties
%%%===================================================================

prop_rope_matches_binary() ->
    ?FORALL(Ops, list(op()),
        begin
            {Ref, _Rope, Checks} =
                lists:foldl(fun step/2, {<<>>, lasso:new(), []}, Ops),
            ?WHENFAIL(
                io:format("ops=~p~nfinal ref=~p~n", [Ops, Ref]),
                conjunction(lists:reverse(Checks)))
        end).

%% Repeated single-codepoint inserts near the middle must not shred the rope
%% into tiny leaves: coalescing keeps the leaf count proportional to the byte
%% size.
prop_no_leaf_shredding() ->
    ?FORALL(Cs, list(utf8_char()),
        begin
            Rope = lists:foldl(
                     fun(C, Acc) ->
                         Bin = unicode:characters_to_binary([C]),
                         lasso:insert(Acc, lasso:length(Acc) div 2, Bin)
                     end, lasso:new(), Cs),
            Bytes = lasso:bytes(Rope),
            Leaves = leaf_count(Rope),
            ?WHENFAIL(
                io:format("bytes=~p leaves=~p~n", [Bytes, Leaves]),
                lasso:validate(Rope) =:= ok
                    andalso Leaves =< 8 + Bytes div (?MAX_LEAF div 2))
        end).

%%%===================================================================
%%% Step / consistency
%%%===================================================================

%% Apply one op, then check the rope against the reference; the check for step
%% number `length(Checks)' is appended so `conjunction/1' reports which step and
%% which invariant first diverged.
step(Op, {Ref, Rope, Checks}) ->
    {Ref2, Rope2} = apply_op(Op, Ref, Rope),
    Label = list_to_atom("step_" ++ integer_to_list(length(Checks))),
    {Ref2, Rope2, [{Label, consistent(Ref2, Rope2)} | Checks]}.

apply_op({insert, N, Text}, Ref, Rope) ->
    I = N rem (cp_len(Ref) + 1),
    {ref_insert(Ref, I, Text), lasso:insert(Rope, I, Text)};
apply_op({delete, N, M}, Ref, Rope) ->
    Len = cp_len(Ref),
    I = N rem (Len + 1),
    DelLen = M rem (Len - I + 1),
    {ref_delete(Ref, I, DelLen), lasso:delete(Rope, I, DelLen)};
apply_op({split_concat, N}, Ref, Rope) ->
    I = N rem (cp_len(Ref) + 1),
    {L, R} = lasso:split(Rope, I),
    {Ref, lasso:concat(L, R)}.

consistent(Ref, Rope) ->
    Cps = cps(Ref),
    Len = length(Cps),
    RefLines = binary:split(Ref, <<"\n">>, [global]),
    conjunction([
        {to_binary,  equals(Ref, lasso:to_binary(Rope))},
        {length,     equals(Len, lasso:length(Rope))},
        {bytes,      equals(byte_size(Ref), lasso:bytes(Rope))},
        {validate,   equals(ok, lasso:validate(Rope))},
        {line_count, equals(length(RefLines), lasso:line_count(Rope))},
        {line_at,    equals(RefLines,
                            [lasso:line_at(Rope, L)
                             || L <- lists:seq(0, length(RefLines) - 1)])},
        {offset_of_line,
                     equals(ref_line_offsets(Cps, length(RefLines)),
                            [lasso:offset_of_line(Rope, L)
                             || L <- lists:seq(0, length(RefLines) - 1)])},
        {index_to_line_col,
                     equals([ref_line_col(Cps, I) || I <- lists:seq(0, Len)],
                            [lasso:index_to_line_col(Rope, I)
                             || I <- lists:seq(0, Len)])},
        {line_of_offset,
                     equals([ref_line_of(Cps, I) || I <- lists:seq(0, Len)],
                            [lasso:line_of_offset(Rope, I)
                             || I <- lists:seq(0, Len)])}
    ]).

%%%===================================================================
%%% Binary reference model (all indices in codepoints)
%%%===================================================================

cps(Bin) -> unicode:characters_to_list(Bin).

cp_len(Bin) -> length(cps(Bin)).

from_cps(Cps) -> unicode:characters_to_binary(Cps).

ref_insert(Ref, I, Text) ->
    {A, B} = lists:split(I, cps(Ref)),
    from_cps(A ++ cps(Text) ++ B).

ref_delete(Ref, I, Len) ->
    {A, Rest} = lists:split(I, cps(Ref)),
    {_, B} = lists:split(Len, Rest),
    from_cps(A ++ B).

%% Codepoint offset at which each 0-based line starts.
ref_line_offsets(Cps, LineCount) ->
    Starts = [0 | [P || P <- lists:seq(1, length(Cps)),
                        lists:nth(P, Cps) =:= $\n]],
    lists:sublist(Starts, LineCount).

ref_line_of(Cps, I) ->
    length([x || C <- lists:sublist(Cps, I), C =:= $\n]).

ref_line_col(Cps, I) ->
    Prefix = lists:sublist(Cps, I),
    NlPos = [P || P <- lists:seq(1, length(Prefix)),
                  lists:nth(P, Prefix) =:= $\n],
    Line = length(NlPos),
    Col = case NlPos of
              [] -> I;
              _  -> I - lists:last(NlPos)
          end,
    {Line, Col}.

%%%===================================================================
%%% Helpers
%%%===================================================================

leaf_count(empty)                      -> 0;
leaf_count(#leaf{})                    -> 1;
leaf_count(#node{left = L, right = R}) -> leaf_count(L) + leaf_count(R).
