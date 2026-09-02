%% lasso - internal representation.
%%
%% A rope is a binary tree. Leaves hold a chunk of the text as a UTF-8 binary;
%% internal nodes cache the aggregate metrics of their subtree so that every
%% navigation step (by codepoint index or by line number) is O(height).
%%
%% Metrics, for both leaves and nodes:
%%   bytes  - number of bytes in the subtree's text
%%   cps    - number of Unicode codepoints in the subtree's text
%%   lines  - number of newline (\n) characters in the subtree's text
%%
%% The empty rope is the atom 'empty' (never a zero-length leaf), so that the
%% tree has no degenerate nodes and pattern matches stay simple.

-record(leaf, {
    bytes = 0 :: non_neg_integer(),
    cps   = 0 :: non_neg_integer(),
    lines = 0 :: non_neg_integer(),
    text  = <<>> :: binary()
}).

-record(node, {
    bytes  = 0 :: non_neg_integer(),
    cps    = 0 :: non_neg_integer(),
    lines  = 0 :: non_neg_integer(),
    height = 1 :: pos_integer(),
    left   :: lasso:tree(),
    right  :: lasso:tree()
}).

%% Leaf-size tuning. Splitting and deleting can leave many small adjacent
%% leaves; coalescing merges neighbours whose combined size is under MAX_LEAF.
%% TARGET_LEAF is the chunk size used when building a rope from a binary.
-define(MAX_LEAF, 1024).
-define(TARGET_LEAF, 512).
