---
name: code-grounded
description: Require user scope lock and code/runtime evidence before claims, plans, or edits. Read when dev-flow is active, before analysis output, or when the user forbids guessing. Stop if Evidence read is empty but the agent would propose concrete code changes.
---

# Code Grounded

## Purpose

Ground every dev-flow step in **user instruction + evidence**. Do not guess, expand scope, or treat SDK/README defaults as facts.

## Evidence before claims

| Claim | Required evidence |
|-------|-------------------|
| How code works today | `Read` / `grep` path + line range |
| Root cause | investigation + code path |
| What to change | maps to user request + read code/API |
| Payload/API shape | copied from reference, doc, or capture — not memory |

If evidence is missing, output only:

- what is unknown
- the next concrete read/search/command

Do not output speculative root causes or field lists as fact.

## Scope lock

**In scope** (plan may include only):

- user explicit request
- defect required to complete that request safely
- regression directly caused by the requested change

**Out of scope without user approval:**

- refactors while here
- extra fields, APIs, tests, docs, abstractions
- switching integration approach unless analysis proves current path violates stated contract

## Classification output (required at dev-flow start)

```text
User asked for:
Type: feature | bug
In scope:
Out of scope:
Evidence read: [paths opened this session]
```

Hard stop if `Evidence read` is empty but the plan proposes concrete code changes.

## Hard rules

1. No repo/runtime claims without reading or running the agreed check.
2. No scope beyond user request unless approved in plan.
3. When blocked, state only unknowns + next read/command.
