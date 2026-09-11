# Facts, Decisions, and Decision Frontier

Read this reference when `confirm-gate` activates. It defines the separation of
investigable Facts from human-judgment Decisions, and the dependency frontier
that must be closed before the user can confirm the plan.

## Purpose

A confirm-gate output that mixes facts and decisions forces the user to
re-derive facts the agent already investigated, and hides real trade-offs among
noise. Separating them makes the confirmation actionable: the user only decides
what cannot be determined from evidence.

## Facts (Agent-investigated)

Facts are statements the agent established by reading code, running tests,
inspecting runtime, or consulting authoritative artifacts. Each fact must cite
its evidence source.

```text
Facts:
  - fact statement | evidence: path/line, test result, runtime node, log marker, artifact
  - fact statement | evidence: ...
```

If a fact cannot be evidenced, it is not a fact — move it to Decisions or mark the
plan as not ready for confirmation.

### What counts as evidence

| Claim | Evidence required |
|-------|-------------------|
| How code works today | `Read` / `grep` path + line range |
| Root cause | investigation + code path + red-capable repro |
| What to change | maps to user request + read code/API |
| API / payload shape | copied from reference, doc, or capture |
| Runtime behavior | DebugBridge UI tree / log marker (current session) |

## Decisions (Human trade-offs)

Decisions are choices that cannot be resolved by evidence alone — they involve
scope, priority, risk tolerance, or business direction. Only keep decisions that
genuinely require the user's input; do not list facts rephrased as questions.

```text
Decisions:
  - decision: statement | options: A / B / ... | recommendation: ... | reason: ...
```

Each decision must state:
- the concrete choice;
- the available options;
- a recommendation with rationale;
- the consequence of not deciding.

## Decision frontier

The **decision frontier** is the set of decisions whose dependencies are all
closed (answered or not-needed). A decision is **blocked** if it depends on
another open decision. The user can only meaningfully confirm decisions on the
frontier — blocked decisions cannot be resolved yet.

```text
Decision frontier:
  - decision A → ready (no deps)
  - decision B → blocked by A
Frontier closure: all frontier decisions have a recorded answer (chosen option)
```

**Frontier not closed** = the plan is not ready for confirmation. Hard stop.

## Relationship to requirements-closure

When `requirements-closure` is active, its **Open decisions** field is the
authoritative list of unresolved trade-offs. This reference points to that list
but does not copy it:

```text
Open decisions (from requirements-closure):
  - see: .dev-flow/requirements/<artifact>.md § Open decisions
  - frontier status: closed | partially-open | blocked
```

If requirements-closure open decisions exist but are not closed, the
confirm-gate frontier is not closed. Do not confirm.

## When to read this reference

Read immediately after the analysis step (feature-workflow or bug-workflow)
produces its plan, and before outputting the confirm-gate template. Use it to
structure the template's Facts and Decisions sections.
