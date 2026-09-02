# API reference

Module `lasso`. All index and length arguments are **codepoints**, 0-based.
Line numbers are 0-based; a trailing `\n` yields a final empty line. Out-of-range
arguments raise `badarg`.

The rope type is `lasso:rope()`. It is an ordinary term (an atom or a record
from `include/lasso.hrl`); treat it as opaque.

## Construction and conversion

| Function | Description |
|----------|-------------|
| `new() -> rope()` | The empty rope. |
| `from_binary(binary()) -> rope()` | Build from a UTF-8 binary. Raises `badarg` if the bytes are not valid UTF-8 or the argument is not a binary. |
| `to_binary(rope()) -> binary()` | The rope's text as one UTF-8 binary. |
| `to_list(rope()) -> string()` | The text as a list of codepoints. |

## Measurement

| Function | Description |
|----------|-------------|
| `length(rope()) -> non_neg_integer()` | Number of codepoints. |
| `bytes(rope()) -> non_neg_integer()` | Number of bytes in the UTF-8 encoding. |
| `is_empty(rope()) -> boolean()` | Whether the rope has no text. |

## Editing

Every function returns a new rope; the argument is unchanged.

| Function | Description |
|----------|-------------|
| `insert(rope(), Index, binary() \| rope()) -> rope()` | Insert so the new text begins at `Index`. `Index` may equal `length` (append). A binary argument is validated as UTF-8. |
| `delete(rope(), Index, Len) -> rope()` | Remove `Len` codepoints starting at `Index`. |
| `split(rope(), Index) -> {rope(), rope()}` | The first `Index` codepoints and the rest. |
| `concat(rope() \| binary(), rope() \| binary()) -> rope()` | Concatenate. Binary arguments are validated as UTF-8. |
| `slice(rope(), Index, Len) -> rope()` | The sub-rope of `Len` codepoints from `Index`. |
| `sub_binary(rope(), Index, Len) -> binary()` | `slice/3` as a binary. |
| `at(rope(), Index) -> char()` | The codepoint at `Index`. Addresses a single codepoint, not a grapheme cluster. |

## Line-aware

| Function | Description |
|----------|-------------|
| `line_count(rope()) -> pos_integer()` | Number of lines. `1` for the empty rope. |
| `line_at(rope(), Line) -> binary()` | The text of `Line`, without its trailing `\n`. |
| `offset_of_line(rope(), Line) -> Index` | Codepoint index where `Line` begins. Valid for `Line` in `0 .. line_count - 1`. |
| `line_of_offset(rope(), Index) -> Line` | The line containing codepoint `Index` (the newline count before it). `Index` may equal `length`. |
| `index_to_line_col(rope(), Index) -> {Line, Col}` | `Col` is the codepoint distance from the line start. |
| `line_col_to_index(rope(), Line, Col) -> Index` | Inverse of `index_to_line_col/2`. `Col` is counted in codepoints, not grapheme clusters. |

## Debug

| Function | Description |
|----------|-------------|
| `validate(rope()) -> ok \| {error, term()}` | Check every structural invariant (see [design.md](design.md)). |
