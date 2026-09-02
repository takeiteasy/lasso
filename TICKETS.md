# Deferred work

Tracked here until the sr.ht `cowboy` tracker exists; move each item to the
tracker once it does.

## Grapheme-cluster layer

A `lasso_grapheme` module wrapping the codepoint API so cursor movement treats a
combining sequence or emoji ZWJ sequence as one unit. `at/2` and
`line_col_to_index/3` currently count codepoints and carry a source comment
pointing here.

## Iteration and streaming

- `fold/3` over the leaf chunks without materialising `to_binary/1`.
- An iterator for incremental rendering (resume from a codepoint or line offset).
- `from_file/1` building a rope from a file without reading it whole.

## Stateful buffer process

A `gen_server` owning a rope, with an undo/redo history stack, for use as an
editor buffer. Separable from the immutable data structure.

## Possible improvements

- `join/2` coalesces only the single seam pair. A multi-fragment splice path
  could coalesce a run of small leaves in one pass.
- `line_at/2` for a very long line copies the whole line into a binary; a
  streaming variant would help a pathological single-line file.
