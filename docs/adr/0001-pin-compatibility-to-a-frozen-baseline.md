# Compatibility is pinned to one immutable Legado revision

**Status:** accepted (2026-10-30)

Book Source compatibility is measured against `LegadoTeam/legado` formal release
`3.26101819`, commit `a7d37f1707a70a459ad708f4fe79341d1e42d716`, tree
`0f69dc7004012a969551ce271dc4e11051637d32`. The formal release identifies the
source lineage; the full commit, not a moving branch or version label, defines
the reference. Its source and release metadata are independently retrievable.

The reference oracle uses an instrumentable build of that exact source. Each
execution binds its actual source, build configuration, APK, certificate, runtime
initialization and scenario inputs. A source-built reference and the published
release APK are distinct artifacts; provenance identifies which one executed.

## Considered options

- **Keep the historical local snapshot.** It avoids immediate re-capture, but
  further ordinary-source acceptance would still target the older runtime and
  need renewal when adopting the selected formal release.
- **Track a branch, newest release or version label.** These can move without
  changing Liber. The compatibility definition instead names one full commit.
- **Require the published release APK as the only oracle.** Its certificate and
  retained reflection surface would constrain the existing collectors. A bound
  same-source instrumentable build preserves the fixed source definition and
  the existing replay/scratch collection mechanism.

## Consequences

The selected revision does not expand v1 capability scope or replace approved
Liber policies. Spec A #133 owns ordinary behavior; #146 owns the reference and
renewed A1 evidence, and #137/#138 consume that handoff. Browser work remains
under Spec B and its existing execution prerequisites.

Every golden, fixture and comparison names its actual reference. Evidence for
`14dd24945b2914ce2708b8abaa4ee67ceef892af` retains that scope; changing the
selected reference requires fresh reference-side execution and affected
destination comparisons, not replacement of historical identity fields.

See [the baseline contract](../compatibility/legado-compatibility-baseline.md)
and [Spec A](https://github.com/qsgy-edge/liber/issues/133).
