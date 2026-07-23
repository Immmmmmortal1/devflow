---
name: feature-workflow
description: Plan-first path for small feature work in dev-flow. Use gstack-review for impact analysis, produce an execution plan, then bugkb after implementation for regression hints. Do not edit code during this phase.
---

# Feature Workflow

## When

User request is **feature development**: add, change, extend, optimize, redesign, or refactor a capability.

Not for explain-only or pure review.

## Order

1. Read `code-grounded` and fill classification + evidence.
2. **`gstack-review`** — requirement, affected files, impact, regression risk, missing validation.
3. **Execution plan** — concrete files, change areas, validation path, risks.
4. Read **`confirm-gate`** → stop for user confirmation.
5. After user confirms → implement confirmed scope only.
6. **`bugkb`** — historical pitfalls for touched module/area.
7. Read **`commit-gate`** — must fill **`Post-implementation bugkb`** in commit summary (hard stop if empty/placeholder).

## Plan must include

- Files likely to change
- Why each change serves the user request
- Validation path (test, manual repro, log check)
- Sub-gates if reference parity applies

## Hard rules

1. Do not edit code during steps 1–4.
2. Do not skip `gstack-review`.
3. Do not skip post-implementation `bugkb` before commit gate.
