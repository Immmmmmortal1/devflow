---
name: runtime-debug-workflow
description: Use when an iOS change must be built, launched, operated, inspected, or debugged on a real physical device with XcodeBuildMCP, DebugBridge, UIWindow evidence, and current-run App logs.
---

# Runtime Debug Workflow

## Overview

Verify real device behavior as a correlated chain of build, launch, UI operation, view-tree
inspection, and current-run log evidence. Do not claim an endpoint, callback, state transition, or
UI result from a screenshot, build result, or log line alone.

This skill owns physical-device runtime evidence. It does not define product requirements, API
meaning, UI parity, code review, or commit approval.

## Tool boundary

Use the registered tools in this order:

1. XcodeBuildMCP named profile = current session id (`DEV_FLOW_SESSION_ID`, then `CODEX_THREAD_ID`, then `CURSOR_CONVERSATION_ID`), then `session_show_defaults`, then `build_run_device` with `env: { DEV_FLOW_SESSION_ID: "<current session id>" }`.
2. DebugBridge `get_debug_page` and UI actions such as `tap_element`.
3. DebugBridge `inspect_ui` for the current App UIWindow/UIView tree.
4. DebugBridge `read_app_logs` for the complete current-run in-memory log pool, or
   `wait_app_logs` for a new matching entry.

If the required registered tool or physical device is unavailable, return `runtime-blocked` with
the exact missing capability. Do not silently switch to a simulator, Xcode GUI automation,
`Command+R`, `xcodebuild`/`devicectl` as a substitute, system-wide log streams, or persisted log
files for a real-device claim.

## Workflow

### 1. Establish the physical runtime

Resolve the current session id (`DEV_FLOW_SESSION_ID`, then `CODEX_THREAD_ID`, then
`CURSOR_CONVERSATION_ID`; never `local` inside Cursor). Call `session_set_defaults` with
`profile` set to that id and `createIfNotExists: true` for this worktree, then
`session_show_defaults`. Confirm the project/workspace, scheme, configuration, and physical
device belong to this repo, not a sibling worktree. Then call `build_run_device` with the
current session id in the App launch environment so DebugBridge identity matches dev-flow:

```text
build_run_device({ env: { DEV_FLOW_SESSION_ID: "<current session id>" } })
```

Without this env, the App reports `sessionID: local` in `/identity` and environment-health /
commit gates block DebugBridge.

Record:

```text
device name/UDID | iOS version | project/workspace | scheme | build configuration
build/run result | app identity | launch time | session id
```

If build, signing, installation, launch, or device connectivity fails, stop at that phase. Record
the first actionable error; do not inspect the UI or claim runtime behavior from an old build.

### 2. Operate the real UI

Use `get_debug_page` to identify the current page, then use registered DebugBridge actions to follow
the exact user flow. Record each action, its target anchor or label, and the resulting page/state.
Do not ask the user to reproduce actions that the registered runtime tool can perform.

For every claimed interaction, preserve the pair:

```text
action evidence → resulting UI evidence
```

### 3. Inspect the runtime tree

Use `inspect_ui` after entering the target state and after meaningful transitions. Record the actual
visible UIWindow/UIView hierarchy, page/root identity, runtime anchor or accessibility identifier,
type, label/value, enabled state, visibility, frame, and interaction state.

For scrollable screens also record the primary scroll owner, content/visible heights, and whether the
target control is reachable. A screenshot may supplement the tree for non-parity tasks but cannot
replace it. When invoked by `ui-review`, screenshots are prohibited as evidence; use DebugBridge
runtime nodes and hierarchy only.

### 4. Correlate current-run logs

Use `read_app_logs` to search the complete current-run in-memory pool, or `wait_app_logs` when the
next event has not appeared. Search by stable marker, request id, or event name. A restarted App
starts a fresh pool; there is no cursor, offset, persistent history, or agent-created duplicate log
store.

Correlate logs with the exact UI action and current app run:

```text
action_started → request/callback event → state transition → resulting UI tree
```

If a log is absent, distinguish “the event was not observed” from “the event did not occur.” Do not
use a system-wide log stream as proof of the App's current-run behavior.

### 5. Add targeted diagnostics only when needed

If the code path is reached but existing logs cannot answer the current question, obtain
`confirm-gate` approval before source edits. Add the smallest DEBUG-only diagnostic that is:

- behind `#if DEBUG` or an equivalent compile-time Debug boundary;
- searchable by a stable marker or request/trace id;
- placed at the action, request, callback, and state-transition boundaries needed to distinguish the hypothesis;
- limited to safe enums, counts, timings, error domains/codes, and redacted state;
- bounded in size and frequency.

Never log credentials, tokens, cookies, signatures, user/device identifiers, raw payloads, or
unbounded error objects. Do not change business behavior, retry semantics, thread scheduling, or
the source of truth merely to make logging easier.

### 6. Rebuild and rerun

After a diagnostic or relevant source change, call `build_run_device` again, repeat the same UI
actions, inspect the tree, and query the current-run logs. Keep reusable safe diagnostics only when
they are within the confirmed scope; remove noisy one-off output before handoff.

### 7. Return a runtime result

Use one status:

- `runtime-verified`: build/run, exact UI action, resulting UI tree, and relevant current-run log evidence all match the claim.
- `runtime-failed`: the target behavior was exercised and failed, with the first actionable evidence recorded.
- `runtime-blocked`: device, build, tool, app state, or required evidence was unavailable.

Use [runtime-evidence-template.md](references/runtime-evidence-template.md) and report the exact
unverified boundary. Do not convert `runtime-blocked` or a tool timeout into a pass.

## Scope boundaries

- `requirements-closure` defines the approved state chain that runtime evidence must prove.
- `api-contract` defines API field meaning; runtime logs only show observed execution.
- `figma-ui-gates` / `ui-review` define Figma implementation or parity evidence.
- `confirm-gate` authorizes diagnostic source edits.
- `code-review-workflow` evaluates source changes after runtime work.

When invoked inside a dev-flow session, record the final status with
`bash scripts/dev-flow-session.sh record-gate --name runtime --report <path>`. Only
`runtime-verified` satisfies the commit gate; `runtime-failed`, `runtime-blocked`, or an absent
record remains blocked.

Home-specific proof arguments, mock payload conventions, and product navigation rules belong in a
separate product skill. Do not add them to this generic runtime workflow.

## Common mistakes

- **Build passed, therefore behavior passed:** build success proves no runtime interaction.
- **Screenshot proves the state:** bind the state to a real UI action and inspected tree.
- **No log means no callback:** verify filters and correlate the current run before concluding.
- **Use Xcode Console or system logs as a shortcut:** use the registered current-run App log tools.
- **Add broad production logging:** keep diagnostics Debug-only, redacted, bounded, and approved.
- **Leave the device on a proof or debug state:** rerun the production entry before handoff when a project-specific proof path was used.
