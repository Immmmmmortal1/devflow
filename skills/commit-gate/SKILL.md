---
name: commit-gate
description: Block git commit until implementation is summarized, required validation is reported, and the user explicitly confirms. Then use git-commit-convention to create the commit message and commit.
---

# Commit Gate

## Purpose

No commit on agent initiative.

Every commit must represent exactly one atomic feature module or one independent bug fix. A
commit must not combine unrelated features, multiple independent bug fixes, refactors, or
formatting changes. If the worktree contains several modules, split them into separate commits
and validate each commit scope independently.

After each atomic feature or bug fix is implemented and validated, dev-flow must automatically
generate a Chinese commit title and body for that exact scope by following `git-commit-convention`.
Message generation is mandatory before the commit confirmation request, but it never authorizes or
performs the commit by itself.

## When

After implementation and validation, before `git commit`.

## Order

1. Partition the diff into atomic commit scopes by feature module or independent bug fix. Move or
   exclude unrelated worktree changes before staging; do not use one commit to bundle them.
2. Summarize changes vs **confirmed plan only** for the current commit scope.
3. Report validation results (tests run, manual checks, logs) for the current commit scope.
4. Read **`git-commit-convention`** and automatically generate the Chinese commit title and full
   body for the current scope. The generated message must use `feat`, `fix`, or `bug`, include the
   required Chinese sections, and state the single-commit boundary.
5. **Feature path only:** run post-implementation **`bugkb`** (per `feature-workflow`) — then fill **`Post-implementation bugkb`** in the summary below.
6. If `zentao-bug-gate` was active → complete ZenTao resolve first.
7. Output the commit summary template (all required fields), including the generated commit message, single module/bug scope, and explicitly excluded worktree changes.
8. Ask user: **create commit now?** for this commit scope only.
9. Only if user confirms → ensure `scripts/dev-flow-session.sh` exists; if missing, bootstrap the dev-flow mechanical gate first. Then run `bash scripts/dev-flow-session.sh approve-commit` → inspect the scoped diff → commit with the generated or user-adjusted message.
10. If user declines → leave changes uncommitted. Each additional commit scope requires its own generated message, summary, validation report, and confirmation.

## Commit summary template

Output before asking to commit:

```text
Type: feature | bug
Commit module / bug scope:
Generated commit message:
Changes vs confirmed plan:
Validation run:
Excluded worktree changes:
Post-implementation bugkb: (feature — required; bug — n/a unless re-run)
ZenTao resolve: (if active)
Ready to commit: ask user
```

### `Post-implementation bugkb` (feature path)

Required when dev-flow type was **feature**. Must include:

- modules/areas searched
- at least one concrete outcome: similar case id/title, pitfall noted, or explicit “searched, no similar cases” with query/scope

Placeholders (`n/a`, `skipped`, `待查`, `TBD`) → **hard stop**; run bugkb first.

For **bug** path: use `n/a (pre-implementation bugkb already in confirm-gate)` unless you re-ran bugkb after code changes.

## Hard rules

1. Never commit without user confirmation.
2. One commit must contain one feature module or one independent bug fix only.
3. Never combine unrelated features, multiple independent fixes, refactors, or formatting-only changes in one commit.
4. Split mixed worktree changes before staging and validate each commit scope independently.
5. Ask for confirmation separately for each commit scope; one confirmation must not authorize unrelated commits.
6. Automatically generate a Chinese commit title and body after each atomic scope is validated and before asking for commit confirmation.
7. Never skip `git-commit-convention` when generating or using a dev-flow commit message.
8. Message generation never counts as user confirmation and never performs `git commit`.
9. Never commit when validation required by an active skill is missing or failed.
10. When dev-flow marks `figma_ui`, `review`, or `runtime` as required, each must be recorded in the
    current session before `approve-commit`; the required statuses are G0-G12 all `pass`, review
    `pass`, and runtime `runtime-verified` respectively.
11. **Feature:** never reach step 7 without **`Post-implementation bugkb`** filled — same bar as confirm-gate `bugkb findings` (concrete, not placeholder).
