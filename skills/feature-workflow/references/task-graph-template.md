# Task Graph Template

Read this reference when `feature-workflow` Step 4 activates and the task meets
the Task Graph trigger conditions. It defines slice, dependency, frontier, fog,
and claim — the coordination artifact for complex multi-slice tasks.

## Purpose

A flat execution plan cannot express dependencies between independently
verifiable work units or track which slices are ready to claim vs. blocked by
unknowns. The Task Graph is a **planning and coordination artifact only**. It
does not implement an executor, does not auto-create PRs, does not merge, and
does not commit. All submission still goes through `commit-gate`.

## Trigger conditions

A Task Graph is required when **either** condition is true:

1. The task has **two or more** independently verifiable vertical slices.
2. There is a **real dependency** between work units, or genuine **fog**
   (unknowns that block planning).

If neither condition is true, use the flat execution plan — do not create a Task
Graph.

## Definitions

| Term | Definition |
|------|------------|
| **slice** | A vertical slice that can be independently verified (has its own validation path). |
| **deps** | Other slices that must be completed and verified before this slice can be claimed. |
| **frontier** | The set of slices whose deps are all satisfied and whose fog is resolved. Only frontier slices can be **claimed**. |
| **fog** | An unknown that blocks planning or claiming (unresolved API, unclear requirement, unconfirmed design). Fog must be explicitly tracked; it does not silently block. |
| **claim** | A slice is claimed when the agent begins implementing it. Only frontier slices may be claimed. |

## Template

```text
Task Graph:
Slices:
  - id: S1
    description:
    validation:
    deps: [] | [S1, ...]
    fog: [] | [unknown description + resolution path]
    status: unclaimed | claimed | verified | blocked
  - id: S2
    description:
    validation:
    deps: [S1]
    fog: []
    status: unclaimed
Frontier: [S1]  # slices with deps satisfied and fog resolved
Claimed: []
Verified: []
Blocked fog: []  # fog items not yet resolved
```

## Rules

1. **Only frontier slices can be claimed.** A slice with open deps or unresolved
   fog cannot be claimed.
2. **Fog must be explicit.** Every unknown that blocks planning must appear in
   the graph as a fog item with a resolution path (investigate, ask user, wait
   for dependency).
3. **Verification is per-slice.** Each slice has its own validation path. A
   slice is `verified` only when its validation passes.
4. **No auto-execution.** The graph coordinates; it does not spawn agents, create
   PRs, merge branches, or commit. `commit-gate` remains the only commit entry
   point.
5. **Scope lock still applies.** Slices must map to the user's confirmed scope.
   No slice may expand scope without a new human confirmation.

## Relationship to confirm-gate

When a Task Graph is enabled, `confirm-gate` requires:

- a **graph summary** (slice count, dependency structure, fog items) in the plan;
- **frontier closure**: all frontier slices' open decisions are answered.

If the frontier is not closed, the plan is not ready for confirmation.

## Relationship to commit-gate

`commit-gate` does not consume the Task Graph directly. Each commit is still
atomic (one feature module or one independent bug fix). The graph is a
coordination tool; the commit scope and validation are governed by `commit-gate`
as usual.

## When to read this reference

Read after `feature-workflow` Step 3 (requirements-closure) and before Step 5
(confirm-gate), when the trigger conditions are met. Use it to structure the
execution plan into verifiable slices with explicit dependencies and fog.
