---
name: environment-health-check
description: Use when a selected development workflow needs an explicit availability report for DebugBridge, Review MCP, and the Figma REST API skill before continuing execution.
---

# Environment Health Check

## Overview

Provide a read-only, evidence-backed availability report for the development capabilities that
support UI implementation, UI review, and runtime verification. When invoked by `dev-flow`, it is
the first gate after route classification; when invoked independently, it only reports health and
does not select or change a route.

## Checks

Run all three checks independently and report each result. Do not infer availability from a
configured name, an old process, a previous task, or the existence of a skill file.

From a repository using `dev-flow`, execute the check through the session-aware script:

```bash
bash scripts/environment-health-check.sh run
```

The script records the report in the current `.dev-flow/sessions/<session-id>.json` and exits
non-zero when any check is `blocked` or `not-run`. Use `DEV_FLOW_DEBUGBRIDGE_HEALTH_CMD` and
`DEV_FLOW_REVIEW_MCP_HEALTH_CMD` when the registered service requires a local probe adapter. The
script can use a sibling `orchestrator-mcp/scripts/orchestrator-doctor.sh` when present; do not
replace a failed probe with a hand-written `available` result. `dev-flow-session.sh` rejects
`confirm-plan` and `approve-commit` until the recorded status is `available`.

### 1. DebugBridge

Use the registered DebugBridge health capabilities, normally `ensure_ports` followed by `ping`.
If health passes, record the returned device/service evidence without exposing credentials or
unbounded payloads. If the tools are not registered, the service times out, or the device bridge is
not reachable, return `blocked` with the exact missing capability. Do not substitute Simulator,
Xcode GUI automation, system log streams, or a screenshot.

### 2. Review MCP

Use the non-model Review MCP health/config check first:

```text
orchestrate_effective_config
```

Require a usable current session with `transport=stdio`, `registered=true`, and a live reported
PID. When the configured provider is needed for an actual review, run the provider credential check
without printing secrets. A WebUI process or another task's MCP process is not evidence for the
current session. Do not call a model review just to test health.

### 3. Figma REST API skill

Resolve the installed `figma-rest-api` skill and verify both:

- its `SKILL.md` and bundled `scripts/figma_rest.py` are present and readable;
- its smallest read-only authentication request, `figma_rest.py me`, succeeds with the current
  `FIGMA_REST_TOKEN` without printing or persisting the token.

Treat missing skill files, missing credentials, HTTP 401/403, network failure, and malformed
responses as separate blockers. Do not fetch a project or node merely to prove the skill is
installed. Do not place tokens in artifacts, source code, or command output.

## Result contract

Return one row for each capability:

```text
Environment status: available | blocked | not-run
DebugBridge: available | blocked | not-run
Review MCP: available | blocked | not-run
figma-rest-api: available | blocked | not-run
Evidence: <health response, run/session id, skill path, or exact error per row>
Blockers: <none or exact next action>
```

`available` means the requested read-only check actually passed. `blocked` means the check ran but
the capability cannot be used. `not-run` means the check could not be attempted; never convert it
to `available`.

When invoked by `dev-flow`, every capability must be `available` before the selected route starts;
`blocked` or `not-run` stops that route. When invoked independently, the caller decides how to use
the report. This skill reports health; it does not approve requirements, authorize source edits,
select a review route, or approve a commit.

## Safety rules

- Keep all checks read-only and bounded.
- Do not kill, restart, or clean up another task's service process.
- Do not expose tokens, cookies, signatures, device identifiers, or raw sensitive payloads.
- Preserve exact error phase and next action for every failed check.
- Do not claim end-to-end UI or code-review success from a health check alone.
