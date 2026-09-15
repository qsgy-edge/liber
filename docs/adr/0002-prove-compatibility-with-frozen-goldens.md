# Compatibility is proved by frozen goldens over a controlled replay corpus

**Status:** accepted (2026-09-15)

A Book Source is compatible on a platform only when every stage and capability
it reaches passes the differential contract on that platform, proved against
immutable goldens produced by executing the frozen baseline against a controlled
local replay server. A live site is never the oracle. The contract compares
requests causally (order, method, URL, source-declared headers, body bytes), the
runtime configuration they consume, source-visible cache and cookie state,
persistent records, normalized outputs, stable failure categories, and
source-observable cleanup. It preserves unusual observable behavior but not
Kotlin exception classes, stack traces, or internal implementation defects: a
behavior that would break security or data integrity is registered as a policy
divergence instead of being copied.

## Considered options

- **Certify sources against live sites.** Rejected: results are not repeatable,
  cannot be attributed to a build, and hide state-dependent differences.
- **Hand-written expectations as goldens.** Rejected: a golden must come from
  executing the frozen oracle; human expectations are only an audit aid.
- **Treat "a book was found" as compatibility.** Rejected: it hides which stage
  failed and which capabilities were exercised.

## Consequences

Coverage gaps, `not-run` rows, and approved `policy-rejected` rows block an
aggregate compatibility claim rather than being averaged away, and a green
workflow promotes no compatibility state. The committed platform- and
destination-scoped goldens with their manifests are the evidence; a shared
adapter change re-runs the affected platform rows.

See `docs/compatibility/book-source-differential-contract.md` and
`docs/compatibility/book-source-capability-matrix.md`. Provenance:
`liber-archive`, issues 02 and 12.
