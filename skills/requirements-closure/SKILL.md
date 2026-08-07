---
name: requirements-closure
description: Use when a feature, bug fix, UI change, or API-driven behavior has stateful behavior and implementation cannot safely begin until surrounding states, evidence, fallbacks, invariants, and human decisions are explicit.
---

# Requirements Closure

## Overview

Turn a partial request into an evidence-backed behavior contract before source edits. Close the
full state chain, data/UI ownership, fallback behavior, forbidden states, and golden validation
cases; do not fill unknowns with plausible defaults.

## Activation boundary

Activate for work involving any of the following:

- user actions, state transitions, permissions, rewards, entitlement, countdowns, status, or red dots;
- API fields or server-driven UI that control business behavior;
- loading, empty, error, retry, offline, or missing-data behavior;
- copy that changes by business state; route locale coverage and translation completeness to `localization-workflow`.

For a static copy explanation, a read-only field listing, or a non-behavioral refactor, use the
relevant direct skill without creating a requirements artifact.

## Hard rules

1. Treat the user's explicit requirement and authoritative evidence as the source of truth. Code,
   naming conventions, SDK defaults, and field names cannot silently define behavior.
2. Search for an existing approved logic chain before creating a competing one.
3. Every implemented state, fallback, and interaction must appear in the approved chain. An
   unapproved state is a hard stop, not a minor risk.
4. Do not infer missing API semantics, time rules, permissions, copy, or retry behavior. Record the
   unknown as an open decision or blocker.
5. `draft`, `pending-human-approval`, and `blocked` artifacts do not authorize source edits.
   Only `approved` authorizes the next confirmation gate.

## Workflow

### 1. Find or create the chain

Use the current repository's `.dev-flow/requirements/` when a dev-flow session exists:

```text
.dev-flow/requirements/index.json
.dev-flow/requirements/<logic-id-or-slug>.md
```

Search `index.json` and the referenced Markdown files with `rg` before creating a new chain. If a
repository provides a requirements search helper, use it first. Do not skip lookup because the
request sounds small.

Classify the result:

- `MATCH_APPROVED`: load and reuse the approved chain.
- `MATCH_NOT_APPROVED`: report the matching artifact and stop for approval or revision.
- `AMBIGUOUS_MATCH`: stop and ask which chain is in scope.
- `NO_MATCH`: create one `pending-human-approval` artifact.

Keep one stable `logic_id` per behavior. Update or supersede an existing chain instead of creating
two competing approved definitions.

### 2. Gather evidence and lock scope

Record concrete evidence paths or identifiers from the user request, source code, API contract,
Figma nodes, tickets, logs, screenshots, mocks, or reference implementations. Mark each item as
authoritative, supporting, or unresolved. Use `api-contract` when endpoint or field behavior is
involved; this skill consumes its mapping but does not replace its contract extraction.

Separate:

- in-scope states and transitions;
- explicitly out-of-scope states;
- unresolved decisions that affect behavior;
- assumptions that are forbidden until confirmed.

### 3. Close the state chain

For every state, record:

```text
precondition → source of truth → displayed UI/data → allowed action
→ transition/result → loading/error/empty fallback → next owner
```

Include surrounding states, not only the state named by the user. Stateful flows normally need
initial/loading, actionable, submitting, success/completed, failure/retry, empty/missing, and
permission or entitlement variants when applicable. Include boundary values such as first/last
day, zero/max count, expired/used, or duplicate action when the domain supports them.

Then produce a matrix with at least:

```text
state | entry/precondition | authoritative data | UI/interaction | fallback | validation
```

### 4. Define invariants and golden cases

List behavior that must never occur, such as showing an actionable button when server state is
unknown, treating a count as a status without contract evidence, or silently falling back to a
different account/locale/state.

For each golden case, provide concrete input state or payload and expected business state, UI,
interaction, and result. Cover the happy path plus boundary, duplicate-action, missing-data, and
failure/retry cases that the closed chain allows.

### 5. Handle conditional contracts

For API-driven behavior, require every consumed field to map to a business state and UI/interaction
owner. List intentionally unused fields with a reason. Do not invent endpoint names or meanings.

For localized copy, record the state-to-copy key or text dependency needed by the behavior contract,
then activate `localization-workflow` for locale enumeration, target values, exceptions, and validation.
Do not duplicate its translation rules here.

### 6. Resolve decisions and approve

Write every behavior-changing unknown under `Open decisions`. Ask the user only for decisions that
cannot be established from evidence. Do not hide an unresolved decision inside a default.

When the chain is complete, set `status: pending-human-approval` and present:

```text
需求分析状态: pending-human-approval
整体逻辑链路: ...
禁止出现的状态/兜底: ...
Golden cases: ...
Open decisions: ...
Approved artifact: <path>
```

After explicit approval, update the same artifact to `status: approved`, sync its `logic_id` and
routing keys into `index.json`, and pass the artifact to `confirm-gate`. When source changes are
later reviewed, select the `requirements-chain-review` route from `code-review-workflow` and hand
it this approved artifact; do not embed Review MCP health or packet construction here. If evidence
is missing or contradictory, use `blocked` and name the exact next read or decision.

## Artifact contract

Use the structure in [requirements-artifact-template.md](references/requirements-artifact-template.md).
The YAML metadata must include:

```yaml
logic_id: stable.unique.id
status: draft|pending-human-approval|approved|blocked
title: Human readable title
aliases: []
api_fields: []
figma_nodes: []
code_areas: []
forbidden: []
updated_at: "YYYY-MM-DD"
```

Store workflow artifacts under `.dev-flow/requirements/`. Do not include them in product commits
unless the user explicitly asks. Preserve user fragments and raw evidence references; derived
tables may be updated when the approved behavior changes.

## Relationship to other skills

| Skill | Boundary |
|---|---|
| `feature-workflow` / `bug-workflow` | Analyze impact or root cause and produce the implementation plan. |
| `api-contract` | Extract endpoint/field contracts and validate field mappings. |
| `localization-workflow` | Enumerate locales, manage target copy and explicit same-string exceptions, and validate every locale. |
| `confirm-gate` | Enforce user confirmation after this chain is complete. |
| `figma-ui-gates` / `ui-review` | Implement or review UI after the applicable contract and gates. |

This skill owns behavior closure; it does not implement code, decide visual parity, or approve a
commit.

## Common failure modes

- **Only the happy path is written:** add loading, empty, failure, retry, duplicate, and boundary states.
- **A field name becomes business truth:** require contract evidence and an explicit mapping.
- **A copy key is treated as a full localization contract:** delegate locale completeness and translation decisions to `localization-workflow`.
- **A plausible fallback is added to unblock coding:** record it as an open decision; do not implement it.
- **A second artifact is created for the same behavior:** reuse the stable `logic_id` and update the existing chain.
