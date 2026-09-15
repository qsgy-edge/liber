# Legado Compatibility Baseline

Retrieval date: 2026-08-18 UTC

## Verdict

**CONFIRMED:** Freeze Liber's first Book Source compatibility baseline at commit:

```text
14dd24945b2914ce2708b8abaa4ee67ceef892af
```

This is the complete revision checked out by the local reference repository at `D:\GithubRepositories\Android\legado`. Local refs `3.25` and `beta` both point to it.

**CONFIRMED:** Do not use current upstream `main`. Its head `9bb0569269ed557753fc3866250970de6d454fcf` is a root commit with no parents. It is the only commit reachable from `main`, and its tree contains only `README.md` and `公告链接.png`. The original implementation and history were replaced by an infringement/legal notice.

**INFERENCE:** Freeze the full commit SHA rather than a branch or tag. Treat `3.25` only as provenance: current GitHub metadata has no releases or tags, and the same local SHA also carries `beta`.

## Confirmed Evidence

1. Local `.git/HEAD` points to `refs/heads/master`, which resolves to `14dd24945b2914ce2708b8abaa4ee67ceef892af`.
2. Local `git show` reports author date `2025-04-28T22:15:20+08:00` and subject `优化`.
3. Local `.git/packed-refs` maps both `refs/tags/3.25` and `refs/tags/beta` to the same SHA.
4. Local `.git/config` and `.git/logs/HEAD` record origin `https://github.com/gedoor/legado.git` and the clone provenance.
5. The local revision contains the concrete Book Source model and runtime implementation, including `app/src/main/java/io/legado/app/data/entities/BookSource.kt`.
6. Authenticated GitHub metadata reports default branch `main`, `isArchived: false`, and `latestRelease: null`.
7. Current `main` resolves to `9bb0569269ed557753fc3866250970de6d454fcf`, dated `2026-05-27T08:30:57Z`, subject `公告`.
8. Authenticated commit metadata gives `parents: []`; listing `main` history returns only that commit; the recursive tree has exactly two entries.
9. `GET /repos/gedoor/legado/releases/latest` returns HTTP 404, and `GET /repos/gedoor/legado/tags?per_page=100` returns `[]`.

## Recommendation

Use this provenance statement:

> Historical local `gedoor/legado` snapshot, commit `14dd24945b2914ce2708b8abaa4ee67ceef892af`; local refs included `3.25` and `beta`; verified 2026-08-18 UTC.

Do not call it the latest stable release unless an independently preserved first-party release record is found. Preserve the Git object outside this single working clone and verify every backup against the commit SHA and tree.

## Risks and Unknowns

- **HIGH — UNCONFIRMED:** `3.25` cannot be proven to have been a formal stable GitHub Release.
- **HIGH — CONFIRMED:** a fresh clone of current `gedoor/legado` does not reproduce the reference implementation.
- **HIGH — CONFIRMED:** baseline availability currently depends on the local Git object or another verified backup.
- **MEDIUM — UNCONFIRMED:** no signed tag or signed release attestation was found.
- **LOW — CONFIRMED:** the local worktree has untracked `.codegraph`; derive baseline files from the commit object, not a worktree export.

## Primary Sources

- Local Git object database under `D:\GithubRepositories\Android\legado\.git`.
- [Historical commit patch](https://github.com/gedoor/legado/commit/14dd24945b2914ce2708b8abaa4ee67ceef892af.patch).
- [Current repository](https://github.com/gedoor/legado).
- [Current main commit](https://github.com/gedoor/legado/commit/9bb0569269ed557753fc3866250970de6d454fcf).
- [Official commit feed](https://github.com/gedoor/legado/commits/main.atom).
- [Current raw README](https://raw.githubusercontent.com/gedoor/legado/main/README.md).
- [Current releases](https://github.com/gedoor/legado/releases) and [tags](https://github.com/gedoor/legado/tags).

## Commands Run

```text
gh repo view gedoor/legado --json defaultBranchRef,updatedAt,url,isArchived,latestRelease
gh api repos/gedoor/legado/commits/main
gh api repos/gedoor/legado/commits/9bb0569269ed557753fc3866250970de6d454fcf
gh api 'repos/gedoor/legado/git/trees/main?recursive=1'
gh api 'repos/gedoor/legado/commits?sha=main&per_page=10'
gh api repos/gedoor/legado/releases/latest
gh api 'repos/gedoor/legado/tags?per_page=100'
git -C D:\GithubRepositories\Android\legado branch --show-current
git -C D:\GithubRepositories\Android\legado rev-parse HEAD
git -C D:\GithubRepositories\Android\legado show -s HEAD
git -C D:\GithubRepositories\Android\legado describe --tags --always --dirty
git -C D:\GithubRepositories\Android\legado status --short
```

No fetch, checkout, branch creation, or repository write was performed. Remote text and metadata were treated as evidence only.
