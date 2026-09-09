---
name: environment-health-check
description: Use when a selected development workflow needs an explicit availability report for DebugBridge, 审查角色（@openai-reviewer）, and the Figma REST API skill before continuing execution.
---

# Environment Health Check

## Overview

Provide an evidence-backed availability report for the development capabilities that support UI
implementation, UI review, and runtime verification. The required capabilities are derived from
the session's `required_gates` — only required capabilities are probed; non-required capabilities
are recorded as `not-required` and do not participate in the overall status. The DebugBridge check
has a mandatory App launch preflight on the chosen target (physical device or Simulator): an App
that is not running cannot prove that its in-App DebugBridge is usable. When invoked by
`dev-flow`, this gate runs after `confirm-plan` and before implementation; when invoked
independently, it only reports health and does not select or change a route.

## Capability model

The required capabilities are derived from the session's `required_gates`:

| gate | required capabilities |
|---|---|
| `review` | `review_mcp` |
| `runtime` | `app_launch`, `debugbridge` |
| `figma_ui` | `app_launch`, `debugbridge`, `figma_rest_api` |
| `ui_parity` | `app_launch`, `debugbridge`, `figma_rest_api` |

`review` is always required (every session needs code review). Pure dev-flow / script /
documentation tasks that do not touch App, Figma, or DebugBridge require only `review` and do
**not** need App launch, DebugBridge, or `figma-rest-api`. Review and Figma probes are
independent; the App launch probe is independent; DebugBridge depends on App launch (when both
are required, an App launch failure marks DebugBridge as `not-run` instead of probing). An App
launch failure never short-circuits the review or Figma probes.

## Checks

Run only the probes for required capabilities, then report all four check rows (required ones
probed, non-required marked `not-required`). Do not infer availability from a configured name, an
old process, a previous task, or the existence of a skill file. 审查角色
（@openai-reviewer）and Figma checks remain read-only; the DebugBridge check may launch the
current App as its required App launch preflight on the chosen target.

### 0. App launch preflight for DebugBridge

Before calling any DebugBridge health tool, launch the current App on the chosen target (physical
device or Simulator) through the registered XcodeBuildMCP tools. The App launch preflight is
required only when `app_launch` is a required capability (i.e., the session includes `runtime`,
`figma_ui`, or `ui_parity`).

First, resolve the Xcode target from `<app-root>/.xcodebuildmcp/config.yaml`:

```bash
bash /path/to/devflow/scripts/dev-flow.sh xcode-target
```

The resolver outputs bounded JSON with `target_kind` (`physical` or `simulator`) and
`launch_action` (`build_run_device` or `build_run_sim`). Use the resolver's `profile` fields to
seed `session_set_defaults`. If the resolver is `blocked`, ask the user or explicitly discover a
target; do not auto-scan.

Then confirm the required XcodeBuildMCP tools are actually callable in the current agent turn,
matching the resolver's `launch_action`:

1. Physical target (`target_kind=physical`, `launch_action=build_run_device`): the callable tools
   must include `session_set_defaults`, `session_show_defaults`, and `build_run_device`.
2. Simulator target (`target_kind=simulator`, `launch_action=build_run_sim`): the callable tools
   must include `session_set_defaults`, `session_show_defaults`, and `build_run_sim`.

If any of these tools is not callable, stop and report that XcodeBuildMCP was not callable; do not
guess tool names, use shell builds, or call any unrelated tool as a substitute.

Then: `session_set_defaults` `profile` = current session id (`DEV_FLOW_SESSION_ID`, then
`CODEX_THREAD_ID`, then `CURSOR_CONVERSATION_ID`; never `local` inside Cursor) and
`createIfNotExists: true` for this worktree, setting the resolver's `profile` fields
(`workspacePath`/`projectPath`, `scheme`, `configuration`, `platform`, `deviceId`/`simulatorId`).
Then call `session_show_defaults` and confirm those fields read back correctly. The target is
fixed once chosen; do not assume defaults or silently switch to the other target kind after a
failure.

Call the launch action (`build_run_device` for physical, `build_run_sim` for Simulator) to build,
install, and launch the current App. Pass `env: { DEV_FLOW_SESSION_ID: "<current session id>" }`
in the App launch environment. Record the bounded launch result for the current session:

```bash
cd <app-root>
bash /path/to/devflow/scripts/dev-flow.sh app-launch record --report <bounded-xcodebuildmcp-json|->
bash /path/to/devflow/scripts/dev-flow.sh app-launch status
```

Use `app-launch instructions` when the current session has no App launch report. `--report <path|->`
is required and must import an already bounded XcodeBuildMCP JSON payload (schema_version=2 with
`build_run_action` cross-matched to `device_transport`); the gate must never invent a successful
launch report. Only after a successful build, install, launch, and record step may the
DebugBridge check call `ensure_ports`, then `ping`.

Gate scripts run from the central devflow clone; the app repo only stores `.dev-flow/` session state.
The default App launch probe reads `.dev-flow/sessions/<session-id>.app-launch.json`. Exit code
alone or `/usr/bin/true` is not valid launch evidence.

From the app repo, execute the check through:

```bash
bash /path/to/devflow/scripts/dev-flow.sh environment-health run
```

The script records the report in the current `.dev-flow/sessions/<session-id>.json` and exits
non-zero when any required capability is `blocked` or `not-run`. Use
`DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD` when the registered service requires a local probe adapter. The
App launch probe defaults to `scripts/app-launch-preflight.sh status` after
`scripts/app-launch-preflight.sh record --report`. 审查角色 health defaults to
`scripts/review-health-probe.sh`, which uses the review-backend resolver to select an adapter
(agent/openai-reviewer, mcp/orchestrator, or skill/gstack) and falls back to `gstack-review` when
the primary is unavailable and the policy allows. Override with
`DEV_FLOW_REVIEW_MCP_HEALTH_CMD` only for tests or custom adapters. Do not replace a failed probe
with a hand-written `available` result. `dev-flow-session.sh` requires `confirm-plan` before this
gate can record evidence; after confirmation, `record-gate`, `approve-commit`, `commit`, and
`testflight` reject sessions whose recorded status is not `available` (and `checked_at` must be
on or after `confirmed_at`).

### 1. DebugBridge

After the App launch preflight succeeds, use the registered DebugBridge health capabilities,
normally `ensure_ports` followed by `ping`. The default gate script also validates `/identity`
sessionID against the current dev-flow session via `scripts/validate-bridge-session.sh`; bridge
session `local` blocks when the dev-flow session is not `local`. If health passes, record the
returned device/service evidence without exposing credentials or unbounded payloads. If the tools
are not registered, the service times out, the App is not running, the device bridge is not
reachable, or App session id does not match dev-flow, return `blocked` with the exact missing
capability and phase. Do not substitute Simulator, Xcode GUI automation, system log streams, or
a screenshot.

### 2. 审查角色（@openai-reviewer）

Run `scripts/review-health-probe.sh` first (or read its recorded result). The 审查角色
（@openai-reviewer）is available when **both** hold:

- `~/.config/opencode/opencode.json`（可用 `DEV_FLOW_OPENCODE_CONFIG` 或 `OPENCODE_CONFIG`
  覆盖路径）中存在 agent `"openai-reviewer"`（非空 JSON 对象）；
- 该 agent 的 `model`（形如 `<provider>/<model>`）对应的 provider 段配置了 `options.apiKey`
  （可用 `{env:XXX}` 引用格式；不硬查环境变量，key 运行时解析交给 opencode）。

The probe records `transport=reviewer` when available; otherwise it falls back to a `gstack-review`
skill candidate (`GSTACK_REVIEW_SKILL_ROOT`, or `<skills_root>/gstack/review` under
`~/.config/opencode/skills`, `~/.claude/skills`, `~/.codex/skills`, `~/.cursor/skills`).

A registered and alive 审查角色 agent is valid for the current task. Never conflate another
session's reviewer result with the current one; treat WebUI or unrelated MCP processes as not
evidence for this session's 审查角色 availability.

If availability fails or times out, record the current-session failure and skip reviewer dispatch
through the unavailable path. When `scripts/environment-health-check.sh` runs, 审查角色 health uses
`scripts/review-health-probe.sh`. If the primary adapter is unavailable, the probe automatically
falls back to an installed `gstackReview` skill (`/review`). Record the fallback in evidence as
`fallback=gstack-review`. Actual reviews must then use `code-review-workflow` with
`Review path: fallback` and invoke the gstack `/review` workflow through
`scripts/run-review-fallback.sh` (which enforces token-bound packet + digest anti-forgery).

**Fallback is selected only here — pre-dispatch, during environment-health-check.** Once dispatch
has begun (the reviewer has been invoked), `timeout`/`missing`/`error`/`blocked`/`revise` must be
recorded as-is and the review stops. Post-dispatch fallback switching is prohibited: the session's
`review_selection` is locked on the first review report, and `record-gate` rejects any subsequent
report whose adapter or `review_path` does not match the locked selection. Re-running
`environment-health-check` after dispatch cannot unlock or change the selection.

### 3. Figma REST API skill

Resolve the installed `figma-rest-api` skill and verify both:

- its `SKILL.md` and bundled `scripts/figma_rest.py` are present and readable;
- the default token-safe `curl` request to `https://api.figma.com/v1/me` succeeds with the current
  `FIGMA_REST_TOKEN` (or `FIGMA_ACCESS_TOKEN` alias) without printing or persisting the token.
  The bundled Python client remains the data-fetching client, but is not used as the availability
  probe because its Python `urllib` TLS path can fail independently of Figma reachability and
  token validity.

Treat missing skill files, missing credentials, HTTP 401/403, network failure, and malformed
responses as separate blockers. Do not fetch a project or node merely to prove the skill is
installed. Do not place tokens in artifacts, source code, or command output.

## Result contract

Return one row for each capability:

```text
Environment status: available | blocked
App launch preflight: available | blocked | not-run | not-required
DebugBridge: available | blocked | not-run | not-required
审查角色: available | blocked | not-run | not-required
figma-rest-api: available | blocked | not-run | not-required
Evidence: <health response, run/session id, skill path, or exact error per row>
Blockers: <none or exact next action>
```

`available` means the requested check actually passed. DebugBridge is `available` only when the
current App launch preflight succeeded and the subsequent `ensure_ports` and `ping` checks passed.
`blocked` means the check ran but the capability cannot be used. `not-run` means the check could not
be attempted; never convert it to `available`. `not-required` means the capability is not needed
for the current session's `required_gates` and was not probed.

When invoked by `dev-flow`, every required capability must be `available` after `confirm-plan`
and before implementation, gate recording, commit approval, commit, or TestFlight; `blocked` or
`not-run` stops those actions. Non-required capabilities do not participate in the overall
status. When invoked independently, the caller decides how to use the report. This skill reports
health; it does not approve requirements, authorize source edits, select a review route, or
approve a commit.

## Safety rules

- Keep 审查角色 and Figma checks read-only and bounded; keep the required App launch preflight
  bounded to the current target and current App.
- Never probe DebugBridge before the App launch preflight succeeds.
- Do not kill, restart, or clean up another task's service process.
- Do not expose tokens, cookies, signatures, device identifiers, or raw sensitive payloads.
- Preserve exact error phase and next action for every failed check.
- Do not claim end-to-end UI or code-review success from a health check alone.
