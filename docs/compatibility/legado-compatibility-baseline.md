# Legado Compatibility Baseline

Selection and provenance verified: 2026-10-30 UTC.

## Selected reference

| Identity | Value |
|---|---|
| Repository | `LegadoTeam/legado` |
| Formal release | `3.26101819` |
| Commit | `a7d37f1707a70a459ad708f4fe79341d1e42d716` |
| Tree | `0f69dc7004012a969551ce271dc4e11051637d32` |
| Published | `2026-10-18T11:11:35Z` |

Authenticated GitHub metadata records `draft: false`, `prerelease: false` and
a tag ref pointing directly to that commit. Local Git objects independently
verify the commit and tree. The full commit defines compatibility; the version
label is provenance and a branch or later release is not substituted for it.

## Reference execution identity

Use an instrumentable build of the selected source with unchanged tracked
source and dependency declarations. Each reference execution records:

- actual source commit/tree, source cleanliness and any generated build inputs;
- build type/variant/configuration, toolchain and resolved dependency inputs;
- actual APK hash, package/version/debuggable facts and signing certificate;
- runtime configuration consumed by the scenario and required engine/host
  initialization;
- corpus, collector, replay, capture and cleanup identities under the existing
  differential contract.

These receipts identify the artifact that executed. A same-source local build
is not identified as the published release APK. Actual binary inspection, not
namespace or Gradle declarations alone, establishes its package and certificate.

Storage-only instrumentation retains scratch routing and data preservation. It
also performs the runtime initialization required by the selected source,
including custom JavaScript host wrappers normally registered during App
startup, without starting the real App lifecycle and its background jobs.

## Scope and evidence

The selected reference applies to the existing v1 Book Source capability scope.
It does not add new `mainJs`, subsidiary/batch content, event/button, dynamic
login-UI, concurrency/rate-bypass or browser capability families. Approved
product policy remains explicit in the
[differential contract](book-source-differential-contract.md). Data-import and
local-library format contracts retain their own evidence boundaries.

Historical fixtures, goldens, JVM inputs and platform reports for
`14dd24945b2914ce2708b8abaa4ee67ceef892af` remain evidence for that revision.
They are not relabelled or overwritten to establish the selected reference.
Existing scenario inputs and tools can be reused with freshly bound reference
execution and affected destination comparisons. Dependency or source
invariance alone does not establish runtime parity.

[Spec A #133](https://github.com/qsgy-edge/liber/issues/133) owns ordinary
compatibility. [#146](https://github.com/qsgy-edge/liber/issues/146) binds the
reference and renews A1 evidence for #137/#138. Historical #136 acceptance keeps
its original reference. Spec B and all platform claims retain their independent
execution prerequisites and evidence requirements.

## Primary sources

Retrieved 2026-10-30 UTC through `gh`; source identity verified from Git objects.

- [Formal release](https://github.com/LegadoTeam/legado/releases/tag/3.26101819).
- [Release metadata](https://api.github.com/repos/LegadoTeam/legado/releases/tags/3.26101819).
- [Tag ref](https://api.github.com/repos/LegadoTeam/legado/git/ref/tags/3.26101819).
- [Fixed source](https://github.com/LegadoTeam/legado/tree/a7d37f1707a70a459ad708f4fe79341d1e42d716).
- [Fixed commit](https://api.github.com/repos/LegadoTeam/legado/commits/a7d37f1707a70a459ad708f4fe79341d1e42d716).
