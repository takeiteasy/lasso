%%% @doc lasso - a purely-functional rope for text editors.
%%%
%%% Text is stored as UTF-8 in the leaves of a height-balanced (AVL) binary
%%% tree.  Every node caches the byte count, codepoint count and newline count
%%% of its subtree, so indexing by codepoint and lookup by line number are both
%%% O(log n).
%%%
%%% All public index and length arguments are Unicode *codepoints*, 0-based.
%%% Byte offsets are an internal concern.  Line numbers are 0-based and a
%%% trailing "\n" produces a final empty line, so
%%% `line_count(from_binary(<<"a\nb\n">>))' is 3 and `line_count(new())' is 1.
%%%
%%% Out-of-range indices raise `badarg'.
-module(lasso).

%% lasso:length/1 counts codepoints; the erlang BIF is not used in this module.
-compile({no_auto_import, [{length, 1}]}).

-include("lasso.hrl").

%% construction / conversion
-export([new/0, from_binary/1, to_binary/1, to_list/1]).
%% measurement
-export([length/1, bytes/1, is_empty/1]).
%% editing
-export([insert/3, delete/3, split/2, concat/2, slice/3, sub_binary/3, at/2]).
%% line-aware
-export([line_count/1, line_at/2, offset_of_line/2, line_of_offset/2,
         index_to_line_col/2, line_col_to_index/3]).
%% debug
-export([validate/1]).

-export_type([rope/0, tree/0]).

-type tree() :: empty | #leaf{} | #node{}.
-type rope() :: tree().

%%%===================================================================
%%% Construction / conversion
%%%===================================================================

-spec new() -> rope().
new() -> empty.

%% @doc Build a rope from a UTF-8 binary.  Raises `badarg' if the bytes are not
%% valid UTF-8.
-spec from_binary(binary()) -> rope().
from_binary(Bin) when is_binary(Bin) ->
    case is_valid_utf8(Bin) of
        true  -> build([mk_leaf(C) || C <- chunk(Bin, ?TARGET_LEAF)]);
        false -> erlang:error(badarg, [Bin])
    end;
from_binary(Other) ->
    erlang:error(badarg, [Other]).

-spec to_binary(rope()) -> binary().
to_binary(T) -> iolist_to_binary(to_iolist(T)).

-spec to_list(rope()) -> string().
to_list(T) -> unicode:characters_to_list(to_binary(T)).

%%%===================================================================
%%% Measurement
%%%===================================================================

%% @doc Number of Unicode codepoints in the rope.
-spec length(rope()) -> non_neg_integer().
length(T) -> cps(T).

%% @doc Number of bytes in the rope's UTF-8 encoding.
-spec bytes(rope()) -> non_neg_integer().
bytes(empty)              -> 0;
bytes(#leaf{bytes = B})   -> B;
bytes(#node{bytes = B})   -> B.

-spec is_empty(rope()) -> boolean().
is_empty(empty) -> true;
is_empty(_)     -> false.

%%%===================================================================
%%% Editing
%%%===================================================================

%% @doc Insert `Sub' (a binary or another rope) so that its first codepoint
%% lands at codepoint `Index'.  `Index' may equal the rope length (append).
-spec insert(rope(), non_neg_integer(), binary() | rope()) -> rope().
insert(T, Index, Sub) when is_integer(Index), Index >= 0 ->
    N = cps(T),
    Index =< N orelse erlang:error(badarg, [T, Index, Sub]),
    Ins = coerce(Sub),
    {L, R} = split_tree(T, Index),
    join(join(L, Ins), R);
insert(T, Index, Sub) ->
    erlang:error(badarg, [T, Index, Sub]).

%% @doc Remove `Len' codepoints starting at codepoint `Index'.
-spec delete(rope(), non_neg_integer(), non_neg_integer()) -> rope().
delete(T, Index, Len)
  when is_integer(Index), Index >= 0, is_integer(Len), Len >= 0 ->
    N = cps(T),
    Index + Len =< N orelse erlang:error(badarg, [T, Index, Len]),
    {L, Rest} = split_tree(T, Index),
    {_Mid, R} = split_tree(Rest, Len),
    join(L, R);
delete(T, Index, Len) ->
    erlang:error(badarg, [T, Index, Len]).

%% @doc Split into the first `Index' codepoints and the rest.
-spec split(rope(), non_neg_integer()) -> {rope(), rope()}.
split(T, Index) when is_integer(Index), Index >= 0 ->
    Index =< cps(T) orelse erlang:error(badarg, [T, Index]),
    split_tree(T, Index);
split(T, Index) ->
    erlang:error(badarg, [T, Index]).

-spec concat(rope() | binary(), rope() | binary()) -> rope().
concat(A, B) -> join(coerce(A), coerce(B)).

%% @doc The sub-rope of `Len' codepoints starting at codepoint `Index'.
-spec slice(rope(), non_neg_integer(), non_neg_integer()) -> rope().
slice(T, Index, Len)
  when is_integer(Index), Index >= 0, is_integer(Len), Len >= 0 ->
    Index + Len =< cps(T) orelse erlang:error(badarg, [T, Index, Len]),
    {_, Rest} = split_tree(T, Index),
    {Mid, _} = split_tree(Rest, Len),
    Mid;
slice(T, Index, Len) ->
    erlang:error(badarg, [T, Index, Len]).

-spec sub_binary(rope(), non_neg_integer(), non_neg_integer()) -> binary().
sub_binary(T, Index, Len) -> to_binary(slice(T, Index, Len)).

%% @doc The codepoint at `Index'.
%%
%% NOTE: this addresses a single codepoint, not a grapheme cluster - a
%% combining mark or emoji ZWJ sequence spans several indices.  Grapheme-aware
%% cursor movement is a separate layer (see TICKETS.md).
-spec at(rope(), non_neg_integer()) -> char().
at(T, Index) ->
    <<Cp/utf8, _/binary>> = sub_binary(T, Index, 1),
    Cp.

%%%===================================================================
%%% Line-aware API  (0-based lines; trailing "\n" yields a final empty line)
%%%===================================================================

-spec line_count(rope()) -> pos_integer().
line_count(T) -> lines(T) + 1.

%% @doc Codepoint index at which `Line' begins.  Valid for `Line' in
%% `0..line_count-1'.
-spec offset_of_line(rope(), non_neg_integer()) -> non_neg_integer().
offset_of_line(_T, 0) -> 0;
offset_of_line(T, Line) when is_integer(Line), Line > 0 ->
    Line =< lines(T) orelse erlang:error(badarg, [T, Line]),
    line_start(T, Line, 0);
offset_of_line(T, Line) ->
    erlang:error(badarg, [T, Line]).

%% @doc The 0-based line containing codepoint `Index' (i.e. the number of
%% newlines before it).  `Index' may equal the rope length.
-spec line_of_offset(rope(), non_neg_integer()) -> non_neg_integer().
line_of_offset(T, Index) when is_integer(Index), Index >= 0 ->
    Index =< cps(T) orelse erlang:error(badarg, [T, Index]),
    nl_before(T, Index, 0);
line_of_offset(T, Index) ->
    erlang:error(badarg, [T, Index]).

%% @doc The text of `Line', without its trailing "\n".
-spec line_at(rope(), non_neg_integer()) -> binary().
line_at(T, Line) ->
    Start = offset_of_line(T, Line),
    End = case Line >= lines(T) of
              true  -> cps(T);
              false -> offset_of_line(T, Line + 1) - 1
          end,
    sub_binary(T, Start, End - Start).

-spec index_to_line_col(rope(), non_neg_integer()) ->
          {non_neg_integer(), non_neg_integer()}.
index_to_line_col(T, Index) ->
    Line = line_of_offset(T, Index),
    {Line, Index - offset_of_line(T, Line)}.

%% @doc Codepoint index of `Col' codepoints into `Line'.  `Col' is counted in
%% codepoints, not grapheme clusters (see `at/2').
-spec line_col_to_index(rope(), non_neg_integer(), non_neg_integer()) ->
          non_neg_integer().
line_col_to_index(T, Line, Col) when is_integer(Col), Col >= 0 ->
    Start = offset_of_line(T, Line),
    LineEnd = case Line >= lines(T) of
                  true  -> cps(T);
                  false -> offset_of_line(T, Line + 1) - 1
              end,
    Col =< LineEnd - Start orelse erlang:error(badarg, [T, Line, Col]),
    Start + Col;
line_col_to_index(T, Line, Col) ->
    erlang:error(badarg, [T, Line, Col]).

%%%===================================================================
%%% Debug
%%%===================================================================

%% @doc Check every structural invariant: cached metrics equal the sum of the
%% children's, the tree is height-balanced, leaves are non-empty valid UTF-8 no
%% larger than ?MAX_LEAF, and internal nodes have no empty child.
-spec validate(rope()) -> ok | {error, term()}.
validate(T) ->
    try
        _ = check(T),
        ok
    catch
        throw:{invalid, Reason} -> {error, Reason}
    end.

%%%===================================================================
%%% Metrics accessors
%%%===================================================================

-spec cps(tree()) -> non_neg_integer().
cps(empty)            -> 0;
cps(#leaf{cps = C})   -> C;
cps(#node{cps = C})   -> C.

-spec lines(tree()) -> non_neg_integer().
lines(empty)            -> 0;
lines(#leaf{lines = L}) -> L;
lines(#node{lines = L}) -> L.

-spec height(tree()) -> non_neg_integer().
height(empty)              -> 0;
height(#leaf{})            -> 1;
height(#node{height = H})  -> H.

%%%===================================================================
%%% Node construction and balancing
%%%===================================================================

%% Build a leaf, collapsing the empty binary to `empty' so the tree never holds
%% a zero-length leaf.
-spec mk_leaf(binary()) -> empty | #leaf{}.
mk_leaf(<<>>) -> empty;
mk_leaf(Bin) ->
    #leaf{bytes = byte_size(Bin),
          cps   = count_cps(Bin, 0),
          lines = count_nl(Bin, 0),
          text  = Bin}.

%% Combine two subtrees into a node, recomputing cached metrics.  An `empty'
%% child collapses away, so nodes always have two non-empty children.
-spec mk_node(tree(), tree()) -> tree().
mk_node(empty, R) -> R;
mk_node(L, empty) -> L;
mk_node(L, R) ->
    #node{bytes  = bytes(L) + bytes(R),
          cps    = cps(L) + cps(R),
          lines  = lines(L) + lines(R),
          height = 1 + max(height(L), height(R)),
          left   = L,
          right  = R}.

-spec rotate_right(#node{}) -> tree().
rotate_right(#node{left = #node{left = LL, right = LR}, right = R}) ->
    mk_node(LL, mk_node(LR, R)).

-spec rotate_left(#node{}) -> tree().
rotate_left(#node{left = L, right = #node{left = RL, right = RR}}) ->
    mk_node(mk_node(L, RL), RR).

%% One AVL fix-up step: assumes the children are individually balanced and
%% differ in height by at most two.
-spec balance(tree()) -> tree().
balance(#node{left = L, right = R} = N) ->
    case height(L) - height(R) of
        BF when BF > 1 ->
            #node{left = LL, right = LR} = L,
            case height(LL) >= height(LR) of
                true  -> rotate_right(N);
                false -> rotate_right(mk_node(rotate_left(L), R))
            end;
        BF when BF < -1 ->
            #node{left = RL, right = RR} = R,
            case height(RR) >= height(RL) of
                true  -> rotate_left(N);
                false -> rotate_left(mk_node(L, rotate_right(R)))
            end;
        _ ->
            N
    end;
balance(T) ->
    T.

%% AVL join: concatenate two balanced trees, descending the taller one's spine
%% and re-balancing on the way back up.  Does not coalesce leaves.
-spec join_balanced(tree(), tree()) -> tree().
join_balanced(empty, R) -> R;
join_balanced(L, empty) -> L;
join_balanced(L, R) ->
    HL = height(L),
    HR = height(R),
    if
        HL =< HR + 1 andalso HR =< HL + 1 ->
            mk_node(L, R);
        HL > HR + 1 ->
            #node{left = LL, right = LR} = L,
            balance(mk_node(LL, join_balanced(LR, R)));
        true ->
            #node{left = RL, right = RR} = R,
            balance(mk_node(join_balanced(L, RL), RR))
    end.

%% Concatenate two trees, first merging the leaf at the seam when the two
%% adjacent leaves together fit in one (`?MAX_LEAF').  This keeps repeated
%% small edits from shredding the rope into tiny leaves.
%%
%% NOTE: only the single seam pair is merged; a caller that splices in many
%% tiny fragments at once still relies on each `join' to tidy its own seam.
-spec join(tree(), tree()) -> tree().
join(empty, R) -> R;
join(L, empty) -> L;
join(L, R) ->
    #leaf{bytes = LB, text = LT} = rightmost_leaf(L),
    #leaf{bytes = RB, text = RT} = leftmost_leaf(R),
    case LB + RB =< ?MAX_LEAF of
        true ->
            {L2, _} = pop_rightmost(L),
            {R2, _} = pop_leftmost(R),
            Merged = mk_leaf(<<LT/binary, RT/binary>>),
            join_balanced(join_balanced(L2, Merged), R2);
        false ->
            join_balanced(L, R)
    end.

-spec leftmost_leaf(tree()) -> #leaf{}.
leftmost_leaf(#leaf{} = L)      -> L;
leftmost_leaf(#node{left = L})  -> leftmost_leaf(L).

-spec rightmost_leaf(tree()) -> #leaf{}.
rightmost_leaf(#leaf{} = L)      -> L;
rightmost_leaf(#node{right = R}) -> rightmost_leaf(R).

-spec pop_leftmost(tree()) -> {tree(), #leaf{}}.
pop_leftmost(#leaf{} = L) ->
    {empty, L};
pop_leftmost(#node{left = L, right = R}) ->
    {L2, Leaf} = pop_leftmost(L),
    {join_balanced(L2, R), Leaf}.

-spec pop_rightmost(tree()) -> {tree(), #leaf{}}.
pop_rightmost(#leaf{} = L) ->
    {empty, L};
pop_rightmost(#node{left = L, right = R}) ->
    {R2, Leaf} = pop_rightmost(R),
    {join_balanced(L, R2), Leaf}.

%%%===================================================================
%%% Splitting
%%%===================================================================

-spec split_tree(tree(), non_neg_integer()) -> {tree(), tree()}.
split_tree(T, 0) ->
    {empty, T};
split_tree(#leaf{cps = C} = L, C) ->
    {L, empty};
split_tree(#leaf{text = Txt}, I) ->
    ByteOff = cp_to_byte(Txt, I),
    <<A:ByteOff/binary, B/binary>> = Txt,
    {mk_leaf(A), mk_leaf(B)};
split_tree(#node{cps = C} = T, C) ->
    {T, empty};
split_tree(#node{left = L, right = R}, I) ->
    LC = cps(L),
    if
        I < LC ->
            {LL, LR} = split_tree(L, I),
            {LL, join(LR, R)};
        I > LC ->
            {RL, RR} = split_tree(R, I - LC),
            {join(L, RL), RR};
        true ->
            {L, R}
    end.

%%%===================================================================
%%% Line navigation
%%%===================================================================

%% Codepoint index just past the `Line'-th newline (Line >= 1).
-spec line_start(tree(), pos_integer(), non_neg_integer()) -> non_neg_integer().
line_start(#leaf{text = Txt}, Line, Base) ->
    Base + cp_past_nth_nl(Txt, Line, 0, 0);
line_start(#node{left = L, right = R}, Line, Base) ->
    LL = lines(L),
    case Line =< LL of
        true  -> line_start(L, Line, Base);
        false -> line_start(R, Line - LL, Base + cps(L))
    end.

-spec cp_past_nth_nl(binary(), pos_integer(), non_neg_integer(),
                     non_neg_integer()) -> non_neg_integer().
cp_past_nth_nl(<<$\n, _/binary>>, Nth, Cp, Seen) when Seen + 1 =:= Nth ->
    Cp + 1;
cp_past_nth_nl(<<$\n, Rest/binary>>, Nth, Cp, Seen) ->
    cp_past_nth_nl(Rest, Nth, Cp + 1, Seen + 1);
cp_past_nth_nl(<<_/utf8, Rest/binary>>, Nth, Cp, Seen) ->
    cp_past_nth_nl(Rest, Nth, Cp + 1, Seen).

%% Number of newlines within the first `I' codepoints.
-spec nl_before(tree(), non_neg_integer(), non_neg_integer()) ->
          non_neg_integer().
nl_before(_T, 0, Acc) ->
    Acc;
nl_before(#leaf{text = Txt}, I, Acc) ->
    Acc + count_nl_prefix(Txt, I, 0);
nl_before(#node{left = L, right = R}, I, Acc) ->
    LC = cps(L),
    case I =< LC of
        true  -> nl_before(L, I, Acc);
        false -> nl_before(R, I - LC, Acc + lines(L))
    end.

-spec count_nl_prefix(binary(), non_neg_integer(), non_neg_integer()) ->
          non_neg_integer().
count_nl_prefix(_Bin, 0, Acc) ->
    Acc;
count_nl_prefix(<<$\n, Rest/binary>>, I, Acc) ->
    count_nl_prefix(Rest, I - 1, Acc + 1);
count_nl_prefix(<<_/utf8, Rest/binary>>, I, Acc) ->
    count_nl_prefix(Rest, I - 1, Acc).

%%%===================================================================
%%% Binary / codepoint helpers
%%%===================================================================

-spec to_iolist(tree()) -> iolist().
to_iolist(empty)                          -> [];
to_iolist(#leaf{text = T})               -> T;
to_iolist(#node{left = L, right = R})    -> [to_iolist(L), to_iolist(R)].

-spec coerce(binary() | tree()) -> tree().
coerce(B) when is_binary(B) -> from_binary(B);
coerce(empty)               -> empty;
coerce(#leaf{} = L)         -> L;
coerce(#node{} = N)         -> N;
coerce(Other)               -> erlang:error(badarg, [Other]).

-spec is_valid_utf8(binary()) -> boolean().
is_valid_utf8(<<>>)                  -> true;
is_valid_utf8(<<_/utf8, R/binary>>)  -> is_valid_utf8(R);
is_valid_utf8(_)                     -> false.

-spec count_cps(binary(), non_neg_integer()) -> non_neg_integer().
count_cps(<<>>, N)                  -> N;
count_cps(<<_/utf8, R/binary>>, N)  -> count_cps(R, N + 1).

-spec count_nl(binary(), non_neg_integer()) -> non_neg_integer().
count_nl(<<>>, N)               -> N;
count_nl(<<$\n, R/binary>>, N)  -> count_nl(R, N + 1);
count_nl(<<_, R/binary>>, N)    -> count_nl(R, N).

%% Byte offset of the `I'-th codepoint in a UTF-8 binary.
-spec cp_to_byte(binary(), non_neg_integer()) -> non_neg_integer().
cp_to_byte(Bin, I) -> cp_to_byte(Bin, I, 0).

-spec cp_to_byte(binary(), non_neg_integer(), non_neg_integer()) ->
          non_neg_integer().
cp_to_byte(_Bin, 0, Acc) ->
    Acc;
cp_to_byte(<<_/utf8, Rest/binary>> = Bin, I, Acc) ->
    Consumed = byte_size(Bin) - byte_size(Rest),
    cp_to_byte(Rest, I - 1, Acc + Consumed).

%% Split a binary into UTF-8-boundary-aligned chunks of at most `Size' bytes.
-spec chunk(binary(), pos_integer()) -> [binary()].
chunk(<<>>, _Size) ->
    [];
chunk(Bin, Size) when byte_size(Bin) =< Size ->
    [Bin];
chunk(Bin, Size) ->
    Adj = utf8_floor(Bin, Size),
    <<Head:Adj/binary, Tail/binary>> = Bin,
    [Head | chunk(Tail, Size)].

%% Largest N =< Size such that byte N does not begin mid-codepoint.
-spec utf8_floor(binary(), pos_integer()) -> pos_integer().
utf8_floor(Bin, Size) ->
    case Bin of
        <<_:Size/binary, B, _/binary>> when B band 16#C0 =:= 16#80 ->
            utf8_floor(Bin, Size - 1);
        _ ->
            Size
    end.

%% Balanced build from a list of leaves by recursive halving: the two halves
%% differ in length by at most one, so their heights differ by at most one and
%% the result is AVL-valid.
-spec build([empty | #leaf{}]) -> tree().
build(Ts) -> build_up([T || T <- Ts, T =/= empty]).

-spec build_up([tree()]) -> tree().
build_up([])  -> empty;
build_up([T]) -> T;
build_up(Ts) ->
    {L, R} = lists:split(erlang:length(Ts) div 2, Ts),
    mk_node(build_up(L), build_up(R)).

%%%===================================================================
%%% validate/1 worker
%%%===================================================================

%% Returns {Bytes, Cps, Lines, Height} of the checked subtree, or throws
%% {invalid, Reason}.
-spec check(tree()) ->
          {non_neg_integer(), non_neg_integer(), non_neg_integer(),
           non_neg_integer()}.
check(empty) ->
    {0, 0, 0, 0};
check(#leaf{bytes = B, cps = C, lines = L, text = Txt}) ->
    byte_size(Txt) =:= B orelse throw({invalid, {leaf_bytes, B}}),
    count_cps(Txt, 0) =:= C orelse throw({invalid, {leaf_cps, C}}),
    count_nl(Txt, 0) =:= L orelse throw({invalid, {leaf_lines, L}}),
    Txt =/= <<>> orelse throw({invalid, empty_leaf}),
    B =< ?MAX_LEAF orelse throw({invalid, {leaf_too_big, B}}),
    is_valid_utf8(Txt) orelse throw({invalid, bad_utf8}),
    {B, C, L, 1};
check(#node{bytes = B, cps = C, lines = L, height = H,
            left = Lft, right = Rgt}) ->
    (Lft =/= empty andalso Rgt =/= empty)
        orelse throw({invalid, empty_child}),
    {BL, CL, LL, HL} = check(Lft),
    {BR, CR, LR, HR} = check(Rgt),
    B =:= BL + BR orelse throw({invalid, {node_bytes, B}}),
    C =:= CL + CR orelse throw({invalid, {node_cps, C}}),
    L =:= LL + LR orelse throw({invalid, {node_lines, L}}),
    H =:= 1 + max(HL, HR) orelse throw({invalid, {node_height, H}}),
    abs(HL - HR) =< 1 orelse throw({invalid, {imbalance, HL, HR}}),
    {B, C, L, H}.
