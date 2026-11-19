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
- After each runnable migration slice passes its automated checks, review the Windows app in a driven run before starting the next slice: input goes through Dart MCP against a scratch installation directory, never through the operator's keyboard and mouse. See `README.md` → Verification and evidence → Driving the UI for the sequence and for what the driver cannot reach.

<!-- agents-md-author:end wayfinder-migration -->

<!-- agents-md-author:begin branch-and-worktree-lifecycle -->

## Branch and worktree lifecycle

- `master` is the only long-lived branch. `archive-master` is the local pointer to the pre-split history and is never pushed; the private `liber-archive` repository holds that history plus every retired branch, as `archived/<branch>`.
- Investigation work happens on a short-lived branch named after its ticket (`prototype/<ticket>`, `wayfinder/<ticket>`), usually in a task worktree beside the checkout (`../liber-<ticket>`).
- When a ticket closes: record its findings in the ticket, an ADR, or a contract document first; push any commit that exists nowhere else to `liber-archive`; then remove the worktree (`git worktree remove`) and delete the local branch. A closed ticket leaves no branch or worktree behind.
- Keep retired evidence reachable: `git log --oneline archive-master` and `git grep archive-master -- <path>` read the pre-split tree, and `git ls-remote --heads archive` lists what the archive kept.

<!-- agents-md-author:end branch-and-worktree-lifecycle -->

<!-- agents-md-author:begin lane-dispatch -->

## Spec execution

- Scope each implementation run to an operator-approved spec or an independently deliverable ticket slice.
  Use `to-spec` and `to-tickets` when missing scope or dependencies must be prepared, and execute multi-ticket
  graphs with `implement-spec`. Merge each verified ticket or runnable slice onto `master` incrementally once
  its automated checks and required gate pass, rather than holding the whole spec graph on a long-lived
  integration branch.
- Reuse existing specs, tickets and shared contracts. Freeze the starting SHA, acceptance and test interfaces.
  Evidence-backed spec or graph amendments use `amend-spec`; changes to approved scope or behavior return to
  the operator. Investigation and decision tickets keep their own acceptance and execution paths.
- Implementation and repair workers use `mistral-vibe/deepseek-v4-1-flash-1017:max`. The controller uses the
  operator-selected main-session model. Fresh Standards and Spec reviewers use that session's selected
  provider/model and thinking level, explicitly pinned at dispatch. An unavailable requested model is a
  dispatch blocker.
- For Pi execution use `subagent-delegation` and `pi-subagents`: one async workflow and, when coordinating
  parallel tickets, a short-lived `integration/<spec>` worktree. The controller owns the main checkout and
  serial integration merges, replacing the skill's merger subagent. Check each ticket's raw diff before
  merging and preserve existing work when its starting ref is wrong. Apply the Windows driven-run gate above
  to runnable UI slices.
- Briefs point to the spec, ticket, shared contracts, test interfaces and validation. Dart/Flutter work uses
  `flutter-dart-mcp` under the project's MCP/CLI split. Give every child an explicit `timeoutMs` and
  `checkpointBeforeDeadlineMs`; implementation lanes receive three hours. Implementers commit locally and
  leave an evidence comment with actual checks, acceptance and residuals; unresolved boundaries use
  `contact_supervisor`. Final acceptance, publication, ticket closure and map changes belong to the controller.
- Co-locate product regressions in the owning module's existing `test/*_test.dart` file with shared fixtures,
  asserting observable product behavior rather than script or harness source SHA-256 hashes. Keep `tool/`
  oracle capture and comparison scripts focused on producing and comparing committed `golden.json` evidence;
  never write meta-tests (unit tests for `capture.py`, fake-Android-SDK JVM tests for oracle harnesses, or
  synthetic corrupted-JSON negative-control matrices for comparators).
- Scope `code-review` (Standards and Spec reviewers) to `lib/` product behavior, contract compliance and core
  regression tests, with at most one repair-and-re-review round for genuine product bugs, crashes or contract
  violations. Exclude `tool/` capture scripts and comparator internals from defensive review expansion. The
  controller independently reproduces headline results before final acceptance.
- After acceptance, the controller merges `--no-ff` into `master`, verifies the integrated tree with
  `docs/compatibility/delivery-phases.md`'s verification matrix and claim gate, pushes once and waits for every
  platform row. Then resolve the tickets with evidence comments, update the map, link follow-ups and perform
  the branch/worktree cleanup above.
- A decision ticket gets its own interactive session with a briefing and `grilling`; it never runs as an
  implementation lane. Open that session in a Herdr pane beside the controller so the operator answers directly.
- Briefings, evidence and resolution comments reference artifacts rather than repeat them. Continue in the
  current session while its context is useful; use `handoff` for a new harness, directory, colleague or a
  mid-phase side task.

<!-- agents-md-author:end lane-dispatch -->
