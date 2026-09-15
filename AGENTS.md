## Agent skills

### Issue tracker

Issues, specs, and the migration map live as GitHub issues; use the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The default canonical triage labels are used. See `docs/agents/triage-labels.md`.

### Domain docs

This repo uses a single-context layout. See `docs/agents/domain.md`.

<!-- agents-md-author:begin wayfinder-migration -->

## Wayfinder migration

- The route is the map issue labelled `wayfinder:map`; its child issues are the tickets, and the open, unblocked, unassigned ones are the frontier. Read the map before starting a slice or changing a ticket.
- Compatibility contracts and the capability inventory live in `docs/compatibility/`. The frozen-oracle harnesses and the executed WebView evidence they once produced live in the private `liber-archive` repository, which also holds this repository's pre-split history.
- Keep decision state, executed evidence, and product implementation separate. Verify the active branch, commit, manifest, and source hashes before promoting a result or closing a ticket.
- Evidence recorded on an unmerged branch stays branch-scoped until it is reviewed and integrated; a shared adapter change requires re-running the affected platform rows.
- A closed ticket records its answer; it is not proof that dependent gates or the Flutter product are complete. Keep `not-run`, coverage gaps, and policy rejections explicit in aggregate plans.
- After each runnable migration slice passes its automated checks, launch the Windows app for visual/manual review before starting the next slice.

<!-- agents-md-author:end wayfinder-migration -->
