---
name: dev-flow
description: Use when the user explicitly requests dev-flow for a feature, bug fix, new Figma-driven UI implementation, existing UI parity review, plan-first investigation, or automated mobile development task.
---

# Dev Flow

## Purpose

`dev-flow` is the top-level router and automated development loop for three first-class routes:

```text
feature | bug | ui_review
```

New Figma UI is a conditional sub-route of `feature`, not an independent entry. The normal
completion contract is:

```text
approved requirements → confirmed plan → implementation/review → runtime evidence
→ code review → route result → bugkb/ZenTao/UI result → commit approval → commit
```

This file owns orchestration only. Detailed procedures belong to the selected skills below.

## When to use

Use for `/dev-flow`, `/dev-flow feature`, `/dev-flow bug`, `/dev-flow ui_review`, plan-first
investigation, feature development, bug fixing, new Figma-driven UI, or existing UI parity review.

Do not use for explain-only questions, unrelated work, or pure code review that does not request
the `ui_review` route.

## Install / upgrade (agents must run first)

From the devflow git clone (after `git pull`):

```bash
bash scripts/install-dev-flow.sh --project <ios-app-root>
```

- Gate scripts stay in the devflow clone only; never copy them into the app repo
- The app repo gets only `.dev-flow/` session state plus DebugBridge install manifest
- Installs [UI-dbugbridge-mcp](https://github.com/Immmmmmortal1/UI-dbugbridge-mcp): Mac MCP server + LookDebugBridge Pod wiring when a Podfile exists
- After install, if `pod_changed` in `.dev-flow/debugbridge-install.json`: run `pod install`, add Debug bootstrap from `.dev-flow/debugbridge-app-bootstrap.swift.snippet`, restart MCP host
- Verify with: `bash <devflow-root>/scripts/dev-flow.sh doctor` from the app root


| Route / condition | Required skill | Owns |
|---|---|---|
| Every task | `code-grounded` | evidence, scope, classification |
| First gate of every first-class route | `environment-health-check` | physical App launch preflight plus DebugBridge, Review MCP, and `figma-rest-api` availability |
| `feature` | `feature-workflow` | feature analysis and execution plan |
| `bug` | `bug-workflow` | bug analysis and repair plan |
| Stateful behavior | `requirements-closure` | closed state chain and requirements artifact |
| Localized copy | `localization-workflow` | locale matrix, translations, exceptions, validation |
| API-driven behavior | `api-contract` | field → business state → UI mapping |
| New Figma UI in `feature` | `figma-ui-gates` | Figma decomposition and G0–G12 implementation gates |
| Existing UI parity | `ui-review` | Whole-page G2-equivalent split hard gate (`--stage split`) → all-unit live compare → baseline → human-authorized repair → live re-verify → acceptance |
| After `ui_review` source repairs | `code-review-workflow` → `ui-parity-review` | post-fix Review MCP on authorized diffs only |
| Real-device validation | `runtime-debug-workflow` | XcodeBuildMCP, DebugBridge, logs, runtime evidence |
| Review after source edits | `code-review-workflow` + selected route | Review MCP base capability and review criteria |
| Bug historical check | `zentao-bug-gate` when required | ZenTao id and resolution |
| Before commit | `commit-gate` | commit authorization and scope |

Read the selected skill at the point where its route activates. Do not copy its detailed
procedures into this file.

## Orchestration

### 0. Enter and isolate the session

Read `code-grounded`, then start the task-scoped mechanical gate:

```bash
bash scripts/dev-flow-session.sh start --type bug|feature|ui_review --task "short label"
```

The script must isolate state by `DEV_FLOW_SESSION_ID`, then `CODEX_THREAD_ID`, then
`CURSOR_CONVERSATION_ID`. Outside Cursor it may fall back to `local`; inside Cursor
(`CURSOR_AGENT=1`) a missing conversation id is an error and must not reuse shared `local.json`.
It must support `status`, `confirm-plan`, `approve-commit`, and `end`. Never bypass a missing gate
or read another task's session state.

It must also support `environment-health --report <path>`. `confirm-plan` and
`approve-commit` must reject sessions whose recorded environment status is not `available`.
Every session requires the `review` gate by default. Before confirmation, configure conditional
gates when the task needs them:

```bash
bash scripts/dev-flow-session.sh configure-gates --required review,figma_ui,runtime
```

After each gate completes, record its bounded result in the same session:

```bash
bash scripts/dev-flow-session.sh record-gate --name figma_ui|review|runtime --report <path>
```

`figma_ui` is accepted only when G0 through G12 are all `pass`; `review` is accepted only when its
route result is `pass`; `runtime` is accepted only as `runtime-verified`.

### 1. Classify the route

Classify exactly one first-class route:

- New capability or new Figma screen → `feature`.
- Defect or regression → `bug`.
- Existing screen Figma parity review → `ui_review`.

`ui_new` is not a session type or first-level route. A `feature` with new Figma UI activates
`figma-ui-gates` only after the requirements and confirmation gates.

### 2. Run the first gate for the selected route

After classification and before reading `feature-workflow`, `bug-workflow`, or `ui-review`, read
`environment-health-check`. This gate does not participate in route classification and must not
change the selected route.

Run the executable check for the current session from the **devflow clone**, with the app repo as
project root:

```bash
cd <app-root>
bash /path/to/devflow/scripts/dev-flow.sh doctor
bash /path/to/devflow/scripts/dev-flow.sh environment-health run
```

Before the health check, complete the physical-device launch preflight and record it:

```bash
bash /path/to/devflow/scripts/dev-flow.sh record-app-launch record
```

Gate scripts live only in the devflow git clone. App repos keep `.dev-flow/sessions/` state only.
Initialize once with `dev-flow-init-project.sh <app-root>` after clone; `git pull` devflow updates
every project automatically without per-app script copies.

The command writes the four results into `.dev-flow/sessions/<session-id>.json`. It exits non-zero
when any capability is unavailable.

All four checks must return `available`:

- current App physical-device build/install/launch preflight;
- DebugBridge health and connectivity;
- Review MCP current-session health, or `gstack-review` fallback when orchestrator MCP is unavailable;
- `figma-rest-api` Skill presence and read-only authentication check.

If any result is `blocked` or `not-run`, stop before the selected route starts and report the exact
environment blocker. Do not use a route-specific fallback to bypass this gate, except the built-in
Review MCP → `gstack-review` (`/review`) fallback recorded by `scripts/review-health-probe.sh`.

### 3. Activate conditional skills

Activate only when evidence requires them:

- Stateful interaction, business state, fallback, or behavior-changing copy → `requirements-closure`.
- Localized copy, locale files, translations, or same-string exception → `localization-workflow`.
- Endpoint, response field, server-driven behavior, or status mapping → `api-contract`.
- Bug fix with ZenTao requirement → `zentao-bug-gate`.
- New Figma UI → defer `figma-ui-gates` until after `confirm-gate`.
- Real iOS device build, operation, inspection, or logs → `runtime-debug-workflow`.

### 4. Close requirements before coding

For a stateful or behavior-changing task, read `requirements-closure`. It must search for or create
the repository-local `.dev-flow/requirements/` artifact, close surrounding states and fallbacks,
record invariants, evidence, Golden cases, and open decisions, then return:

```text
pending-human-approval | approved | blocked
```

Only an `approved` artifact may proceed. The approved artifact is authoritative for implementation,
runtime validation, and `requirements-chain-review`. Do not duplicate its state-chain procedure here.

If localized content is involved, `localization-workflow` must return `ready` or `blocked` with a
complete locale matrix before the confirmation plan. Missing copy is a blocker unless the user
records an explicit same-string exception.

### 5. Confirm the implementation scope

Read `confirm-gate` and wait for explicit user confirmation. Then run:

```bash
bash scripts/dev-flow-session.sh confirm-plan --task "short label"
```

No source edits, including diagnostic logging, are allowed before this command. A read-only
`ui_review` evidence pass (Structure + Group reviews with no edits) may finish without
`confirm-plan`; after the whole-page parity result is complete, the first authorized repair requires
workspace-level `parity-confirmed.json` plus `confirm-plan` once.

### 6. Implement or review

- `feature`: implement only the approved plan. If it includes new Figma UI, read
  `figma-ui-gates` now and complete its G0–G12 contract.
- `bug`: implement only the approved repair plan.
- `ui_review`: read `ui-review` and execute its pipeline in this order: Step1 whole-page
  **G2-equivalent hard gate** (recursive detail + real Review MCP evidence; pass
  `validate-ui-review-artifacts --stage split`; do not hardcode the unit index or bundle
  parity writes) → only then live-compare **every minimum unit** → freeze the baseline → obtain
  workspace-level `parity-confirmed.json` → repair authorized units one at a time with live
  verification → obtain `repair-accepted.json`. Do not edit any Group before the whole-page
  comparison and human authorization are complete. After source repairs, call
  `code-review-workflow` with route `ui-parity-review` (post-fix only).
- When the task needs physical-device evidence, delegate the full runtime loop to
  `runtime-debug-workflow`. Accept only `runtime-verified`, `runtime-failed`, or
  `runtime-blocked`; never convert missing evidence into a pass.

### Runtime rendering inspection rule

Whenever the task requires checking the rendered UI state—on either a physical device or an iOS
Simulator—use DebugBridge as the only inspection path. Read the live view hierarchy, runtime nodes,
and any required app logs through DebugBridge. Do not use screenshots or image inspection as
evidence: this includes XcodeBuildMCP screenshots, Simulator screenshots, `view_image`, saved
screen captures, or previously generated screenshot artifacts. A screenshot may not be captured,
opened, or used as a fallback for a DebugBridge inspection failure; report the DebugBridge blocker
instead.

### 7. Review source changes

After source edits, read `code-review-workflow` and select a route from `routes/index.md`. The base
skill owns Review MCP health, compact packet construction, MCP invocation, and bounded
`gstack-review` fallback. The selected route owns review criteria, finding decisions, validation,
and the final `pass`, `blocked`, or revise result.

Only route `pass`, or residual risk explicitly accepted by the user and recorded by the route, may
continue. Timeout, missing result, or `blocked` is not a pass.

### 8. Complete route-specific post-gates

- Feature → run `bugkb` and record the post-implementation regression check.
- Bug → resolve through `zentao-bug-gate` when required.
- Feature with new Figma UI → record the `figma-ui-gates` G0–G12 result and run
  `validate-g6-asset-binding.sh` before `record-gate --name figma_ui`.
- `ui_review` → when repairs ran, post-fix `ui-parity-review` must pass first; then record `review`,
  mandatory `runtime=runtime-verified`, and `ui_parity=accepted`. The parity report must bind
  `parity-confirmed.json` to `repair-accepted.json` and prove every authorized id accepted or
  verified-reverted. A read-only review with no edits uses the read-only review result and does not
  require `confirm-plan`, `runtime`, `ui_parity`, or a commit.

Record each applicable result with `dev-flow-session.sh record-gate`; a written skill result that is
not recorded in the current session does not satisfy the mechanical gate.

### 9. Commit

Read `commit-gate`. First detect same-branch sibling worktrees; if any exist, commit the child,
merge into that family's main worktree only, then sync siblings — never merge into `master` or
another family. Partition the remaining work into one feature module or one independent bug fix per
commit. Generate the Chinese commit message through `git-commit-convention`, report validation and
excluded changes, then wait for confirmation. After confirmation run:

```bash
bash scripts/dev-flow-session.sh approve-commit --task "short label"
```

Only then may the exact approved scope be committed. End the session with:

```bash
bash scripts/dev-flow-session.sh end
```

## Hard rules

1. No source edits before `confirm-gate` and `confirm-plan`.
2. Every first-class route must pass `environment-health-check` before its route skill starts.
3. A blocked or unrun environment check cannot be bypassed by selecting another route or fallback,
   except Review MCP health may fall back to `gstack-review` (`/review`) through
   `scripts/review-health-probe.sh`.
4. No coding while the requirements artifact is `draft`, `pending-human-approval`, or `blocked`.
5. The approved requirements chain is authoritative; code, fallback, tests, and review cannot
   invent, remove, coerce, or silently reinterpret states.
6. Localization is incomplete until every required locale is mapped and validated.
7. Runtime claims require correlated UI action, inspected UI tree, and current-run App log evidence.
8. Rendered-state inspection on both physical devices and Simulators must use DebugBridge only;
   screenshots and image inspection are prohibited, including as a fallback.
9. Review timeout, missing output, or `blocked` never becomes a pass.
10. No commit before every required gate is recorded in the current session with its passing status.
11. `figma_ui` requires G0-G12 all pass and `g6_validation=pass` with a bounded
    `g6_validation_report`; `review` requires `pass`; `runtime` requires `runtime-verified`; and
    configured `ui_parity` requires `accepted` with matching authorization and acceptance reports.
    Failed, blocked, unknown, or missing results cannot be converted to pass.
12. The selected review route and `commit-gate` must still approve the exact scope after the
    mechanical gate passes.
13. Mixed features, unrelated fixes, and formatting-only changes must be split into separate commits.
14. New Figma UI is a `feature` sub-route; `ui_new` must not be exposed as a first-level route.

## Flow

```text
classify
→ feature | bug | ui_review
→ environment-health-check [all four available: app_launch + debugbridge + review_mcp + figma_rest_api]
→ requirements-closure? → localization-workflow? → api-contract? → zentao-bug-gate?
→ confirm-gate (required before first source edit)
→ feature: figma-ui-gates? → implement
→ bug: implement repair
→ ui_review: G2-equivalent split hard gate → all-unit live compare → baseline → authorize → per-unit repair
  (confirm-plan before first fix) → human acceptance
→ runtime-debug-workflow?
→ code-review-workflow + selected route
  (ui_review repairs → route ui-parity-review)
→ bugkb / ZenTao / ui-review parity-result.json
→ commit-gate → commit
```

## Not for

- Large greenfield design without plan-first intent
- Explain-only requests
- Tasks outside `feature`, `bug`, or `ui_review`
