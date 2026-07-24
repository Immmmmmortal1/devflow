---
name: zentao-bug-gate
description: ZenTao boundaries for dev-flow bug fixes. Require concrete bug id in plan and commit steps, user confirmation before commit, and resolve in ZenTao before creating the commit. Skip when user explicitly says ZenTao id is not required.
---

# ZenTao Bug Gate

## When to activate

- Bug fix under dev-flow **and** ZenTao tracking is required
- User or project rules require bug id for fix commits

**Skip** when user explicitly says bug id is not required for this task.

## Before implementation

- Identify exact ZenTao bug id early
- Keep id in plan, confirm-gate output, and progress summaries
- If id is missing or ambiguous → **stop** before coding

## Before commit

1. Restate exact bug id in commit-readiness summary
2. User confirms the id
3. Mark bug **resolved** in ZenTao (use `zentao` skill)
4. Only then proceed to `commit-gate` + `git-commit-convention`

## Hard rules

1. No bug-fix commit without confirmed bug id when this gate is active.
2. No commit if ZenTao resolve fails — stop and ask user.
3. Do not guess bug id mapping.
