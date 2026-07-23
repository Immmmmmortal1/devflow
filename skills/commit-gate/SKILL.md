---
name: commit-gate
description: Block git commit until implementation is summarized, validation is reported, optional reference parity report passes, and the user explicitly confirms. Then use git-commit-convention to create the commit message and commit.
---

# Commit Gate

## Purpose

No commit on agent initiative.

## When

After implementation and validation, before `git commit`.

## Order

1. Summarize changes vs **confirmed plan only**.
2. Report validation results (tests run, manual checks, logs).
3. **Feature path only:** run post-implementation **`bugkb`** (per `feature-workflow`) — then fill **`Post-implementation bugkb`** in the summary below.
4. If `reference-parity` was active → attach parity report; fail → **stop**.
5. If `zentao-bug-gate` was active → complete ZenTao resolve first.
6. Output the commit summary template (all required fields).
7. Ask user: **create commit now?**
8. Only if user confirms → ensure `scripts/dev-flow-session.sh` exists; if missing, bootstrap the dev-flow mechanical gate first. Then run `bash scripts/dev-flow-session.sh approve-commit` → read **`git-commit-convention`** → inspect diff → commit with agreed message.
9. If user declines → leave changes uncommitted.

## Commit summary template

Output before asking to commit:

```text
Type: feature | bug
Changes vs confirmed plan:
Validation run:
Post-implementation bugkb: (feature — required; bug — n/a unless re-run)
Reference parity: (if active)
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
2. Never skip `git-commit-convention` when committing dev-flow work.
3. Never commit when parity report fails or golden validation not run (reference tasks).
4. **Feature:** never reach step 7 without **`Post-implementation bugkb`** filled — same bar as confirm-gate `bugkb findings` (concrete, not placeholder).
