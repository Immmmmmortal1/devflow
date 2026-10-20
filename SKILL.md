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
approved requirements → confirmed plan → implement → runtime evidence
→ code review → route result → bugkb/ZenTao/UI result → commit approval → commit
```

This file owns orchestration only. Detailed procedures belong to the selected skills below.

## Context pointer convention

Skills use **context pointers** (links to reference files) for detailed templates and
contracts. Progressive disclosure keeps each SKILL.md focused on execution order and hard stops,
while references hold the full specification. Every pointer must:

1. **State what the reference is** — a template, a contract, a definition set.
2. **State when to read it** — the step or condition that triggers the read.

Example: "Read [references/bug-repro-template.md](references/bug-repro-template.md) for the
full contract (minimal repro, full scenario, allowed evidence, blocked handling)" — this tells
the agent the reference is a contract and the trigger is the red-capable feedback loop step.

Main Skills retain their execution order and hard stops. Long detailed content lives in
references. Do not mass-move existing top-level SKILL.md long prose into references; only new
contracts and templates are added as references. New references must be registered in
`scripts/link-skills-common.sh` so they are installed alongside their parent skill.

## Global connection rule

Dev-flow must not proactively close, exit, restart, or release the current MCP or DebugBridge
connection. Keep the active connection available for the rest of the task and subsequent
verification. Connection cleanup is allowed only when the user explicitly requests it.

## XcodeBuildMCP fixed invocation rule

Any dev-flow route that needs iOS build, install, launch, runtime evidence, or `app_launch`
preflight must use XcodeBuildMCP in this exact order:

Before every XcodeBuildMCP interaction in a dev-flow task, reread this section and apply it as a
hard gate. Do not rely on memory, previous turns, or inferred tool names.

The XcodeBuildMCP launch chain is atomic. Once it starts, the next tool calls must be exactly
`session_set_defaults` → `session_show_defaults` → `build_run_device`/`build_run_sim`, with no
intervening `exec_command`, shell/noop command, git command, plan update, status probe,
DebugBridge call, or unrelated tool. If an unrelated tool is accidentally called between these
steps, report the mistake as invalid evidence and restart the atomic chain from
`session_set_defaults`. Before starting the chain, confirm `session_set_defaults`,
`session_show_defaults`, and the resolver's `build_run_device`/`build_run_sim` are actually
callable in the current agent turn; if any is not callable, stop and report that XcodeBuildMCP was
not callable — do not guess tool names, use shell builds, or call any unrelated tool as a
substitute.

Runtime target policy. The launch target is either a wired physical device or an iOS Simulator,
chosen explicitly by the user, the project profile, or the active XcodeBuildMCP profile. Once a
target (with its `deviceId`/simulator id) is chosen for the session, it is fixed: a launch/connect
failure must be reported as a blocker and must not silently fall back to the other target kind or
to a different device. A Simulator is a valid target only when explicitly chosen up front; it must
never be used as an unconfirmed fallback after a physical-device failure, and vice versa.

Xcode target resolution. Before calling `session_set_defaults`, resolve the project target from
`<app-root>/.xcodebuildmcp/config.yaml` (the single source of truth that XcodeBuildMCP 2.x itself
reads at MCP startup). Run `bash /path/to/devflow/scripts/dev-flow.sh xcode-target` to parse
`sessionDefaults`, resolve relative paths, validate required fields, and output bounded JSON
fields for `session_set_defaults`. The resolver never auto-scans for devices; if the config is
missing, a required field is absent, or the project path does not match the app root, it reports
`blocked` with the exact reason — the agent must then ask the user or explicitly discover a
target. Only when the resolver is `blocked`, the config is stale, or the user explicitly switches
targets should the agent discover or ask for a device. Do not read `~/.xcodebuildmcp/config.yaml`
as a project truth source.

0. Confirm the required XcodeBuildMCP tools are actually callable in the current agent turn before
   starting the atomic chain. The matching launch action comes from the resolver's `launch_action`:
   - physical target (`target_kind=physical`, `launch_action=build_run_device`): the callable tools
     must include `session_set_defaults`, `session_show_defaults`, and `build_run_device`.
   - simulator target (`target_kind=simulator`, `launch_action=build_run_sim`): the callable tools
     must include `session_set_defaults`, `session_show_defaults`, and `build_run_sim`.
   If these tools are not callable in the current agent turn, stop and report that XcodeBuildMCP was
   not callable. Do not continue with shell commands, placeholder function names, or guessed
   namespaces, and do not call any unrelated tool as a substitute.
1. Call the XcodeBuildMCP `session_set_defaults` to isolate/seed the active profile for
   this worktree before reading or building. Pass `profile=<current session id>`
   (`DEV_FLOW_SESSION_ID`, then `CODEX_THREAD_ID`, then `CURSOR_CONVERSATION_ID`; never `local`
   inside Cursor) and `createIfNotExists=true`, and set the project target fields from the
   resolver's `profile` output: `workspacePath` (`.xcworkspace` for CocoaPods projects) or
   `projectPath`, `scheme`, `configuration`, `platform`, and the explicit `deviceId`/`simulatorId`
   chosen for this session. If the resolver is `blocked`, ask the user or explicitly discover a
   target; do not auto-scan. An active profile that is initially empty is not, by itself, a stop
   condition, because `session_set_defaults` is the legitimate action that fills it.
2. Call the XcodeBuildMCP `session_show_defaults` to read back the active profile and
   verify it before the first build/run/test call in the session.
3. Verify the active profile, not a guessed path. The profile must contain the intended
   `workspacePath`/`projectPath`, `scheme`, `configuration`, `platform`, and the `deviceId`/
   `simulatorId` of the chosen target.
4. For CocoaPods projects, `workspacePath` must point to the `.xcworkspace`; never use the sibling
   `.xcodeproj` for build, install, launch, DebugBridge bootstrap, or runtime verification.
5. If the active profile is missing required target fields after `session_set_defaults`, stale,
   uses the wrong workspace/project, has no `deviceId`/`simulatorId`, or points to `.xcodeproj`
   for a CocoaPods app, stop immediately and report the exact profile field that must be fixed.
   Do not keep trying alternative paths, do not run a shell `xcodebuild`, and do not silently
   switch to the other target kind or a different device as a workaround.
6. After the profile is verified, call the XcodeBuildMCP launch action matching the resolver's
   `launch_action`: `build_run_device` for a physical device (`target_kind=physical`), or
   `build_run_sim` for a Simulator (`target_kind=simulator`). Pass
   `env.DEV_FLOW_SESSION_ID=<current session id>` to the launched app. Do not call
   `build_device`/`install_app_device`/`launch_app_device` or `build_sim`/`install_app_sim`/
   `launch_app_sim` separately unless the combined `build_run_*` action is not callable in the
   current agent turn and that blocker is reported first.

If a flow rule, script, or project profile appears wrong, dev-flow must raise the process problem to
the user instead of silently attempting a workaround that wastes time or produces invalid evidence.

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
- The app repo gets only `.dev-flow/` session state plus XcodeBuild / DebugBridge install manifests
- Installs [XcodeBuildMCP](https://github.com/getsentry/XcodeBuildMCP): merges MCP config with `device`, `session-management`, and `project-discovery` workflows; writes `<app>/.xcodebuildmcp/config.yaml`
- Installs [UI-dbugbridge-mcp](https://github.com/Immmmmmortal1/UI-dbugbridge-mcp): Mac MCP server + LookDebugBridge Pod wiring when a Podfile exists
- Prompts for review backend: `agent/openai-reviewer`, [orchestrator-mcp](https://github.com/Immmmmmortal1/orchestrator-mcp), or `skill/gstack`; use `--review-backend agent/openai-reviewer|mcp/orchestrator|skill/gstack` non-interactively (v1 aliases: `reviewer|orchestrator|gstack`). Non-interactive installs without CLI, environment, or existing configuration fail closed
- After install, if reloading is needed, ask the user to restart the MCP host; dev-flow must not
  close or restart the active MCP connection on its own
- After install, if `pod_changed` in `.dev-flow/debugbridge-install.json`: run `pod install`, add Debug bootstrap from `.dev-flow/debugbridge-app-bootstrap.swift.snippet`
- Verify with: `bash <devflow-root>/scripts/dev-flow.sh doctor` from the app root


| Route / condition | Required skill | Owns |
|---|---|---|
| Every task | `code-grounded` | evidence, scope, classification |
| Post-confirm gate before implementation / commit flow | `environment-health-check` | App launch preflight on the chosen target plus DebugBridge, 审查角色（@openai-reviewer）, and `figma-rest-api` availability; required capabilities derived from `required_gates` |
| `feature` | `feature-workflow` | feature analysis and execution plan |
| `bug` | `bug-workflow` | bug analysis and repair plan |
| Stateful behavior | `requirements-closure` | closed state chain and requirements artifact |
| Localized copy | `localization-workflow` | locale matrix, translations, exceptions, validation |
| API-driven behavior | `api-contract` | field → business state → UI mapping |
| New Figma UI in `feature` | `figma-ui-gates` | Rules/scripts/tests are self-contained; runtime depends on Figma REST, DebugBridge, XcodeBuildMCP, and the project's `build` configuration; configurable reviewers; runtime geometry evidence; simulator or device (default simulator) |
| Existing UI parity | `ui-review` | Whole-page G2-equivalent split hard gate (`--stage split`) → all-unit live compare → baseline → human-authorized repair → live re-verify → acceptance |
| After `ui_review` source repairs | `code-review-workflow` → `ui-parity-review` | post-fix 审查角色 review on authorized diffs only |
| Real-device validation | `runtime-debug-workflow` | XcodeBuildMCP, DebugBridge, logs, runtime evidence |
| Review after source edits | `code-review-workflow` + selected route | 审查角色 base capability and review criteria |
| Bug historical check | `zentao-bug-gate` when required | ZenTao id and resolution |
| Before commit | `commit-gate` | commit authorization and scope |

Read the selected skill at the point where its route activates. Do not copy its detailed
procedures into this file.

## Orchestration

### 0. Enter and isolate the session

Read `code-grounded`, then start the task-scoped mechanical gate:

```bash
bash scripts/dev-flow-session.sh start --type bug|feature|ui_review --level trivial|standard|heavy --task "short label"
```

Task level (`--level`, only meaningful for `start`):

- `trivial` — 文档 / pod-patch 修补专用 fast-path；`required_gates=[]`（环境门四项 not-required 且 overall available）；**禁止 `configure-gates`**；必须带 `--trivial-kind docs|pod-patch`，pod-patch 还需 `--dependency NAME --from-version x.y.z --to-version x.y.z`；不走独立 review/ticket/review-health/App/DebugBridge/Figma，但仍需 confirm-plan → environment-health → `validate-trivial` → approve-commit → commit。
- `standard` — 默认；`required_gates=[review]`，普通 feature/bug。
- `heavy` — 新 Figma UI / `ui_review`；需手动 `configure-gates` 加 `runtime`/`figma_ui`/`ui_parity`，环境门相应能力必需。

环境健康检查的必需能力从会话的 `required_gates` 派生：standard/heavy 默认 `review` 必需；trivial fast-path `required_gates=[]` 使四项全部 `not-required` 且 overall `available`。非必需项在报告中标记为 `not-required` 且不参与最终 `available` 判定。

双层规则机制（不依赖 AI 记忆，门禁脚本强制执行）：

- 全局规则：`rules/global-rules.md`（中央仓库，git 版本化）；项目规则：`<项目>/.dev-flow/rules.md`（项目私有，start 时自动创建空模板）。
- `start` / `read-rules` 把两份规则全文打印到 stdout 并在 state 记录 `rules.{global,project}.{path,sha256,read_at}`；全局规则缺失时 `start` 直接失败。
- 所有写 state 的门禁 action（`configure-gates`/`environment-health`/`record-gate`/`confirm-plan`/`approve-commit`）前置校验项目规则 sha256，与 state 记录不符即失败；成功后把项目规则全文回带到 stdout（>4KB 截断并警告）。
- `approve-commit` 额外校验全局规则 sha256，构成闭环。规则文件修改后必须先运行 `read-rules` 刷新记录再继续门禁操作。

The script must isolate state by `DEV_FLOW_SESSION_ID`, then `CODEX_THREAD_ID`, then
`CURSOR_CONVERSATION_ID`. Outside Cursor it may fall back to `local`; inside Cursor
(`CURSOR_AGENT=1`) a missing conversation id is an error and must not reuse shared `local.json`.
It must support `status`, `confirm-plan`, `approve-commit`, and `end`. Never bypass a missing gate
or read another task's session state.

It must also support `environment-health --report <path>`. `confirm-plan` no longer requires
environment health; after confirmation, `record-gate`, `approve-commit`, `commit`, and `testflight`
must reject sessions whose recorded environment status is not `available` (and `checked_at` must be
non-empty). `environment-health` itself may run after `confirm-plan`.

Trivial fast-path (`--level trivial --trivial-kind docs|pod-patch`) writes `required_gates=[]`
(`schema_version: 2`, `fast_path: true`); it does not require independent review, ticket,
review-health, App launch, DebugBridge, or Figma — environment health reports all four checks
`not-required` with overall `available`. It must still run `confirm-plan` → `environment-health`
→ stage changes → `validate-trivial` → `approve-commit` → `commit`. `validate-trivial` records
HEAD, index tree, per-file path/mode/type/content digest, and the validator result; `approve-commit`
and `commit` recompute and reject on drift. Out-of-scope staged changes mark the session
`requires-standard`/`requires-heavy` and freeze it (no approve/commit, no in-place conversion,
no inherited evidence).

For standard/heavy sessions, every session requires the `review` gate by default. Before
confirmation, configure conditional gates when the task needs them (heavy-gate sessions must be
started with `--level heavy`):

```bash
# feature 带新 Figma UI（heavy）
bash scripts/dev-flow-session.sh configure-gates --required review,figma_ui,runtime
# ui_review 源码修复（heavy）
bash scripts/dev-flow-session.sh configure-gates --required review,runtime,ui_parity
```

After each gate completes, record its bounded result in the same session:

```bash
bash scripts/dev-flow-session.sh record-gate --name figma_ui|review|runtime --report <path>
```

`figma_ui` is accepted only when every gate in the `figma-ui-gates` sequence passes, including
`preflight` and `G6V`; `review` is accepted only when its
route result is `pass`; `runtime` is accepted only as `runtime-verified`.

### 1. Classify the route

Classify exactly one first-class route:

- New capability or new Figma screen → `feature`.
- Defect or regression → `bug`.
- Existing screen Figma parity review → `ui_review`.

`ui_new` is not a session type or first-level route. A `feature` with new Figma UI activates
`figma-ui-gates` only after the requirements and confirmation gates.

### 2. Activate conditional skills

Activate only when evidence requires them:

- Stateful interaction, business state, fallback, or behavior-changing copy → `requirements-closure`.
- Localized copy, locale files, translations, or same-string exception → `localization-workflow`.
- Endpoint, response field, server-driven behavior, or status mapping → `api-contract`.
- Bug fix with ZenTao requirement → `zentao-bug-gate`.
- New Figma UI → defer `figma-ui-gates` until after `confirm-gate`.
- Real iOS device build, operation, inspection, or logs → `runtime-debug-workflow`.

### 3. Close requirements before coding

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

### 4. Confirm the implementation scope

Read `confirm-gate` and wait for explicit user confirmation. Then run:

```bash
bash scripts/dev-flow-session.sh confirm-plan --task "short label"
```

No source edits, including diagnostic logging, are allowed before this command. A read-only
`ui_review` evidence pass (Structure + Group reviews with no edits) may finish without
`confirm-plan`; after the whole-page parity result is complete, the first authorized repair requires
workspace-level `parity-confirmed.json` plus `confirm-plan` once.

### 5. Run the environment health gate

After `confirm-plan` and before implementation, read `environment-health-check`. This gate
does not participate in route classification and must not change the selected route. The
environment gate is deferred to this point on purpose: classification, planning, and
confirmation do not require a live device; the gate must be `available` before any source
edit, gate recording, commit approval, commit, or TestFlight.

Run the executable check for the current session from the **devflow clone**, with the app repo as
project root:

```bash
cd <app-root>
bash /path/to/devflow/scripts/dev-flow.sh doctor
bash /path/to/devflow/scripts/dev-flow.sh app-launch status
bash /path/to/devflow/scripts/dev-flow.sh environment-health run
```

If `app-launch status` is blocked, stop and complete the App launch preflight on the chosen target
(physical device or Simulator) before the health check:

```bash
bash /path/to/devflow/scripts/dev-flow.sh app-launch instructions
# XcodeBuildMCP: confirm session_set_defaults / session_show_defaults / build_run_device|build_run_sim are callable, then:
# call session_set_defaults profile=<current session id> createIfNotExists=true with
#   workspacePath (.xcworkspace for CocoaPods), scheme, configuration, platform=iOS,
#   and the explicit deviceId (physical UDID) or simulatorId (Simulator id) chosen for this session.
# Then call session_show_defaults and verify the active profile fields.
# If any field is wrong or missing after set_defaults, stop and report it; do not guess paths.
# Then call build_run_device (wired) or build_run_sim (Simulator) with env DEV_FLOW_SESSION_ID=<current session id>.
bash /path/to/devflow/scripts/dev-flow.sh app-launch record --report <bounded-xcodebuildmcp-json|->
bash /path/to/devflow/scripts/dev-flow.sh app-launch status
```

App 运行必须遵守 fail-fast 顺序（目标可以是物理真机或显式指定的模拟器，选定后不得更换）：

1. 先确认当前轮可调用的 XcodeBuildMCP 工具包含 `session_set_defaults`、`session_show_defaults` 和 `build_run_device`（物理真机）或 `build_run_sim`（模拟器，依 resolver 的 `launch_action`）；如果其中任一不可调用，立即报告 XcodeBuildMCP 不可调用，不得改用 shell、占位函数或猜测命名空间，也不得调用任何无关工具替代。
2. 再调用 XcodeBuildMCP `session_set_defaults`（`profile=<current session id>`、`createIfNotExists=true`，并写入 workspace/scheme/configuration/platform/deviceId（物理真机）或 simulatorId（模拟器））；随后调用 `session_show_defaults` 读回 active profile 确认目标字段正确，再在选定目标上完成 `build_run_device`（wired）或 `build_run_sim`（simulator），确认 App 已安装并启动。
3. App 启动后立即对同一目标、同一 App、同一 dev-flow session 执行一次 DebugBridge 连通性检查。
4. 若连接、构建、签名、安装或启动失败，立即停止，不进入 UI 操作和业务验收，并记录首个可行动错误；不得把目标失败转换为通过。
5. 若 DebugBridge 不可达、身份不匹配或 ping 失败，立即停止后续 UI 检查、点击、日志验收和提交流程；将当前环境记录为 `debugbridge=blocked`，运行结果记录为 `runtime-blocked`。
6. 不得使用无效路径、`.xcodeproj`、shell `xcodebuild`、未确认的切换模拟器/换设备、反复扫描端口或截图/系统日志来把连接失败转换为通过。只有 DebugBridge 连通后，才允许继续运行时 UI 操作、视图树检查和当前运行日志校验。

这条规则是 App 运行的硬门禁，必须写入当前 dev-flow session 的环境/运行证据；连接失败后本轮在该门禁结束，不得继续提交。

Gate scripts live only in the devflow git clone. App repos keep `.dev-flow/sessions/` state only.
Initialize once with `dev-flow-init-project.sh <app-root>` after clone; `git pull` devflow updates
every project automatically without per-app script copies.

The command writes the results into `.dev-flow/sessions/<session-id>.json`. It exits non-zero
when any required capability is unavailable.

required capabilities are derived from the session's `required_gates` (not the session level):

| gate | required capabilities |
|---|---|
| `review` | `review_mcp` |
| `runtime` | `app_launch`, `debugbridge` |
| `figma_ui` | `app_launch`, `debugbridge`, `figma_rest_api` |
| `ui_parity` | `app_launch`, `debugbridge`, `figma_rest_api` |

`review` is required for every **standard/heavy** session. A legitimately trivial
fast-path session (schema_version=2, `level=trivial`, `fast_path=true`, valid
`trivial.kind`, and `required_gates=[]`) is the only exception: it requires no
gates and all four capabilities are `not-required`. Empty `required_gates` is
**not** auto-accepted on its own — the session must cross-match all trivial
fields; a non-trivial session with explicitly empty `required_gates`, a missing
`review` gate, or self-inconsistent trivial fields fails closed (no `available`,
no approve). non-required capabilities are recorded as `not-required` and do
not participate in the overall status. Pure dev-flow / script / documentation
tasks that do not touch App, Figma, or DebugBridge require only `review` and do
not need App launch, DebugBridge, or `figma-rest-api`. If any required result is
`blocked` or `not-run`, stop before implementation, gate recording, commit
approval, commit, or TestFlight, and report the exact environment blocker. Do
not use a route-specific fallback to bypass this gate, except the built-in
审查角色 → `gstack-review` (`/review`) fallback recorded by
`scripts/review-health-probe.sh`.

### 6. Implement or review

- `feature`: implement only the approved plan. If it includes new Figma UI, read
  `figma-ui-gates` now and complete its gate sequence in order:
  `preflight → G0 → G1 → G2 → G3 → G4 → G5 → G6 → G7 → G8 → G6V → G7A → G7B → G9 → G10 → G11 → G12`.
  `FIGMA_UI_GATES_DIR` means the `figma-ui-gates` skill root directory, defaults to
  `<devskills>/figma-ui-gates`, and may be overridden by the environment variable of the same name.
  Inside `figma-ui-gates` documentation, `${SKILL_DIR}` is equivalent to
  `${FIGMA_UI_GATES_DIR}`. Resolve its own rules and scripts from `${FIGMA_UI_GATES_DIR}`: node gates use the configured
  reviewer (default `self`), G11 uses the configured final reviewer (default `subagent`), runtime
  is `simulator | device` (default simulator), and G10 is geometry parity with no screenshot evidence.
  Its rules, scripts, and tests are self-contained; runtime execution depends on Figma REST,
  DebugBridge, XcodeBuildMCP, and the target project's resolved `build` configuration.
- `bug`: implement only the approved repair plan.
- `ui_review`: read `ui-review` and execute its pipeline in this order: Step1 whole-page
  **G2-equivalent hard gate** (recursive detail + real 审查角色 evidence; pass
  `validate-ui-review-artifacts --stage split`; do not hardcode the unit index or bundle
  parity writes) → only then live-compare **every minimum unit** → freeze the baseline → obtain
  workspace-level `parity-confirmed.json` → repair authorized units one at a time with live
  verification → obtain `repair-accepted.json`. Do not edit any Group before the whole-page
  comparison and human authorization are complete. After source repairs, call
  `code-review-workflow` with route `ui-parity-review` (post-fix only).
- When the task needs on-device runtime evidence, delegate the full runtime loop to
  `runtime-debug-workflow`. Accept only `runtime-verified`, `runtime-failed`, or
  `runtime-blocked`; never convert missing evidence into a pass.

### Runtime rendering inspection rule

Whenever the task requires checking the rendered UI state—on either a physical device or an iOS
Simulator—use DebugBridge as the only inspection path. Read the live view hierarchy, runtime nodes,
and any required app logs through DebugBridge. A screenshot may supplement the tree as supporting
context for non-parity tasks, but it is never sufficient evidence on its own; screenshots may not
replace DebugBridge inspection, and in `ui_review` tasks screenshots are prohibited entirely.
opened, or used as a fallback for a DebugBridge inspection failure; report the DebugBridge blocker
instead.

对物理设备执行渲染检查时，必须先完成“真机 App 已启动 → DebugBridge ping 成功”两步前置检查。
任一步失败都必须立即返回 `runtime-blocked`，记录到当前 session，并停止后续页面读取、点击、日志
查询和提交；不得降级到模拟器或其他非 DebugBridge 检查路径。

### 7. Review source changes

After source edits, read `code-review-workflow` and select a route from `routes/index.md`. The base
skill owns 审查角色（@openai-reviewer）availability, compact packet construction, reviewer dispatch,
and pre-dispatch `gstack-review` fallback selection. When the session is in fallback mode
(environment evidence `fallback=gstack-review`), run `bash scripts/run-review-fallback.sh` and
review **yourself** per the injected gstack workflow — never a sub-agent; the report must set
`review_path=fallback` or `record-gate` rejects it. Post-dispatch fallback switching is prohibited:
once dispatch has begun, `timeout`/`missing`/`error`/`blocked`/`revise` must be recorded as-is
and the review stops — never switch to a different adapter. The selected route owns review
criteria, finding decisions, validation, and the final `pass`, `blocked`, or revise result.

Only route `pass`, or residual risk explicitly accepted by the user and recorded by the route, may
continue. Timeout, missing result, or `blocked` is not a pass.

### 8. Complete route-specific post-gates

- Feature → run `bugkb` and record the post-implementation regression check.
- Bug → resolve through `zentao-bug-gate` when required.
- Feature with new Figma UI → record every gate in the `figma-ui-gates` sequence as pass,
  including `preflight` and `G6V`, before `record-gate --name figma_ui`. G6 is design-side asset
  declaration only; G6V runs after G8 and performs source-literal plus runtime-binding validation.
  Use `${FIGMA_UI_GATES_DIR}/scripts/validate-g6-asset-binding.sh`; do not use or maintain a
  devflow-local validator copy.
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

Only then may the exact approved scope be committed — through the commit gate itself (stages are
prepared by the agent with `git add`; the gate never auto-stages):

```bash
bash scripts/dev-flow-session.sh commit --message "中文提交信息"
```

`commit` requires a prior `approve-commit` and a non-empty staging area, runs `git commit` in the
project root, and records `commit_hash`/`committed_at` in the session. End the session with:

```bash
bash scripts/dev-flow-session.sh end
```

### 10. TestFlight（可选）

TestFlight 上传委托给各项目自己的 fastlane 脚本，dev-flow 只做门禁与证据登记。前置条件：
会话已 `commit` 且项目 HEAD 与该 commit 一致（防止带未提交漂移发布）。上传命令由项目配置在
`<项目>/.dev-flow/testflight-command`（如 `bundle exec fastlane beta`），未配置则 blocked 并
提示配置方法；执行结果（成功/失败、输出尾部证据）记入 session state。

```bash
bash scripts/dev-flow-session.sh testflight
```

版本号 bump 与 tag 推送由项目自己的 fastlane 脚本负责（见教训：发版必须 bump 版本并推 tag），
dev-flow v1 不侵入项目版本结构。

## Hard rules

1. No source edits before `confirm-gate` and `confirm-plan`.
2. Every first-class route must pass `environment-health-check` after `confirm-plan` and before
   implementation, gate recording, commit approval, commit, or TestFlight. Required capabilities
   are derived from the session's `required_gates`; non-required capabilities are `not-required`
   and do not participate in the overall status. standard/heavy sessions require `review` by
   default; trivial fast-path (`--level trivial --trivial-kind`) writes `required_gates=[]`, all
   four checks `not-required`, overall `available`, and does not need App launch, DebugBridge, or
   Figma. Old/missing-schema or non-trivial empty-`required_gates` sessions must not auto-pass;
   they fail closed and must re-open as standard/heavy.
3. A blocked or unrun environment check cannot be bypassed by selecting another route or fallback,
   except 审查角色 health may fall back to `gstack-review` (`/review`) through
   `scripts/review-health-probe.sh`.
4. No coding while the requirements artifact is `draft`, `pending-human-approval`, or `blocked`.
5. The approved requirements chain is authoritative; code, fallback, tests, and review cannot
   invent, remove, coerce, or silently reinterpret states.
6. Localization is incomplete until every required locale is mapped and validated.
7. Runtime claims require correlated UI action, inspected UI tree, and current-run App log evidence.
8. Rendered-state inspection on both physical devices and Simulators must use DebugBridge only;
   screenshots are never sufficient evidence on their own and are prohibited entirely in `ui_review` tasks.
8a. Physical-device runtime is fail-fast: App launch/connectivity failure or DebugBridge ping failure
    stops the run, records `runtime-blocked` and the environment blocker, and forbids UI actions,
    unconfirmed simulator fallback, port-scan retries, and commit continuation.
9. Review timeout, missing output, or `blocked` never becomes a pass.
10. No commit before every required gate is recorded in the current session with its passing
    status. Trivial fast-path (`required_gates=[]`) instead requires `validate-trivial` to pass
    and the scope digest to match at `approve-commit` and `commit` (no independent review gate);
    out-of-scope staged changes freeze the session as `requires-standard`/`requires-heavy`.
11. `figma_ui` requires every gate in the `figma-ui-gates` sequence to pass, including `preflight`
    and `G6V`, plus `g6v_validation=pass` with a bounded `g6v_validation_report`; `review` requires
    `pass`; `runtime` requires `runtime-verified`; and
    configured `ui_parity` requires `accepted` with matching authorization and acceptance reports.
    Failed, blocked, unknown, or missing results cannot be converted to pass.
11a. For `figma_ui`, G10 means runtime Geometry Parity only: compare numeric design/runtime
     geometry with configured tolerances. Screenshot, pixel-similarity, and pixel-sampling evidence
     cannot satisfy G10. Reviewer and runtime target selection come from the figma-ui-gates config;
     defaults are node review=`self`, final review=`subagent`, runtime target=`simulator`.
12. The selected review route and `commit-gate` must still approve the exact scope after the
    mechanical gate passes.
13. Mixed features, unrelated fixes, and formatting-only changes must be split into separate commits.
14. New Figma UI is a `feature` sub-route; `ui_new` must not be exposed as a first-level route.
15. Before every XcodeBuildMCP call, reread and follow `XcodeBuildMCP fixed invocation rule`: first
    confirm `session_set_defaults`, `session_show_defaults`, and the resolver's `build_run_device`/
    `build_run_sim` are actually callable in the current agent turn, then call `session_set_defaults`
    to seed the profile, call `session_show_defaults` to verify it, and call `build_run_device`/
    `build_run_sim` for launch on the chosen target (physical device or Simulator). This chain is
    atomic: no `exec_command`, shell/noop command, git command, plan update, status probe,
    DebugBridge call, or unrelated tool may be inserted between those steps. Missing
    callable tools, invalid paths, `.xcodeproj` for CocoaPods apps, shell `xcodebuild`, unconfirmed
    simulator/device fallback (silently switching targets after a failure), guessed tool calls, or
    interruption of the atomic chain are blockers and must be reported immediately.

## Flow

```text
classify
→ feature | bug | ui_review
→ requirements-closure? → localization-workflow? → api-contract? → zentao-bug-gate?
→ confirm-gate (required before first source edit)
→ environment-health-check [required capabilities available; non-required = not-required]
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
