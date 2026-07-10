---
name: dev-flow
description: Orchestrator for small feature work and bug fixes. Trigger only on explicit user intent (/dev-flow, 先方案, 修 bug, 先排查). Loads atomic skills in order; do not embed their full rules here. Always read code-grounded first; branch to feature-workflow or bug-workflow; activate reference-parity and zentao-bug-gate only when evidence requires; confirm-gate before edits; code review after implementation with context handoff back to the main agent for self-check; commit-gate after review is addressed.
---

# Dev Flow (Orchestrator)

## Purpose

Orchestrate **small feature** and **bug fix** work. This file defines **order and triggers only**. Detailed rules live in atomic skills — **read them at each step**.

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

Supporting skills/tools (invoked by atomic skills or this orchestrator): `orchestrator_mcp` `code_review`, `gstack-review`, `gstack-investigate`, `bugkb`, `git-commit-convention`, `zentao`.

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

It must write `.dev-flow/session.json` with `active`, `type`, `task`, `started_at`, `confirmed_at`, `commit_approved_at`, and `ended_at`.

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

### Step 3 — Confirm before code

Read **`confirm-gate`**. Wait for user **proceed**.

When user **Proceed** → immediately run. If the script is missing, stop and bootstrap it first; do not silently continue:

```bash
bash scripts/dev-flow-session.sh confirm-plan [--task "short label"]
```

Only then may source edits begin.

### Step 4 — Implement

Only confirmed scope. Important decision points → short comments (why/guardrail).

### Step 5 — Code review handoff

After any source edit and before commit-gate, run a code review stage.

Preferred path:

```text
orchestrator_mcp → code_review
```

Fallback only when `orchestrator_mcp` is unavailable: read/use **`gstack-review`** and clearly state the fallback.

The main agent must pass a compact context handoff to the reviewer:

- `User request:` original task and confirmed scope
- `Classification:` feature / bug / bug+feature
- `Evidence read:` key files, APIs, references, ZenTao ids, or docs used
- `Changed files:` file list plus short intent for each file
- `Diff summary:` behavior changes, data/model changes, UI changes, config changes
- `Validation:` commands/tests/manual checks run and results
- `Active gates:` api-contract, reference-parity, zentao-bug-gate, bugkb, or none
- `Known risks:` edge cases, unverified paths, intentional tradeoffs

The reviewer output must be handed back to the main agent, not treated as the final user answer. The main agent must self-check it:

- Restate each finding as `fix`, `accept risk`, or `not applicable`
- Fix all valid blocking/high-confidence issues within confirmed scope
- Re-run targeted validation after fixes
- Re-run code review when fixes materially change behavior or touch new files
- If a finding is not fixed, document why before asking for commit approval

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

### Step 6 — After implementation gates

- Feature path: **`bugkb`** (per `feature-workflow`)
- Reference path: parity report (per `reference-parity`)
- ZenTao path: resolve (per `zentao-bug-gate`)

### Step 7 — Commit

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
  → confirm-gate → [user proceed]
  → implement
  → code_review round 1
  → main-agent self-check → fixes / validation
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

---

## Mechanical gate

Every project using dev-flow needs at least the script-backed gate. Repos with shell/editor hooks can enforce it automatically; repos without hooks still use `.dev-flow/session.json` as an auditable gate state.

When `.dev-flow/session.json` exists and hooks are installed:

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
