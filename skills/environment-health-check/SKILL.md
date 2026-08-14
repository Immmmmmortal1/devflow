---
name: environment-health-check
description: Use when a selected development workflow needs an explicit availability report for DebugBridge, Review MCP, and the Figma REST API skill before continuing execution.
---

# Environment Health Check

## Overview

Provide an evidence-backed availability report for the development capabilities that support UI
implementation, UI review, and runtime verification. The DebugBridge check has a mandatory physical
App launch preflight: an App that is not running cannot prove that its in-App DebugBridge is usable.
When invoked by `dev-flow`, this is the first gate after route classification; when invoked
independently, it only reports health and does not select or change a route.

## Checks

Run the App launch preflight and all three capability checks, then report all four results. Do not
infer availability from a
configured name, an old process, a previous task, or the existence of a skill file. Review MCP and
Figma checks remain read-only; the DebugBridge check may launch the current App as its required
physical-device preflight.

### 0. App launch preflight for DebugBridge

Before calling any DebugBridge health tool, launch the current App on a physical device through the
registered XcodeBuildMCP tools in this exact order:

1. Isolate XcodeBuildMCP defaults with `session_set_defaults` `profile` = current session id
   (`DEV_FLOW_SESSION_ID`, then `CODEX_THREAD_ID`, then `CURSOR_CONVERSATION_ID`; never `local`
   inside Cursor) and `createIfNotExists: true` for this worktree. Then call
   `session_show_defaults` and confirm the project/workspace, scheme, configuration, and
   physical device. Do not assume defaults or use a simulator.
2. Call `build_run_device` to build, install, and launch the current App. Pass the current
   `DEV_FLOW_SESSION_ID` to the launched App when the project supports it.
3. Record the bounded launch result for the current session:

```bash
bash scripts/record-app-launch-report.sh record
```

Use `--report <path>` only when importing an already bounded XcodeBuildMCP JSON payload.
4. Only after a successful build, install, launch, and record step may the DebugBridge check call
   `ensure_ports`, then `ping`.

The default App launch probe reads `.dev-flow/sessions/<session-id>.app-launch.json`. Its JSON must
identify `producer: XcodeBuildMCP`, schema version 1, current session id,
`build_run_device: success`, `device_transport: wired`, and `app_launched: true`. Exit code alone
or `/usr/bin/true` is not valid launch evidence. Override with `DEV_FLOW_APP_LAUNCH_HEALTH_CMD`
only when a custom adapter is required.

If `session_show_defaults` is missing or wrong, or `build_run_device` fails at build, signing,
installation, launch, or device connectivity, report the DebugBridge capability as `blocked` with
the exact `app_launch` phase and first actionable error. Do not call `ensure_ports` or `ping` against
an App that was not launched in the current check, and do not replace the launch with a stale App,
Simulator, Xcode GUI automation, system log stream, or screenshot. Review MCP and Figma checks may
run independently while this preflight is in progress or blocked.

From a repository using `dev-flow`, execute the check through the session-aware script:

```bash
bash scripts/environment-health-check.sh run
```

The script records the report in the current `.dev-flow/sessions/<session-id>.json` and exits
non-zero when any check is `blocked` or `not-run`. Use `DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD` when the
registered service requires a local probe adapter. The App launch probe defaults to
`scripts/read-app-launch-report.sh` after `scripts/record-app-launch-report.sh record`. Review MCP
health defaults to `scripts/review-health-probe.sh`, which falls back to `gstack-review` when
orchestrator MCP is unavailable. Override with `DEV_FLOW_REVIEW_MCP_HEALTH_CMD` only for tests or
custom adapters. The script can use a sibling `orchestrator-mcp/scripts/orchestrator-doctor.sh`
through that probe; do not replace a failed probe with a hand-written `available` result.
`dev-flow-session.sh` rejects `confirm-plan` and `approve-commit` until the recorded status is
`available`.

### 1. DebugBridge

After the App launch preflight succeeds, use the registered DebugBridge health capabilities,
normally `ensure_ports` followed by `ping`. If health passes, record the returned device/service
evidence without exposing credentials or unbounded payloads. If the tools are not registered, the
service times out, the App is not running, or the device bridge is not reachable, return `blocked`
with the exact missing capability and phase. Do not substitute Simulator, Xcode GUI automation,
system log streams, or a screenshot.

### 2. Review MCP

Use the non-model Review MCP health/config check first:

```text
orchestrate_effective_config
```

Require a usable current session with `transport=stdio`, `registered=true`, and a live reported
PID. When the configured provider is needed for an actual review, run the provider credential check
without printing secrets. A WebUI process or another task's MCP process is not evidence for the
current session. Do not call a model review just to test health.

When `scripts/environment-health-check.sh` runs, Review MCP health uses
`scripts/review-health-probe.sh`. If orchestrator MCP is unavailable, the probe automatically
falls back to an installed `gstack-review` skill (`/review`). Record the fallback in evidence as
`review_mcp_unavailable;fallback=gstack-review`. Actual reviews must then use
`code-review-workflow` with `Review path: fallback` and invoke the gstack `/review` workflow instead
of `orchestrator_mcp → code_review`.

### 3. Figma REST API skill

Resolve the installed `figma-rest-api` skill and verify both:

- its `SKILL.md` and bundled `scripts/figma_rest.py` are present and readable;
- its smallest read-only authentication request, `figma_rest.py me`, succeeds with the current
  `FIGMA_REST_TOKEN` (or `FIGMA_ACCESS_TOKEN` alias) without printing or persisting the token.

Treat missing skill files, missing credentials, HTTP 401/403, network failure, and malformed
responses as separate blockers. Do not fetch a project or node merely to prove the skill is
installed. Do not place tokens in artifacts, source code, or command output.

## Result contract

Return one row for each capability:

```text
Environment status: available | blocked | not-run
App launch preflight: available | blocked | not-run
DebugBridge: available | blocked | not-run
Review MCP: available | blocked | not-run
figma-rest-api: available | blocked | not-run
Evidence: <health response, run/session id, skill path, or exact error per row>
Blockers: <none or exact next action>
```

`available` means the requested check actually passed. DebugBridge is `available` only when the
current App launch preflight succeeded and the subsequent `ensure_ports` and `ping` checks passed.
`blocked` means the check ran but the capability cannot be used. `not-run` means the check could not
be attempted; never convert it to `available`.

When invoked by `dev-flow`, every capability must be `available` before the selected route starts;
`blocked` or `not-run` stops that route. When invoked independently, the caller decides how to use
the report. This skill reports health; it does not approve requirements, authorize source edits,
select a review route, or approve a commit.

## Safety rules

- Keep Review MCP and Figma checks read-only and bounded; keep the required App launch preflight
  bounded to the current physical device and current App.
- Never probe DebugBridge before the App launch preflight succeeds.
- Do not kill, restart, or clean up another task's service process.
- Do not expose tokens, cookies, signatures, device identifiers, or raw sensitive payloads.
- Preserve exact error phase and next action for every failed check.
- Do not claim end-to-end UI or code-review success from a health check alone.
