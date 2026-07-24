---
name: dev-flow
description: Use when the user explicitly requests dev-flow for a small feature, bug fix, plan-first investigation, or automated mobile development task.
---

# Dev Flow (Automated Development Loop)

## Purpose

`dev-flow` is an **automated development loop** for small features and bug fixes. Its default outcome is a completed, runtime-verified change rather than a handoff immediately after code is written.

After required human approvals, it should autonomously implement, build, run on the attached device, operate the real UI, read runtime logs, fix issues, and rerun validation until the development loop is closed.

This file defines orchestration order and completion boundaries. Detailed rules live in atomic skills — **read them at each step**.

`dev-flow` must turn partial user requirements into a closed, reviewable interaction / behavior chain before implementation. A user-provided fragment is not enough to code from until the missing surrounding states, transitions, fallbacks, and forbidden states have been made explicit and approved by the human.

### Completion contract

Code written is not completion. The normal closed loop is:

```text
requirements approved → implement → build → run on device → operate UI → read logs
                     ↑                                                     ↓
                     └────────── fix and rerun until verified ──────────────────────────┘
```

Continue automatically while the next action is safe, authorized, and inside the approved scope. Stop only for a genuine human decision or external blocker, such as an unresolved product choice, unavailable device/account, missing authority, or the three-round review stop gate. Do not ask the human to reproduce UI steps that registered runtime tooling can perform.

## When to use

**Use when user explicitly says:**

- `/dev-flow`
- 先分析 / 先方案 / 先排查 / 别直接改代码
- 开发这个功能 / 改一下 / 修 bug / 为什么坏了

**Do not use when:**

- explain-only / pure review
- user already approved immediate coding (“直接改 / 按刚才方案做”)
- agent wants plan mode without user asking

If unsure → ask once.

---

## Atomic skills (read, do not duplicate)

| Skill | Role |
|-------|------|
| `code-grounded` | evidence, scope lock, classification |
| `feature-workflow` | feature analysis path |
| `bug-workflow` | bug analysis path |
| `api-contract` | API field → business → UI/interaction mapping gate (conditional) |
| `reference-parity` | reference contract parity (conditional) |
| `confirm-gate` | block edits until user confirms |
| `commit-gate` | block commit until user confirms |
| `zentao-bug-gate` | ZenTao id + resolve (conditional) |

Supporting skills/tools (invoked by atomic skills or this orchestrator): `orchestrator_mcp` `code_review`, `gstack-review`, `gstack-investigate`, `bugkb`, `git-commit-convention`, `zentao`, and `LookDebugBridge` / `lookdebug-mcp` for iOS runtime UI and Xcode Console inspection.

The eight foundational skills listed above are maintained as the canonical repository bundle under `skills/<skill-name>/SKILL.md`. Keep the corresponding global `~/.codex/skills/<skill-name>/SKILL.md` paths linked to this bundle by running `bash scripts/link-global-skills.sh`; do not maintain a second copied version in the global directory. Bundled resources, such as `reference-parity/examples/purchase-verify-reference-keys.json`, must stay with their skill.

---

## Orchestration

### Step 0 — Enter dev-flow

Read **`code-grounded`**. Output classification + `Evidence read`.

Bootstrap mechanical gate before starting. If `scripts/dev-flow-session.sh` is missing in a project that wants to use dev-flow, **do not bypass the gate**. Create the standard script first, make it executable, and verify `status` works.

A reusable minimum script must support:

- `start --type bug|feature [--task "..."]`
- `confirm-plan [--task "..."]`
- `approve-commit [--task "..."]`
- `end`
- `status`

It must isolate state per Codex task. Resolve the session id from `DEV_FLOW_SESSION_ID`, then `CODEX_THREAD_ID`, otherwise `local`, and write `.dev-flow/sessions/<session-id>.json` with `session_id`, `active`, `type`, `task`, `started_at`, `confirmed_at`, `commit_approved_at`, and `ended_at`. One task must never read, overwrite, confirm, approve, or end another task's state. Keep legacy `.dev-flow/session.json` files untouched and do not auto-migrate them to an arbitrary task.

Only after the script exists, start mechanical session:

```bash
bash scripts/dev-flow-session.sh start --type bug|feature [--task "short label"]
```

Without `start`, hooks do not apply. Without `confirm-plan` after user Proceed, **source edits are blocked**. Without `approve-commit` after user confirms commit, **`git commit` is blocked**. Missing script is a workflow bootstrap task, not permission to continue manually.

When task is fully done or user exits dev-flow:

```bash
bash scripts/dev-flow-session.sh end
```

### Step 1 — Classify

| User intent | Read next |
|-------------|-----------|
| Feature | **`feature-workflow`** |
| Bug | **`bug-workflow`** |
| Bug + feature | **`bug-workflow`** first |

### Step 2 — Conditional sub-gates (evidence only)

| Condition | Read |
|-----------|------|
| Task adds/changes/consumes API endpoints, fields, docs, mocks, server-driven UI, rewards, entitlement, status, red dots, notifications, pricing, or permissions | **`api-contract`** |
| User named reference / port to match existing code | **`reference-parity`** |
| Bug fix + ZenTao required | **`zentao-bug-gate`** |

Never activate sub-gates “just in case.”
For API work, **do activate `api-contract` whenever an endpoint or response field participates in business behavior**.

### Step 3 — Requirements Analysis Complete（需求分析完成）

Before asking the user to proceed with coding, resolve the task to a local requirements logic chain. For any task that changes or depends on interaction state, business state, UI copy, rewards, entitlement, countdowns, coupons, membership, payment, server-driven behavior, or fallback behavior, first search existing local logic artifacts.

Local requirement logic lives under `.dev-flow/requirements/`.

Required files:

- `.dev-flow/requirements/index.json` — deterministic routing index.
- `.dev-flow/requirements/<logic-id-or-slug>.md` — human-readable approved or pending logic chain.

Before creating a new chain, run the repo-local search helper when available:

```bash
bash scripts/dev-flow-requirements.sh search "<user request + relevant file/API/Figma terms>"
```

If the helper is missing, search manually with `rg` over `.dev-flow/requirements/index.json` and `.dev-flow/requirements/*.md`; do not skip lookup.

#### Requirement lookup outcomes

- `MATCH_APPROVED`: load the matched file and reuse it as the authoritative chain.
- `MATCH_NOT_APPROVED`: load the matched file, report that it blocks coding, and ask the human to approve or revise it.
- `AMBIGUOUS_MATCH`: stop and ask the human which logic chain is in scope.
- `NO_MATCH`: create a new `pending-human-approval` chain before coding.

Only `status: approved` chains can be directly reused. `draft`, `pending-human-approval`, and `blocked` chains are discoverable but cannot authorize coding.

Each requirements chain must have machine-readable metadata at the top:

```yaml
---
logic_id: stable.unique.id
status: draft|pending-human-approval|approved|blocked
title: Human readable title
aliases: [...]
api_fields: [...]
figma_nodes: [...]
code_areas: [...]
forbidden: [...]
updated_at: "YYYY-MM-DD"
---
```

The index entry for the same `logic_id` must point to that file and include the same routing keys. A `logic_id` is unique; if the logic changes, update the same chain or explicitly supersede it rather than creating a competing approved chain.

The artifact is a workflow artifact. Store it under `.dev-flow/requirements/` when a repo-local dev-flow session exists, and do not include it in product commits unless the user explicitly asks.

If no approved chain exists, produce a compact but complete requirements closure artifact.

The artifact must contain:

- `User fragments:` the relevant user-provided statements, preserved as source-of-truth snippets.
- `Evidence:` files, Figma nodes, API fields, docs, tickets, logs, screenshots, or reference behavior used.
- `Closed state chain:` every known state in the flow, including preconditions, display, action, transition, and owner of truth.
- `State matrix:` state → required UI/interaction → required data fields → fallback/loading/error behavior.
- `Invariants / forbidden states:` logic that must never appear in code, UI, fallback, tests, or reviewer-accepted behavior.
- `Golden cases:` the minimum cases that prove the chain, including boundary cases and missing/failed data.
- `Open decisions:` anything still unknown. If any open decision affects behavior, stop and ask; do not infer it silently.

The requirements closure must explicitly handle surrounding states, not only the fragment the user mentioned. Example for a coupon/check-in flow: non-member, member unsigned, member signed day 1, member signed day 2, member completed/unlocked, coupon expired, coupon used, plus loading/error/missing-server-state behavior if those can occur. The exact business chain comes from the current user-provided requirement and evidence; this example is a shape, not a hardcoded product rule.

#### Human approval gate

Mark the artifact as one of:

- `draft`
- `pending-human-approval`
- `approved`
- `blocked`

Code edits are blocked until the current artifact is `approved` by the human. After approval, the approved chain is authoritative:

- Do not question or weaken it during implementation.
- Do not replace it with local fallback logic.
- Do not add a state that is absent from the approved chain.
- Do not coerce data into a different state to avoid a completed/expired/error branch.
- If later evidence or user input changes the chain, create/update the artifact and get human approval again before coding that change.

When reporting the plan before coding, include:

```text
需求分析状态: approved|blocked|pending-human-approval
整体逻辑链路: ...
禁止出现的状态/兜底: ...
Golden cases: ...
Approved artifact: ...
```

#### Localization / text replacement gate

Activate this gate whenever a task changes localized copy, string catalogs, per-locale resource files, translation tables, or language-specific entries for the same semantic text.

Before confirmation or implementation:

1. Enumerate every supported locale from the project's actual localization structure; do not limit scope to the locale named in the request or the first matching file.
2. Build a complete matrix of `locale → key/entry → authoritative target value → status` for the semantic text being changed.
3. Treat all supported locales that expose the same semantic text as required scope by default. Each locale must use its correct translated value; never copy one locale's text into other locales as a substitute for translation.
4. If any locale lacks an authoritative target value, mark the requirement `blocked`, list the missing locales, and ask the human for the missing copy. Do not guess, machine-invent, or silently omit translations.
5. Allow a locale-specific change only when the human explicitly approves that exception. The confirmation plan must list every excluded locale and the reason it is excluded.

Implementation and review must verify the complete locale matrix. A partial-locale replacement is `revise` or `blocked`, never a minor accepted risk. Golden validation must assert every required locale/key has the expected value and that explicitly excluded locales have no unintended diff.

### Step 4 — Confirm before code

Read **`confirm-gate`**. Wait for user **proceed**.

When user **Proceed** → immediately run. If the script is missing, stop and bootstrap it first; do not silently continue:

```bash
bash scripts/dev-flow-session.sh confirm-plan [--task "short label"]
```

Only then may source edits begin.

### Step 5 — Implement

Only confirmed scope. Important decision points → short comments (why/guardrail).

Implementation must trace each changed branch back to the approved requirements closure. When a branch has no matching approved state, stop and update/approve the closure first. Do not create “temporary” fallback states that contradict the approved chain.

#### Runtime debug loop

For an attached iOS Debug app, validate the real behavior end to end instead of waiting for the human to reproduce each step:

0. Establish the Xcode/LLDB session before runtime validation. The app must be launched from the Xcode GUI with the target scheme and physical device selected, `Debug executable` enabled, and the Xcode Debug Area Console showing the attached `KakaPic` process. If `read_xcode_console` or `wait_xcode_console` reports `xcode_window_not_found`, no attached LLDB process, or otherwise cannot read the Xcode Console, **block immediately and alert the user**. Do not substitute `idevicesyslog`, `start_device_log_cap`, or any other device/system log stream; those are not LLDB/Xcode Console logs. Resume only after the Xcode/LLDB session is visibly established.

1. Use `get_debug_page` and `tap_element` (or equivalent registered LookDebugBridge actions) to navigate the real UI and trigger the target flow.
2. Use `read_xcode_console` for existing logs or `wait_xcode_console` for new output. Read Xcode's Console on demand; do not persist or duplicate its log stream.
3. If the code path is reached but existing logs cannot answer the current debugging question, add the smallest targeted diagnostic output after `confirm-gate` approval. Logging edits are source edits and never bypass that gate.
4. Diagnostic output must be DEBUG-only (`#if DEBUG` or an equivalent compile-time Debug boundary), searchable by stable markers / request IDs, and include enough state to connect the UI action to the result.
5. Redact credentials, tokens, cookies, signatures, user/device identifiers, and recursively sensitive payload fields. Bound or truncate large payloads. Never add Release logging merely for agent convenience.
6. Rebuild, rerun the UI flow, and query the Console again. Keep reusable safe diagnostics; remove noisy one-off output before handoff.

Do not claim an endpoint, callback, state transition, or UI result was exercised unless the UI action and matching runtime evidence were both observed.

### Step 6 — Code review handoff

After any source edit and before commit-gate, run a code review stage.

Preferred path:

```text
orchestrator_mcp → code_review
```

Before calling `orchestrator_mcp`, do a review-tool health preflight:

- Treat stdio MCP processes as per-session instances. Multiple `python -m orchestrator_mcp` processes are expected when multiple Codex threads are active and are not, by themselves, unhealthy.
- Read the current Codex thread id from `CODEX_THREAD_ID` when it is available. Codex's MCP launcher may not forward that variable into the MCP child; the installed wrapper then uses a `codex-mcp-*` process-scoped session id. Prefer the `mcp_session` object returned by `orchestrate_effective_config`: require `transport=stdio`, `registered=true`, and a live PID. If the MCP-reported session id equals `CODEX_THREAD_ID`, also verify the exact thread record with `python -m orchestrator_mcp.session_runtime --session-id "$CODEX_THREAD_ID"`; do not mark the MCP unhealthy solely because the child session id differs or the exact thread record is absent. Never downgrade review health merely because other thread ids have MCP processes.
- Never kill, clean up, or classify another thread id's MCP process as stale. If the current thread's record is missing or invalid, report only the current thread unhealthy and use the fallback. Process cleanup must be scoped to the same verified thread id.
- Treat WebUI separately from MCP session health. WebUI is a singleton service; its process count or port must not be used to infer whether the current stdio MCP session is healthy.
- Call a non-model health/config endpoint first when available, preferring `orchestrate_effective_config`. For a stdio session, require its `mcp_session.transport` to be `stdio`, its `mcp_session.registered` to be true, and its reported PID to be alive. Require equality with `CODEX_THREAD_ID` only when the MCP child actually reports that thread id; a `codex-mcp-*` process-scoped id is valid when registered and alive. If this fails or times out, do not attempt a model review; use fallback and report the current-session tool failure.
- Keep the model review packet compact enough to complete under Codex MCP's tool timeout. Do not pass a huge raw diff, full build log, or a path to a large artifact and expect the reviewer to read it.
- Required `review_packet_json` fields for orchestrator review: `task_summary`, `changed_files`, and `diff`. The `diff` field must be an inline, curated diff summary or only the relevant hunks. Put full artifact paths only under `validation` / `known_risks`, not as the primary review input.
- If the changed scope is too large for one compact review packet, split review by area (for example `pricing core`, `template CTA`, `analytics`) and run separate code_review rounds rather than one oversized request.

Fallback when `orchestrator_mcp` is unavailable, unhealthy, or exceeds the tool timeout: read/use **`gstack-review`** and clearly state the fallback. A timeout is a tool failure, not a passed review.

The main agent must pass a compact context handoff to the reviewer:

- `User request:` original task and confirmed scope
- `Classification:` feature / bug / bug+feature
- `Evidence read:` key files, APIs, references, ZenTao ids, or docs used
- `Changed files:` file list plus short intent for each file
- `Diff summary:` behavior changes, data/model changes, UI changes, config changes
- `Validation:` commands/tests/manual checks run and results
- `Active gates:` api-contract, reference-parity, zentao-bug-gate, bugkb, or none
- `Approved requirements chain:` path to artifact plus the state matrix / invariants relevant to the diff
- `Known risks:` edge cases, unverified paths, intentional tradeoffs

The reviewer output must be handed back to the main agent, not treated as the final user answer. The main agent must self-check it:

- Restate each finding as `fix`, `accept risk`, or `not applicable`
- Fix all valid blocking/high-confidence issues within confirmed scope
- Re-run targeted validation after fixes
- Re-run code review when fixes materially change behavior or touch new files
- If a finding is not fixed, document why before asking for commit approval

#### Requirements-chain review gate

Before normal code-quality findings can be considered “passed,” the reviewer and main agent must verify the diff against the approved requirements closure:

- Every approved state has an implementation path or an explicitly approved non-code reason.
- Every implemented state exists in the approved chain.
- Every fallback/loading/error branch is in the approved chain.
- Every invariant / forbidden state is absent from the diff.
- Every golden case has either a test, targeted validation, or documented manual evidence.

If the diff contains an unapproved state, illegal fallback, coerced count/status, locally inferred server state, or UI text/action that contradicts the approved chain, the review result is `revise` or `blocked`. It cannot be accepted as a minor risk merely because the code builds.

#### Review loop gate

`dev-flow` review is a gated loop, not a one-shot check.

- Start counting at the **first post-edit review**. This is `review_round = 1`.
- One round is: `run review` → `main agent classifies findings` → `fixes within scope` → `targeted validation`.
- After any material fix set, the main agent must run the **next review round** before commit-gate.
- For each round, the main agent must explicitly record:
  - `Round:` `1|2|3`
  - `Review result:` pass / revise
  - `Finding decisions:` `fix`, `accept risk`, `not applicable`
  - `Validation rerun:` commands/checks and outcome
- The loop continues until either:
  - review reaches a state that satisfies the interaction / behavior logic for the confirmed scope, or
  - the user explicitly accepts the remaining risk.

#### Three-round stop gate

If **3 consecutive review rounds** have completed after source edits and the work still does **not** meet the required interaction / behavior standard:

- **Do not continue silently**
- **Do not enter commit-gate**
- Mark the task as **blocked waiting for human confirmation**
- Hand back a compact blocker packet containing:
  - `Rounds completed: 3`
  - `Still-open findings`
  - `What was fixed already`
  - `What remains uncertain`
  - `Recommended options for human decision`

The main agent may resume only after explicit user confirmation on how to proceed.

Do not enter `commit-gate` until the code review handoff has been addressed, or the user explicitly accepts the remaining risk.

### Step 7 — After implementation gates

- Feature path: **`bugkb`** (per `feature-workflow`)
- Reference path: parity report (per `reference-parity`)
- ZenTao path: resolve (per `zentao-bug-gate`)

### Step 8 — Commit

Read **`commit-gate`**. When user confirms commit → run. If the script is missing, stop and bootstrap it first; do not silently continue:

```bash
bash scripts/dev-flow-session.sh approve-commit [--task "short label"]
```

Then **`git-commit-convention`** → `git commit`.

---

## Flow diagram

```text
dev-flow
  → code-grounded
  → feature-workflow | bug-workflow
  → api-contract? (if endpoint/field/API-driven behavior is involved)
  → reference-parity? (if reference named)
  → zentao-bug-gate? (if ZenTao required)
  → requirements-analysis-complete → [human approves closed chain]
  → confirm-gate → [user proceed]
  → implement
  → runtime debug loop? → operate UI → query Xcode Console → add DEBUG-only diagnostics if insufficient → rerun
  → code_review round 1
  → requirements-chain review + main-agent self-check → fixes / validation
  → code_review round 2? → fixes / validation
  → code_review round 3?
  → [pass] or [blocked for human confirmation]
  → bugkb? (feature) / parity report? (reference) / zentao resolve? (bug)
  → commit-gate → [user proceed] → git-commit-convention
```

---

## Orchestrator hard rules

1. At each step, **read the atomic skill** — do not rely on memory of old dev-flow text.
2. No code edits before `confirm-gate` approval.
3. No commit before code review results are handed back to the main agent and addressed.
4. No commit before `commit-gate` approval.
5. Sub-gates activate on evidence, not habit.
6. API integration is not complete because fields were decoded. When `api-contract` is active, produce field → business → UI/interaction mapping plus golden cases before coding.
7. Prompt-only discipline is insufficient for contract parity — run golden validation (unit test or script in the target repo) when `reference-parity` is active.
8. Review context must be explicit: never ask a reviewer to infer scope from chat history alone.
9. Review findings are inputs to the main agent's self-check loop; the main agent remains responsible for deciding, fixing, validating, and explaining residual risk.
10. Post-edit review is a **three-round gated loop**. After 3 review rounds without reaching the required interaction / behavior standard, stop and wait for human confirmation.
11. `commit-gate` is forbidden while the three-round review loop is unresolved.
12. Requirements analysis completion is mandatory before coding any stateful interaction. Partial requirements must be closed into an approved state chain before `confirm-gate`.
13. The approved requirements chain is authoritative. Code, fallback, tests, and review must not invent, remove, coerce, or silently reinterpret states.
14. Build success, type success, or a reviewer pass is invalid if the diff violates the approved requirements chain.
15. Runtime claims require matched UI-operation and Console evidence. When diagnostics are insufficient, improve them only after `confirm-gate`, under a compile-time Debug boundary, with redaction and bounded output; never create a second persisted log store.
16. Localized text replacement is incomplete until every supported locale for the same semantic text is mapped, updated, and validated. Missing copy blocks implementation; only an explicit human-approved locale exception may narrow the scope.

---

## Mechanical gate

Every project using dev-flow needs at least the script-backed gate. Repos with shell/editor hooks can enforce it automatically; repos without hooks still use `.dev-flow/sessions/<session-id>.json` as an auditable, task-scoped gate state.

When the current task's `.dev-flow/sessions/<session-id>.json` exists and hooks are installed:

| Hook | Blocks |
|------|--------|
| `preToolUse` | Write/StrReplace/… until `confirm-plan` |
| `beforeShellExecution` | `git commit` until `approve-commit` |

Scripts: `scripts/dev-flow-session.sh`, `.cursor/hooks/dev-flow-guard-*.sh`

If `scripts/dev-flow-session.sh` is missing:

1. Create/bootstrap it before proceeding.
2. Run `bash scripts/dev-flow-session.sh status`.
3. Then rerun `start` / `confirm-plan` / `approve-commit` as required by the current step.
4. Do not describe the missing gate as an acceptable fallback.

---

## Not for

- Large greenfield design without user plan-first intent
- Tasks outside feature/bug scope
