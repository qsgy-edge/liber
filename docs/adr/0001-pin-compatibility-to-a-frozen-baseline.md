# Compatibility is pinned to one frozen Legado snapshot

**Status:** accepted (2026-09-15)

Book Source compatibility is measured against the local Legado snapshot
`14dd24945b2914ce2708b8abaa4ee67ceef892af`, not against upstream `main`, tags, or
the newest release. Upstream's `main` head `9bb0569269ed557753fc3866250970de6d454fcf`
is a parentless commit whose tree holds only `README.md` and a notice image: the
implementation and its history were replaced by a legal notice, so "latest" no
longer identifies the implementation this product is compatible with. The commit
SHA is frozen rather than a branch or tag because the local `3.25` and `beta`
refs both point at it while upstream publishes no releases.

## Considered options

- **Track upstream `main` or the newest release.** Rejected: the branch no
  longer contains the implementation, and there is no release to track.
- **Record only the version name (`3.25`).** Rejected: two local refs carry the
  same SHA, so a name is not a stable identifier. The name is kept as provenance
  only.

## Consequences

Every golden, fixture, and differential row names this SHA. Moving the baseline
invalidates the committed evidence and requires re-running the frozen oracle;
the retired oracle harnesses live in the private `liber-archive` repository.

See `docs/compatibility/legado-compatibility-baseline.md`. Provenance:
`liber-archive`, `.scratch/flutter-legado-reader/issues/01-freeze-legado-baseline.md`.
