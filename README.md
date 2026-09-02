# lasso

A purely-functional [rope](https://en.wikipedia.org/wiki/Rope_(data_structure))
for text editors, written in Erlang/OTP.

Text is held as UTF-8 in the leaves of a height-balanced binary tree. Every node
caches the byte, codepoint and newline counts of its subtree, so insert, delete,
split and concat at an arbitrary position are `O(log n)`, and so is mapping
between a codepoint offset and a line/column.

```erlang
R  = lasso:from_binary(<<"héllo\nwörld\n"/utf8>>),
12 = lasso:length(R),                         % codepoints
3  = lasso:line_count(R),                      % trailing \n -> a final empty line
R2 = lasso:insert(R, 6, <<"there ">>),
<<"héllo\nthere wörld\n"/utf8>> = lasso:to_binary(R2),
{1, 6} = lasso:index_to_line_col(R2, 12).
```

## Status

Milestone 1 - the immutable core and the line-aware API. Grapheme-cluster
movement, streaming/iteration and a stateful buffer process are planned; see
the [tracker](https://todo.sr.ht/~takeiteasy/lasso).

## Documentation

- [docs/design.md](docs/design.md) - representation, cached metrics, invariants,
  complexity.
- [docs/api.md](docs/api.md) - function reference.

## Building

```sh
rebar3 compile
rebar3 eunit        # unit + regression tests
rebar3 proper       # model-based property tests
rebar3 dialyzer
```

## Licence

GPL-3.0-or-later. See [COPYING](COPYING).
