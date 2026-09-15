# HTML rules are reproduced behind one explicit compatibility adapter

**Status:** accepted (2026-09-15)

The frozen baseline's selector semantics are Jsoup's plus Legado's own rule
layer, not standard CSS or standard XPath. The Dart `html`/`xml` pair is kept
only as a parser substrate behind a single adapter, because the probe showed
`nth-child(2)` off by one, `2n+1`/`:contains`/`:eq` unsupported, HTML
serialization unusable as an XML XPath bridge, and the historical XPath forms
rejected. Rule evaluation therefore reproduces the layered semantics in one
place that is testable per layer: the selection entry (`@CSS:`, `@XPath:`,
`@Json:` markers and the legacy naked syntax), `@` chains, the `&&`/`||`/`%%`
merges, index and slice positioning, and result extraction
(`text`/`textNodes`/`ownText`/`html`/`all`/attributes).

## Considered options

- **Use the community HTML/XML packages directly.** Rejected by the probe
  results above: tolerant parsing plus XPath is not the same engine, and the
  differences are exactly the ones real sources depend on.
- **Reimplement selectors per pipeline.** Rejected: the HTML, JSON, and legacy
  paths share positioning, merge, and extraction semantics, and duplicating them
  is how they drift apart.

## Consequences

Rule families that have no executed frozen-oracle row are `not-run` and may not
be cited in a compatibility claim. The adapter is the single place where the
layer semantics live, and its gaps stay visible in
`docs/compatibility/book-source-capability-matrix.md`.

Provenance: `liber-archive`, issue 12 with its probe record.
