# Design

## Representation

A rope is one of:

| Value        | Meaning                                             |
|--------------|----------------------------------------------------|
| `empty`      | the empty rope (never a zero-length leaf)           |
| `#leaf{}`    | a chunk of text as a non-empty UTF-8 `binary()`     |
| `#node{}`    | an internal node with two non-empty children        |

Records are defined in `include/lasso.hrl`. Both leaves and nodes cache the
aggregate metrics of the text they cover:

- `bytes` - bytes in the subtree's UTF-8 encoding
- `cps`   - Unicode codepoints
- `lines` - newline (`\n`) characters

Nodes additionally cache `height` for AVL balancing. Because every metric is a
sum over children, each one is read in `O(1)` at any node and navigation costs
`O(height)`.

## Index space

Every public index and length is measured in **codepoints**, 0-based. Byte
offsets never appear in the API; they are resolved inside a leaf by walking the
UTF-8 lead bytes (`cp_to_byte/2`), which is bounded work because a leaf is at
most `?MAX_LEAF` bytes.

`from_binary/1` validates that its argument is well-formed UTF-8 and raises
`badarg` otherwise, so every leaf in a rope is valid UTF-8 and no operation can
observe a partial codepoint.

## Line model

Lines are 0-based. A line is the text between two newlines; a trailing `\n`
therefore yields a final empty line. This matches `binary:split(Bin, <<"\n">>,
[global])`, which the property tests use as the reference.

- `line_count(new())` is `1`.
- `from_binary(<<"a\nb\n">>)` has 3 lines: `"a"`, `"b"`, `""`.
- `offset_of_line(R, 0)` is always `0`.
- `offset_of_line(R, Line)` is valid for `Line` in `0 .. line_count - 1`.
- `line_at/2` returns a line without its trailing `\n`.
- `index_to_line_col/2` accepts any offset in `0 .. length`; the column is the
  codepoint distance from the start of the line.

Line lookups descend by the cached `lines` weight, so `offset_of_line/2` and
`line_of_offset/2` never scan the whole rope.

## Balancing

The tree is kept AVL-balanced: at every node the child heights differ by at most
one.

- `from_binary/1` builds a balanced tree by recursively halving the leaf list,
  so the two halves differ in size by at most one.
- `join_balanced/2` concatenates two balanced trees by descending the taller
  one's spine and applying a single AVL fix-up (`balance/1`) on the way back up.
- `split_tree/2` walks to the target leaf, splits its binary on the resolved
  byte boundary, and reassembles each side with `join/2`.

`validate/1` checks the full set of invariants - metric sums, height balance,
non-empty leaves that are valid UTF-8 no larger than `?MAX_LEAF`, and internal
nodes with no empty child. The property tests call it after every operation.

## Leaf coalescing

Splitting and deleting would otherwise leave a trail of tiny adjacent leaves,
and character-at-a-time editing is exactly the editor workload. `join/2` merges
the two leaves at the seam whenever their combined size fits in one
(`?MAX_LEAF`). In steady state adjacent leaves therefore sum to more than
`?MAX_LEAF`, so the average leaf is over `?MAX_LEAF / 2` bytes and the leaf
count stays `O(bytes / ?MAX_LEAF)`. `prop_no_leaf_shredding` asserts this after
thousands of single-codepoint inserts.

Only the single seam pair is merged per `join/2`; splicing in many fragments at
once relies on each individual `join` tidying its own seam. This is adequate for
the insert/delete/split paths and keeps `join/2` at `O(log n)`.

Tuning macros in `include/lasso.hrl`:

- `?TARGET_LEAF` (512) - chunk size when building from a binary.
- `?MAX_LEAF` (1024) - a leaf never exceeds this after coalescing.

## Complexity

| Operation                              | Cost         |
|----------------------------------------|--------------|
| `length/1`, `bytes/1`, `line_count/1`  | `O(1)`       |
| `from_binary/1`, `to_binary/1`         | `O(n)`       |
| `insert/3`, `delete/3`, `split/2`, `concat/2`, `slice/3` | `O(log n)` |
| `at/2`, `sub_binary/3` (fixed length)  | `O(log n)`   |
| `offset_of_line/2`, `line_of_offset/2`, `index_to_line_col/2` | `O(log n)` |
| `line_at/2`                            | `O(log n + line length)` |
| `validate/1`                           | `O(n)`       |

`n` is the codepoint count. Because the structure is immutable and persistent,
an edit shares all untouched subtrees with the previous version.
