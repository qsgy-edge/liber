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

## Lane dispatch and the batch loop

- Frontier work is dispatched as lanes: one async `subagent` workflow, one child per ticket, each with its own
  briefing file beside the handoff. Follow the `subagent-delegation` and `pi-subagents` skills for the mechanics;
  this section is the project's binding layer on top of them.
- Give every child an explicit `timeoutMs` (three hours for an implementation lane) and
  `checkpointBeforeDeadlineMs`; the default 30-minute child deadline kills lanes with uncommitted work.
- One writer per worktree (see Branch and worktree lifecycle). The main checkout belongs to the controller, and a
  lane never edits it.
- A lane commits locally and leaves one evidence comment on its ticket: what changed, the commands it ran with
  their actual results, the acceptance list checked off, and every divergence and residual risk. It never merges,
  pushes, or closes the ticket, and it asks the controller through `contact_supervisor` at a boundary instead of
  improvising.
- The controller verifies from the raw diff and re-runs the headline numbers itself; a lane's numbers are claims
  until reproduced.
- Close a batch in this order: merge `--no-ff` locally with the ticket number in the message, run the
  verification matrix on the integrated tree, push once, wait for every platform row, then close each ticket
  with a resolution comment, update the map, open and link the follow-up tickets the lanes proposed, and write
  the next handoff with the `handoff` skill.
- A decision ticket gets its own interactive session with a briefing and the `grilling` skill; it never runs as a
  lane.
- Handoffs, briefings, and resolution comments reference the artifact (ticket, ADR, document, commit) instead of
  restating it.

<!-- agents-md-author:end lane-dispatch -->
