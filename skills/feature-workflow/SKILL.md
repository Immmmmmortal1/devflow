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
3. **`requirements-closure`** — for stateful or behavior-changing features, close the logic chain
   and persist an approved requirements artifact before coding.
4. **Execution plan** — concrete files, change areas, validation path, risks. When the task has
   **≥2 independently verifiable vertical slices** or **real dependencies/fog** (unknowns that
   block planning), structure the plan as a **Task Graph**: slices, deps, frontier, fog, claim.
   Read [references/task-graph-template.md](references/task-graph-template.md) for the full
   contract. The Task Graph is a **planning/coordination artifact only** — it does not implement
   an executor, does not auto-create PRs, does not merge, and does not commit. All submission
   still goes through `commit-gate`.
5. Read **`confirm-gate`** → stop for user confirmation. When a Task Graph is enabled,
   confirm-gate requires the graph summary (slice count, dependency structure, fog items) and
   frontier closure.
6. After user confirms → implement confirmed scope only. If the feature includes a new or rebuilt
   Figma-driven screen, enter the `figma-ui-gates` sub-route at this point; it is not a separate
   dev-flow entry and must consume the approved requirements chain before G0.
7. **`bugkb`** — historical pitfalls for touched module/area.
8. Read **`commit-gate`** — must fill **`Post-implementation bugkb`** in commit summary (hard stop if empty/placeholder).

## Plan must include

- Files likely to change
- Why each change serves the user request
- Validation path (test, manual repro, log check)
- Active conditional gates and their required validation
- **Task Graph** (when triggered): slice ids, dependency structure, fog items, frontier status

## Hard rules

1. Do not edit code during steps 1–5.
2. Do not skip `gstack-review`.
3. Do not skip post-implementation `bugkb` before commit gate.
4. A new Figma UI is implemented inside the feature path: requirements closure and human
    confirmation come first, then every gate in the `figma-ui-gates` sequence must pass, including
    `preflight` and `G6V`. The order around assets and runtime is `G6` design-side asset declaration
    → `G7` implementation → `G8` build + launch → `G6V` source-literal and runtime-binding
    validation → `G7A` → `G7B`. It includes configurable reviewers, simulator-or-device runtime
    (default simulator), and geometry-only G10 evidence. Its rules, scripts, and tests are
    self-contained, but runtime depends on Figma REST, DebugBridge, XcodeBuildMCP, and the project's
    `build` configuration. Resolve rules through `${FIGMA_UI_GATES_DIR}` as defined by
    `devflow/SKILL.md`; inside the `figma-ui-gates` documentation, `${SKILL_DIR}` is equivalent.
5. When a Task Graph is triggered (≥2 slices or real deps/fog), the plan must include the
   graph summary and frontier closure. Only frontier slices may be claimed; fog must be
   explicit.
6. The Task Graph does not auto-create PRs, merge branches, or commit. `commit-gate` remains
   the only commit entry point.
