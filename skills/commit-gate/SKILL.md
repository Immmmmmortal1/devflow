---
name: commit-gate
description: Block git commit until implementation is summarized, required validation is reported, and the user explicitly confirms. Check same-branch child worktrees first; commit the child, merge into that family's main worktree only, then sync siblings. Then use git-commit-convention to create the commit message and commit.
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

1. **Same-branch worktree family check (mandatory, first).** Run `git worktree list --porcelain`
   and resolve the current branch family before any staging or commit. If siblings exist, the
   commit must follow the child → main → sync sequence in **Same-branch worktree family**. Never
   treat `master` / `main` / another family as the main worktree of the current family.
2. Partition the diff into atomic commit scopes by feature module or independent bug fix. Move or
   exclude unrelated worktree changes before staging; do not use one commit to bundle them.
3. Summarize changes vs **confirmed plan only** for the current commit scope.
4. Report validation results (tests run, manual checks, logs) for the current commit scope.
5. Read **`git-commit-convention`** and automatically generate the Chinese commit title and full
   body for the current scope. The generated message must use `feat`, `fix`, or `bug`, include the
   required Chinese sections, and state the single-commit boundary.
6. **Feature path only:** run post-implementation **`bugkb`** (per `feature-workflow`) — then fill **`Post-implementation bugkb`** in the summary below.
7. If `zentao-bug-gate` was active → complete ZenTao resolve first.
8. Output the commit summary template (all required fields), including the generated commit message, single module/bug scope, excluded worktree changes, and the same-branch worktree plan.
9. Ask user: **create commit now?** for this commit scope only.
10. Only if user confirms → ensure `scripts/dev-flow-session.sh` exists; if missing, bootstrap the
    dev-flow mechanical gate first. Then run `bash scripts/dev-flow-session.sh approve-commit` →
    inspect the scoped diff → **commit in the child worktree first** (or on main if there is no
    child) with the generated or user-adjusted message → **fast-forward / merge into that family's
    main worktree only** → **sync every sibling worktree in the same family** to that commit →
    **release DebugBridge for this session** (see **Post-commit session release** below) →
    `bash scripts/dev-flow-session.sh end`.
11. If user declines → leave changes uncommitted. Each additional commit scope requires its own generated message, summary, validation report, and confirmation.

## Commit summary template

Output before asking to commit:

```text
Type: feature | bug
Commit module / bug scope:
Generated commit message:
Changes vs confirmed plan:
Validation run:
Excluded worktree changes:
Same-branch worktrees: none | main=<path> [<branch>]; children=<path> [<branch>], ...
Worktree sync plan: n/a | commit child → ff/merge family main → sync siblings
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

## Post-commit session release

After a successful commit for the current dev-flow scope, treat the task as **complete** for this
session:

1. Call **`ui_dbugbridge_mcp.release_session`** with:
   - `reason`: `dev-flow commit complete`
   - `exitAfterRelease`: `true` (default)
2. Run `bash scripts/dev-flow-session.sh end` in the app repo.
3. Do **not** call DebugBridge business tools again in this chat after release.

`release_session` stops this MCP instance's `iproxy` forwards and exits the server process so the
next task starts clean. It does **not** kill other hosts' orphaned MCP/iproxy processes; run
`bash <devflow-root>/scripts/debugbridge-cleanup.sh` if old instances remain.

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
10. When dev-flow marks `figma_ui`, `review`, `runtime`, or `ui_parity` as required, each must be
    recorded in the current session before `approve-commit`; the required statuses are G0-G12 all
    `pass`, review `pass`, runtime `runtime-verified`, and ui_parity `accepted` with matching
    authorization/acceptance reports respectively.
11. **Feature:** never reach step 8 without **`Post-implementation bugkb`** filled — same bar as confirm-gate `bugkb findings` (concrete, not placeholder).
12. Before every commit, detect same-branch sibling worktrees. If any exist, commit the child
    first, merge only into that family's main worktree, then sync siblings. Never merge a
    `{family}_N` commit into `master`, `main`, `appstore/*`, or any other family.
13. The primary clone path is not automatically the family main. Example: work in
    `1.2.0_dev_2` merges to `1.2.0_dev`, never to `master`.
14. Sibling sync is fast-forward only. Preserve each sibling's unrelated local WIP (stash → ff →
    stash pop). Never `reset --hard` sibling WIP. If `{family}` cannot fast-forward, stop and ask.
15. After a successful commit, always run **Post-commit session release** before starting unrelated
    work in the same chat.

## Same-branch worktree family

Applies to **every** commit, including non-dev-flow commits that still use this skill.

### Detect family

1. Current branch: `git rev-parse --abbrev-ref HEAD`.
2. Family base: if the branch matches `^(.+)_([0-9]+)$`, family is capture 1; otherwise family is
   the branch itself.
   - `1.2.0_dev_2` → family `1.2.0_dev`
   - `1.2.0_dev_1` → family `1.2.0_dev`
   - `1.2.0_dev` → family `1.2.0_dev`
   - `master` → family `master`
3. List worktrees: `git worktree list --porcelain`.
4. Siblings: any worktree whose checked-out branch is exactly `{family}` or `{family}_<digits>`.
5. If there are no siblings, this section is `n/a`; continue with a normal single-worktree commit.

### Identify 主 worktree vs 子 worktree

- **主 worktree / family main:** the worktree whose branch is exactly `{family}` (no `_N` suffix).
- **子 worktree / child:** any worktree on `{family}_<digits>` (`1.2.0_dev_1`, `1.2.0_dev_2`, …).
- If `{family}` is not checked out in any worktree, **do not** substitute `master` / `main` or
  another family. The merge target is still the `{family}` ref: fast-forward it with
  `git fetch . HEAD:{family}` (ff-only) after the child commit, then fast-forward every
  `{family}_N` worktree. If `{family}` cannot fast-forward, stop and ask; do not pick a different
  branch.

### Commit then sync sequence

When siblings exist, after the user confirms the commit:

1. **Commit the child first.** If the current worktree is a child, commit there. If the current
   worktree is already main and a child has uncommitted work for this same scope, commit that
   child first; do not leave the new work only on main while children stay dirty.
2. **Merge into family main only.** Fast-forward `{family}` to the child commit. Use ff-only.
   Never merge into `master`, `main`, `appstore/*`, or any branch outside `{family}`.
3. **Sync 主 and 子 worktrees.** Fast-forward every sibling `{family}_N` (and the main worktree,
   if checked out) to the same commit. If a sibling has local WIP, stash (including untracked if
   needed), fast-forward, then restore the stash. Report the resulting HEADs.

Do not sync or reset worktrees that belong to a different family.
