---
name: code-review-workflow
description: Use when a review route needs an independent 审查角色（@openai-reviewer）or gstack-review call after source changes, including review-session health, bounded context, fallback, or result handoff.
---

# Code Review Workflow

## Overview

Provide the shared Review transport and handoff capability for review routes. This skill selects
a route, checks the review session, builds the shared packet, invokes the selected adapter
（审查角色 @openai-reviewer, orchestrator-mcp, or gstack-review fallback), and returns a
normalized reviewer result. It does not define the acceptance rules for a specific review type.

## Review routes

Read [routes/index.md](routes/index.md) first, then read the selected route specification and the
shared [review-loop.md](routes/review-loop.md). A route
defines the review question, required evidence, reviewer instructions, and route-specific pass
conditions. Do not put a route's business or parity rules into this base skill.

Current routes:

- [code-quality-review.md](routes/code-quality-review.md) — generic source correctness and regression review.
- [requirements-chain-review.md](routes/requirements-chain-review.md) — approved requirements versus implementation.
- [api-contract-review.md](routes/api-contract-review.md) — API field/business/UI contract review.
- [ui-parity-review.md](routes/ui-parity-review.md) — post-fix 审查角色 review for authorized `ui-review` repairs.

The shared review loop in [review-loop.md](routes/review-loop.md) handles finding decisions,
validation reruns, and the three-round stop gate for every route. It is a route protocol, not a
domain review criterion.

If no route matches, stop with `review-blocked`; do not silently use a generic route for a
specialized requirement.

## Scope boundary

This base skill owns only:

- route selection and route-to-review handoff;
- 审查角色（@openai-reviewer）session health;
- shared review packet construction and size/sensitivity limits;
- adapter invocation (resolver-selected: 审查角色, orchestrator-mcp, or gstack-review);
- pre-dispatch fallback selection and post-dispatch fail-closed enforcement;
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
or another concrete input. Missing required evidence is `review-blocked` before adapter invocation.

### 1a. Spec / Standards dual-axis (mandatory)

Every review output is structured along two axes. Neither axis may be omitted, and one axis
must not mask the other.

| Axis | Checks | Sources of truth |
|------|--------|------------------|
| **Spec** | Does the change meet the user request, confirmed scope, requirements artifact, API contract, or UI parity contract? | user request, confirmed scope, `.dev-flow/requirements/` artifact, API contract, Figma bindings |
| **Standards** | Is the code correct, secure, maintainable, well-tested, and free of regressions? | code quality, security, error handling, test coverage, maintainability |

Overall result derivation (applied **after** both axes produce their independent verdict):

```text
Spec=pass     + Standards=pass     → overall pass
Spec=revise   + Standards=pass      → overall revise
Spec=pass     + Standards=revise   → overall revise
Spec=blocked  + Standards=pass      → overall blocked
Spec=pass     + Standards=blocked  → overall blocked
Spec=revise   + Standards=revise   → overall revise
Spec=blocked  + Standards=blocked  → overall blocked
```

In short: **any `blocked` → overall `blocked`; any `revise` → overall `revise`; only
both `pass` → overall `pass`**.

The machine fields (`reviewer_result`, `selected_adapter`, `config_digest`, `ticket_token`,
`ticket_digest`, `result_artifact`, `adapter_result_ref`, `adapter_result_digest`, `run_id`,
`diff_evidence`) and the unified status `pass|revise|blocked` are unchanged. The dual-axis is a
reporting and judgment contract — it does not change the session schema.

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

### 3. Check 审查角色 health

Run `scripts/review-health-probe.sh` first (or read its recorded result from
environment-health-check). The 审查角色（@openai-reviewer）is available when **both** hold:

- `~/.config/opencode/opencode.json`（可用 `DEV_FLOW_OPENCODE_CONFIG` 或 `OPENCODE_CONFIG`
  覆盖路径）中存在 agent `"openai-reviewer"`（非空 JSON 对象）；
- 该 agent 的 `model`（形如 `<provider>/<model>`）对应的 provider 段配置了 `options.apiKey`
  （可用 `{env:XXX}` 引用格式；不硬查环境变量，key 运行时解析交给 opencode）。

The probe records `transport=reviewer` when available; otherwise it falls back to a `gstackReview`
skill candidate. A registered and alive 审查角色 agent is valid for the current task. Never
conflate another session's reviewer result with the current one; treat WebUI or unrelated MCP
processes as not evidence for this session's 审查角色 availability.

### 4. Invoke the reviewer

Before dispatching any review (agent/mcp/fallback), issue a unified review dispatch ticket:

```bash
bash scripts/dev-flow.sh issue-review-ticket [--route <route>]
```

The ticket writes `review_ticket` to session state (token, digest, adapter, config_digest,
route, worktree_digest) and creates a ticket artifact file. All review reports must carry
`ticket_token` / `ticket_digest` matching the issued ticket. `record-gate` validates ticket
ownership, adapter/config/route/worktree_digest consistency, and unconsumed status; `pass`
atomically marks the ticket consumed. Reusing a consumed ticket is rejected — re-issue
after each `pass`. Fallback sessions have the ticket issued automatically by
`run-review-fallback.sh`.

**Round 3 integrity enhancements:**

- **Worktree digest**: The ticket captures a unified worktree digest using structured content hash
  for tracked files (enumerates changed paths from merge-base, recording base/HEAD/index blob
  id+mode and worktree existence/content sha256, binary-safe) plus all untracked files
  (path+mode+type+content hash; symlinks use target hash, regular files use content sha256,
  untracked symlinks are NOT skipped; excluding `.dev-flow/`). `record-gate` recomputes using the
  frozen merge_base SHA from the ticket (prevents branch drift) and rejects if files changed
  after ticket issue. Non-git projects cannot issue a ticket (worktree_digest.py requires
  git + resolvable base ref); record-gate fails closed on recompute failure.
- **Overwrite protection**: An unconsumed/uncancelled ticket blocks re-issuance. Cancel first:
  ```bash
  bash scripts/dev-flow.sh cancel-review-ticket [--reason "text"]
  ```
- **Route whitelist**: Only routes with a corresponding `.md` file in
  `skills/code-review-workflow/routes/` are accepted (excludes `index` and `review-loop`).
- **Result artifact**: All non-readonly review reports must carry `result_artifact` (path within
  `.dev-flow/sessions/`) and `result_artifact_digest`. Use the controlled entry point:
  ```bash
  bash scripts/dev-flow.sh record-review-result   # reads adapter result from stdin
  ```
  record-gate validates: symlink rejection, path boundary (no `../` escape), digest recompute,
  and field matching (producer, session_id, adapter, config_digest, ticket_digest, route,
  worktree_digest, run_id, adapter_result_ref, adapter_result_digest, status, reviewer_result,
  findings). Artifact producer must strictly
  match report producer (producer mismatch rejected; only controlled producer code-review-workflow
  accepted). Artifact reading uses unified `safe_read_json`/`safe_read_bytes` (original path
  lstat, no ValueError pass, no resolve-first component loss).
  `adapter_result_ref` (host task id / orchestrator run id / gstack packet-run ref) and
  `adapter_result_digest` (sha256-prefixed canonicalized handoff text/file digest) record the
  review's host-level provenance. For agent/openai-reviewer, only the host task ref + handoff
  digest is recorded; authenticity is the host orchestration layer's responsibility, not local
  crypto. For orchestrator/gstack, local artifact path/digest is verified if available.

Exception: read-only `ui_review` without `confirmed_at` does not require a ticket (no
source edits).

**Honest wording**: The local integrity gate prevents misuse/drift/replay (missing fields,
config drift, ticket replay, result artifact tampering), not cryptographic
proof against local-write attackers. **Those with local/repo write access are NOT in the
threat model** — a malicious Agent with write access can bypass all local checks.
Independent review authenticity is the host orchestration layer's responsibility.
Non-git projects cannot pass the review gate
(worktree_digest.py requires git + resolvable base ref; recompute failure = fail closed).
Untracked symlinks are included in the digest (not skipped); lstat/readlink failure = fail closed.
gstack probe with explicit skill_path: invalid → blocked, no fallback to default candidates.

Preferred path (selected by the review-backend resolver):

```text
审查角色 @openai-reviewer dispatch
```

If the resolver selected `mcp/orchestrator`, use the installed orchestration sequence, normally:

```text
orchestrate_run_start → orchestrate_dispatch → orchestrate_handoff/status
```

Pass the shared packet plus the selected route's `requirements`, `verification`, `known_risks`,
and `custom_instructions`. The reviewer must receive actual reviewable diff/code and must not
infer scope from chat history.

### 5. Fallback selection and post-dispatch failure handling

Fallback is selected **only pre-dispatch** by the review-backend resolver during
`environment-health-check`. The resolver probes the primary adapter; if the primary is unavailable
and the configured policy allows fallback, the resolver selects `skill/gstack` and locks
`selected_adapter` / `config_digest` into the session's `review_selection`. Once locked, the
adapter is fixed for the entire dispatch — no switching is permitted under any circumstance.

**Pre-dispatch fallback (resolver-selected, locked at environment-health-check time):**

When the session's `review_selection.selected_adapter` is `skill/gstack` (fallback was selected
pre-dispatch), run `bash scripts/run-review-fallback.sh` to perform the review:

1. The runner verifies the session is in gstack-review fallback mode (environment evidence
   `fallback=gstack-review`), then injects the review instructions, the gstack review SKILL.md,
   the selected route contract, and the bounded diff packet into stdout, plus the exact report
   template. Perform the review **yourself** following the injected workflow — do NOT spawn a
   sub-agent or use a host-native review agent; the fallback reviewer is you.
2. Write the report with `review_path: "fallback"` to the path printed by the runner and record
   it with `record-gate --name review`. In fallback sessions record-gate rejects review reports
   that lack `review_path=fallback`.
3. Mark the result source as `fallback`; do not label it as a primary adapter result.

**Post-dispatch failure handling (fail-closed, no switching):**

Once dispatch has begun (the reviewer has been invoked), the following outcomes must be recorded
**as-is** and the review stops — **never switch to a different adapter**:

- `timeout` → record `blocked` with the timeout evidence; timeout is never `pass`.
- `missing` (no result returned) → record `blocked` with the missing-result evidence.
- `error` (adapter crashed or returned invalid output) → record `blocked` with the error evidence.
- `blocked` (reviewer explicitly blocked) → record `blocked` as-is.
- `revise` (reviewer found issues requiring fixes) → record `revise` as-is; the review-loop may
  re-dispatch the **same** adapter after fixes, but never a different adapter.

`record-gate` enforces this mechanically: `review_selection` is locked on the first review report,
and any subsequent report whose `selected_adapter` / `config_digest` does not match the locked
selection is rejected. A report with `review_path: "fallback"` is rejected outright when the locked
adapter is not `skill/gstack` — post-dispatch fallback switching is prohibited regardless of
whether the adapter string matches.

If the primary adapter fails and the session was **not** pre-dispatch fallback, return
`review-blocked`. Local tests, self-review, or build results may be included as supplemental
validation but cannot be relabeled as an independent reviewer result.

**No-result-washing enforcement:** a `blocked`, `timeout`, `missing`, or `error` result must be
recorded as-is; never convert it to `pass`, `revise`, or `unknown→pass`. The review path
(`reviewer`, `mcp`, `fallback`) is fixed at dispatch time and must not be silently switched after
the result returns.

### 6. Return a normalized handoff

The base returns the transport/result envelope to the selected route:

```text
Review route:
Review path: reviewer | mcp | fallback
Adapter health: passed | failed | not-run
Run id: <id or unavailable>
Reviewer result: available | unknown | failed
Raw findings: <normalized list or none>
Transport blocker: <none or exact reason>
Spec verdict: pass | revise | blocked
Standards verdict: pass | revise | blocked
Overall result: pass | revise | blocked
```

The base must not return route-specific `review-passed` merely because MCP responded. The selected
route evaluates the findings against its own criteria and returns the final route status. The
dual-axis verdicts are reported independently so that one axis cannot mask the other; the overall
result follows the derivation rule in Step 1a.

When invoked inside a dev-flow session, record the selected route's final result with
`bash scripts/dev-flow-session.sh record-gate --name review --report <path>`. A reviewer response
that is not recorded in the current session does not satisfy the commit gate.

## Common transport mistakes

- **Many adapter processes means unhealthy:** inspect the current session's transport, registration,
  and live PID; process count alone proves nothing.
- **WebUI is running, so adapter is healthy:** WebUI and adapter health are separate.
- **Timeout means pass:** timeout means `blocked`; record as-is and stop. Post-dispatch fallback
  switching is prohibited — fallback is selected only pre-dispatch by the resolver.
- **Full diff/logs are a packet:** curate the packet and split by review area.
- **A route is implied by the task:** select and record the route explicitly.
- **Adapter response is final acceptance:** hand it to the route; route criteria decide acceptance.
- **No-result-washing:** `blocked` / `timeout` / `missing` / `error` must not be converted to
  `pass`; the review path is fixed at dispatch time. Post-dispatch fallback switching is
  prohibited — a report with `review_path: "fallback"` is rejected when the locked adapter is
  not `skill/gstack`.
- **Single-axis masking:** the Spec and Standards axes are reported independently. A `pass` on
  one axis must not mask a `revise` or `blocked` on the other. The overall result is the
  weakest axis (blocked > revise > pass).
