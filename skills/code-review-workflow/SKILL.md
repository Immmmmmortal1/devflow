---
name: code-review-workflow
description: Use when a review route needs an independent Review MCP or gstack-review call after source changes, including review-session health, bounded context, fallback, or result handoff.
---

# Code Review Workflow

## Overview

Provide the shared Review MCP transport and handoff capability for review routes. This skill
selects a route, checks the review session, builds the shared packet, invokes Review MCP or its
fallback, and returns a normalized reviewer result. It does not define the acceptance rules for a
specific review type.

## Review routes

Read [routes/index.md](routes/index.md) first, then read the selected route specification and the
shared [review-loop.md](routes/review-loop.md). A route
defines the review question, required evidence, reviewer instructions, and route-specific pass
conditions. Do not put a route's business or parity rules into this base skill.

Current routes:

- [code-quality-review.md](routes/code-quality-review.md) — generic source correctness and regression review.
- [requirements-chain-review.md](routes/requirements-chain-review.md) — approved requirements versus implementation.
- [api-contract-review.md](routes/api-contract-review.md) — API field/business/UI contract review.
- [ui-parity-review.md](routes/ui-parity-review.md) — post-fix Review MCP for authorized `ui-review` repairs.

The shared review loop in [review-loop.md](routes/review-loop.md) handles finding decisions,
validation reruns, and the three-round stop gate for every route. It is a route protocol, not a
domain review criterion.

If no route matches, stop with `review-blocked`; do not silently use a generic route for a
specialized requirement.

## Scope boundary

This base skill owns only:

- route selection and route-to-review handoff;
- Review MCP session health;
- shared review packet construction and size/sensitivity limits;
- `orchestrator_mcp → code_review` invocation;
- bounded timeout and `gstack-review` fallback;
- run id, review path, raw result, and transport/error normalization.

The selected route owns:

- what the reviewer must inspect;
- required evidence and acceptance criteria;
- how findings map to the route's contract;
- route-specific `pass`, `revise`, or `blocked` judgment.

The reviewer never edits the workspace. The main agent remains responsible for applying authorized
fixes and running the route's validation. `commit-gate` remains the commit permission boundary.

## Workflow

### 1. Select and prepare a route

Read the route specification and record:

```text
Review route:
Review goal:
Required evidence:
Route-specific instructions:
Acceptance criteria:
```

The route may require an approved artifact, API mapping, Figma binding table, runtime evidence,
or another concrete input. Missing required evidence is `review-blocked` before MCP invocation.

### 2. Build the shared packet

Use [review-packet-template.md](references/review-packet-template.md). The packet must include:

- `task_summary`;
- `changed_files`;
- `diff` with curated, inline relevant hunks;
- the selected route and its review goal;
- evidence paths and validation results;
- route-specific requirements and known risks.

Do not pass a full raw diff, full build log, unbounded artifact, credentials, tokens, cookies,
signatures, user/device identifiers, or raw sensitive payloads. Put large artifact paths only in
`validation` or `known_risks`; a path alone is not review context. Split a large change into
coherent route packets and retain an integration summary for cross-area behavior.

### 3. Check Review MCP health

Run a non-model health/config check first when available, preferring
`orchestrate_effective_config`. For the current stdio session require:

- `transport=stdio`;
- `registered=true`;
- reported PID alive;
- a session usable for the current task.

If the MCP reports `CODEX_THREAD_ID`, verify the exact current-thread record. A registered and
alive process-scoped `codex-mcp-*` id is valid even when it differs from `CODEX_THREAD_ID`. Never
kill, clean up, or classify another task's MCP process as stale.

Treat WebUI separately. Its process count or port does not establish stdio MCP health.

If health fails or times out, record the current-session failure and skip model invocation through
that session.

### 4. Invoke the reviewer

Preferred path:

```text
orchestrator_mcp → code_review
```

Use the installed orchestration sequence, normally:

```text
orchestrate_run_start → orchestrate_dispatch → orchestrate_handoff/status
```

Pass the shared packet plus the selected route's `requirements`, `verification`, `known_risks`,
and `custom_instructions`. The reviewer must receive actual reviewable diff/code and must not
infer scope from chat history.

### 5. Handle timeout and fallback

If Review MCP is unavailable, unhealthy, or exceeds the bounded tool timeout:

1. Record the failed phase and reason.
2. Mark the Review MCP result as `unknown`; timeout is never `pass`.
3. Use `gstack-review` as the fallback when it can provide an independent review. Read
   `~/.claude/skills/gstack/review/SKILL.md` (or `GSTACK_REVIEW_SKILL_ROOT/SKILL.md`) and run the
   `/review` workflow against the current diff.
4. Mark the result source as `fallback`; do not label it as an MCP result.

If both paths fail, return `review-blocked`. Local tests, self-review, or build results may be
included as supplemental validation but cannot be relabeled as an independent reviewer result.

### 6. Return a normalized handoff

The base returns the transport/result envelope to the selected route:

```text
Review route:
Review path: mcp | fallback
MCP health: passed | failed | not-run
Run id: <id or unavailable>
Reviewer result: available | unknown | failed
Raw findings: <normalized list or none>
Transport blocker: <none or exact reason>
```

The base must not return route-specific `review-passed` merely because MCP responded. The selected
route evaluates the findings against its own criteria and returns the final route status.

When invoked inside a dev-flow session, record the selected route's final result with
`bash scripts/dev-flow-session.sh record-gate --name review --report <path>`. A reviewer response
that is not recorded in the current session does not satisfy the commit gate.

## Common transport mistakes

- **Many MCP processes means unhealthy:** inspect the current session's transport, registration,
  and live PID; process count alone proves nothing.
- **WebUI is running, so MCP is healthy:** WebUI and stdio MCP health are separate.
- **Timeout means pass:** timeout means unknown and requires fallback or blocking.
- **Full diff/logs are a packet:** curate the packet and split by review area.
- **A route is implied by the task:** select and record the route explicitly.
- **MCP response is final acceptance:** hand it to the route; route criteria decide acceptance.
