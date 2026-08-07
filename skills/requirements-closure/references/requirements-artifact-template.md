# Requirements Artifact Template

Use one file per stable behavior. Replace every placeholder; do not leave behavior-changing
unknowns implicit.

```yaml
---
logic_id: stable.unique.id
status: pending-human-approval
title: Human readable title
aliases: []
api_fields: []
figma_nodes: []
code_areas: []
forbidden: []
updated_at: "YYYY-MM-DD"
---
```

## User fragments

Preserve the relevant user wording as short source-of-truth snippets.

## Evidence

| source | location/id | authority | fact established |
|---|---|---|---|
| code/API/Figma/ticket/log | path or identifier | authoritative/supporting/unresolved | concrete fact |

## Scope

- In scope:
- Out of scope:
- Open decisions:

## Closed state chain

For each state, use this form:

```text
State:
Precondition:
Authoritative source:
Display/data:
Allowed action:
Transition/result:
Loading/empty/error/retry behavior:
Next owner:
```

## State matrix

| State | Entry/precondition | Authoritative data | UI/interaction | Fallback | Validation |
|---|---|---|---|---|---|
| state | condition | fields/source | expected behavior | approved fallback | golden case/test |

## Invariants / forbidden states

-

## Golden cases

```text
Case:
Input payload/state:
Expected business state:
Expected UI:
Expected interaction:
Expected result:
Validation evidence:
```

## Approval

```text
需求分析状态:
整体逻辑链路:
禁止出现的状态/兜底:
Golden cases:
Open decisions:
Approved artifact:
Human approval:
```
