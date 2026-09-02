# Dev Flow

`dev-flow` 是面向 iOS 开发的顶层路由与自动化门禁包：按任务类型进入固定流水线，用可机械校验的产物与脚本卡住捷径。

## 安装（AI / 人类先看这里）

**从 devflow 仓库根目录执行一条命令即可。** Gate 脚本只留在 devflow clone 里，App 仓库里**不要**复制 `scripts/`。

```bash
cd /path/to/devflow
git pull
bash scripts/install-dev-flow.sh --project /path/to/YourApp
```

安装器会同时完成：

1. **dev-flow skills** → 链到 `~/.cursor/skills` 或 `~/.codex/skills`
2. **[XcodeBuildMCP](https://github.com/getsentry/XcodeBuildMCP)** → 写入 Cursor/Codex MCP 配置，启用 `device` / `session-management` / `project-discovery`；有 `--project` 时还会写 `<app>/.xcodebuildmcp/config.yaml`
3. **[UI-dbugbridge-mcp](https://github.com/Immmmmmortal1/UI-dbugbridge-mcp)** → Mac 侧 DebugBridge MCP（克隆/更新、`npm run build`、写入 Cursor/Codex MCP 配置）
4. **Review 后端（交互选择）** → `orchestrator-mcp` 或 `gstack-review`
   - **orchestrator-mcp**：[`Immmmmmortal1/orchestrator-mcp`](https://github.com/Immmmmmortal1/orchestrator-mcp)（独立 Review Hub MCP，需配置 API Key）
   - **gstack-review**：未安装时自动 shallow clone gstack 的 `/review` skill（非交互默认项）
5. **App 绑定** → 仅写 `<app>/.dev-flow/`（含 `xcodebuild-mcp-install.json`、`debugbridge-install.json`、`review-backend.json`、Pod 引导 manifest）
6. **LookDebugBridge Pod**（有 Podfile 时）→ 自动写入 Debug-only pod 行；**AI 仍需** `pod install` 并在 Debug 启动代码里加入 bootstrap snippet

- `--project`：iOS App 工程根目录（含 `.xcodeproj` / `.xcworkspace` 的那一层）
- 在 Cursor 里通常可写：`bash scripts/install-dev-flow.sh --project .`（当前 workspace 就是 App 时）
- 只装 skills、暂不绑 App：`bash scripts/install-dev-flow.sh --skills-only`
- 跳过 XcodeBuildMCP：`--skip-xcodebuild`
- 跳过 DebugBridge MCP：`--skip-debugbridge`
- 跳过 Review 安装：`--skip-review`
- 非交互指定 Review 后端：`--review-backend orchestrator|gstack`（默认 gstack）
- 自动跑 `pod install`：`--run-pod-install`（需本机已装 CocoaPods）
- 强制平台：`--cursor` 或 `--codex`（默认自动检测）

**AI agent 安装规则：**

1. 先 `git pull` devflow，再跑 `install-dev-flow.sh`，不要手抄 gate 脚本到 App 仓
2. App 仓只会多出 `.dev-flow/`（会话状态 + `source-root` + DebugBridge / Review manifest）
3. 安装时会提示选择 Review 后端；AI 可用 `--review-backend orchestrator` 或 `--review-backend gstack`
4. 若 `.dev-flow/debugbridge-install.json` 显示 `pod_changed: true`：在 App 仓执行 `pod install`，并把 `.dev-flow/debugbridge-app-bootstrap.swift.snippet` 加到 Debug 启动路径（如 `AppDelegate` / `@main` App）
5. 重启 Cursor/Codex MCP，使 `XcodeBuildMCP` / `ui_dbugbridge_mcp` / `orchestrator_mcp` 生效
6. 装完后在 App 根目录跑：`bash /path/to/devflow/scripts/dev-flow.sh doctor`
7. 环境门禁（confirm-plan 之后、实现之前）：`tool_search` → `session_set_defaults` → `session_show_defaults` → `build_run_device`（选定目标：有线真机或显式指定的模拟器）→ `dev-flow.sh app-launch record --report <bounded-xcodebuildmcp-json|->` → `dev-flow.sh environment-health run`
8. Figma token 用 `FIGMA_REST_TOKEN` 或 `FIGMA_ACCESS_TOKEN`

安装完成后日常命令（在 App 根目录）：

```bash
# 启动会话并分类（start 后先定位/出计划，再 confirm-plan）
bash /path/to/devflow/scripts/dev-flow.sh session start --type bug --task "label"
bash /path/to/devflow/scripts/dev-flow.sh session start --type feature --level heavy --task "label"
bash /path/to/devflow/scripts/dev-flow.sh session confirm-plan
# 计划确认后跑环境门禁（confirm-plan 之后、实现之前）
bash /path/to/devflow/scripts/dev-flow.sh app-launch instructions
bash /path/to/devflow/scripts/dev-flow.sh app-launch record --report <bounded-xcodebuildmcp-json|->
bash /path/to/devflow/scripts/dev-flow.sh environment-health run
```

## 任务复杂度分级（--level）

`session start` 支持 `--level trivial|standard|heavy`（默认 `standard`），决定环境门必需的检查项：

| level | 适用场景 | 环境门必需项 | 门禁限制 |
|---|---|---|---|
| `trivial` | 文案 / typo / 纯逻辑微调 | 仅 `review_mcp` | 仅 `review` 门；`configure-gates` 禁止加 `runtime`/`figma_ui`/`ui_parity` |
| `standard` | 普通 feature / bug | `app_launch` + `review_mcp` | 无 |
| `heavy` | 新 Figma UI / `ui_review` | 全 4 项 | 无 |

非必需检查项在环境报告中标记为 `not-required`，不参与最终 `available` 判定。旧 session（无 level 字段）按 `heavy` 全查兼容。

本仓库是 skill / 脚本的源码真相源（source of truth）。`install-dev-flow.sh` 会把 skills 链到本机 `~/.codex/skills` 或 `~/.cursor/skills`。

## 三条一等路由

| 路由 | 用途 | 关键 skill |
|---|---|---|
| `feature` | 新能力；含新 Figma UI 时走 G0–G12 | `feature-workflow` + 条件 `figma-ui-gates` |
| `bug` | 缺陷修复 | `bug-workflow` |
| `ui_review` | **已有页面**与 Figma 的整页 parity 校对与授权修复 | `ui-review` |

入口说明见根目录 [`SKILL.md`](./SKILL.md)。

## Figma UI Gates（新 UI）

新 Figma 界面属于 `feature` 的条件子路由，**不是**独立一等路由。

**独立仓库（真相源）：** [Immmmmmortal1/figma-ui-gates](https://github.com/Immmmmmortal1/figma-ui-gates)

本仓仅通过 `skills/figma-ui-gates/SKILL.md` **符号链接**到并列目录 `../figma-ui-gates/SKILL.md`，便于 `link-*-skills.sh` 安装；请勿再把全文嵌进本仓。

顺序（不可跳过 / 不可手写“已通过”）：

```text
preflight → G0…G12（含 G6 资产边界与机械绑定校验）
```

产物工作区（目标工程内，应被目标仓 ignore）：

```text
.dev-flow/ui/by-url/<sanitized-canonical-figma-url>/
├── manifest.json
├── preflight.json
├── gates/
├── figma/
├── reviews/
├── runtime/
└── …
```

### G6 资产绑定机械校验

在 G6 之后、宣称绑定完成前执行：

```bash
bash scripts/validate-g6-asset-binding.sh \
  --workspace <artifact-workspace> \
  --source-root <target-project-root> \
  [--report <path>]
```

自测：

```bash
bash scripts/test-validate-g6-asset-binding.sh
```

## UI Review（已有页 parity）

已有屏校对合同在：

- [`skills/ui-review/SKILL.md`](./skills/ui-review/SKILL.md)

强制顺序：

```text
Step1 整页 G2 等价硬门禁（递归 detail + 真实 Review MCP 证据）
  → validate --stage split
Step2 全量 minimum-unit live-compare（DebugBridge）
  → 冻结 baseline
Step3 人工 parity-confirmed.json + 授权修复 + 真机/模拟器复验
Step4 repair-accepted.json
  → 源码修复后走 ui-parity-review
```

### 产物校验

```bash
bash scripts/validate-ui-review-artifacts.sh \
  --workspace <artifact-workspace> \
  --session-id <dev-flow-session-id> \
  --stage split|parity|repair|all
```

`--stage split` 会拒绝：

- 硬编码 / 非 detail 汇总的 `minimum-unit-index`
- 缺少真实 Review MCP `run_id` + `verdict` 的 structure/detail review
- 含可本地化文案却被 collapse 成 `image` 的 unit

自测：

```bash
bash scripts/test-validate-ui-review-artifacts.sh
```

### Compare rules（label / button / image）

`unit_kind` 分类与验收标准的**唯一来源**是 `skills/ui-review/SKILL.md` 中的
**Compare rules** 段（`text` / `button-text` / `button-image` / `button-text-icon` / `image`）。
Step1 分类、Step2 比对、Step3 修复复验都必须引用该段，不得另写一套。

## 会话与环境门禁

```bash
# 启动（按 DEV_FLOW_SESSION_ID → CODEX_THREAD_ID → CURSOR_CONVERSATION_ID 隔离）
bash scripts/dev-flow-session.sh start --type feature|bug|ui_review --level trivial|standard|heavy --task "short label"

# 配置条件门禁后 confirm-plan（start → 分类/计划 → confirm；confirm 不要求环境门禁）
bash scripts/dev-flow-session.sh configure-gates --required review,figma_ui,runtime
bash scripts/dev-flow-session.sh confirm-plan --task "short label"

# 环境检查在 confirm-plan 之后、实现之前跑（按会话 level 裁剪必需项；非必需项 not-required，不参与判定）
bash scripts/environment-health-check.sh run

# 环境门禁 available 后 approve-commit / commit
bash scripts/dev-flow-session.sh approve-commit --task "short label"

# 收口提交（需 approve 已批 + 暂存区非空；记录 commit hash）
bash scripts/dev-flow-session.sh commit --message "中文提交信息"

# TestFlight（可选；需 commit 完成且 HEAD 未漂移；命令配置在 .dev-flow/testflight-command）
bash scripts/dev-flow-session.sh testflight

bash scripts/dev-flow-session.sh end
```

Cursor 内禁止回退到共享 `local` session（见 `scripts/resolve-dev-flow-session-id.sh`）。

## 双层规则机制

不靠 AI 记忆，由门禁脚本强制规则进入上下文：

- **全局规则** `rules/global-rules.md`（本仓库，git 版本化）；**项目规则** `<项目>/.dev-flow/rules.md`（项目私有，`start` 自动创建空模板）。
- `start` / `read-rules` 全文打印两份规则到 stdout 并记录 `sha256`；全局规则缺失时 `start` 失败。
- 每个写 state 的门禁 action 前置校验项目规则 `sha256`，变更即失败；成功后回带项目规则全文（>4KB 截断警告）。
- `approve-commit` 额外校验全局规则 `sha256`。规则文件改后先 `read-rules` 再继续：

```bash
bash scripts/dev-flow-session.sh read-rules
```

## review_mcp 不可用时的 gstack-review fallback

环境门探针检测到 orchestrator MCP 不可用时，会话进入 fallback 模式（证据
`fallback=gstack-review`）。此时审查**必须**走机械入口，禁止开子 Agent / 宿主审查 agent：

```bash
bash scripts/run-review-fallback.sh   # [--route code-quality-review]
```

runner 校验会话处于 fallback 模式后，签发一次性 `fallback_token` + `packet_digest` 记入
session state，并把审查指令、gstack review SKILL.md、route 契约、bounded 审查包
（merge-base → 工作区含 staged/unstaged/untracked，>4000 行退化 stat）+ 报告模板全部注入
stdout。AI 按注入流程亲自审查，把报告写到 runner 指定路径（含 token/digest/
`review_path=fallback`），然后 `record-gate --name review` 收口——record-gate 强制校验
token/digest/报告路径三件套 + route 一致 + gstack skill/route 契约签发后未被修改，
`pass` 收录后销毁 token。不跑 runner 手写的 fallback 报告会被拒收。

## 安装到本机 skills

推荐统一入口（见 README 顶部 **安装** 一节）：

```bash
bash scripts/install-dev-flow.sh --project /path/to/YourApp
```

等价于依次执行 skills 链接 + app 绑定 + doctor。手动分步：

```bash
bash scripts/link-global-skills.sh    # Codex
bash scripts/link-cursor-skills.sh    # Cursor
bash scripts/dev-flow-init-project.sh /path/to/YourApp
```

**App 仓库里只有 `.dev-flow/` 状态目录，没有 gate 脚本副本。**

## 目录结构

```text
devflow/
├── SKILL.md                 # 路由与编排合同
├── README.md                # 本说明
├── rules/
│   └── global-rules.md      # 全局规则（start/read-rules 打印，门禁 hash 校验）
├── scripts/                 # 会话、环境、校验与测试
│   ├── lib/
│   │   ├── dev-flow-paths.sh
│   │   └── dev-flow-rules.sh   # 双层规则机制共享函数
│   ├── validate-g6-asset-binding.*
│   ├── validate-ui-review-artifacts.*
│   ├── fixtures/            # 校验器夹具
│   └── test-*.sh
└── skills/
    ├── figma-ui-gates/      # 符号链接 → 独立仓 ../figma-ui-gates
    ├── ui-review/           # 已有页 parity
    └── …                    # 其它条件 / 门禁 skill
```

并列克隆示例：

```text
devskills/
├── devflow/              # 本仓
└── figma-ui-gates/       # https://github.com/Immmmmmortal1/figma-ui-gates
```


## 渲染态检查约定

无论真机还是模拟器，渲染态检查只走 **DebugBridge**（层级 / runtime node / 日志）。
禁止用截图或看图作为证据或失败回退。

## 开发自测建议

在改动门禁脚本或 validator 后至少跑：

```bash
bash scripts/test-gate-enforcement.sh
bash scripts/test-dev-flow-session-isolation.sh
bash scripts/test-rules-gate.sh
bash scripts/test-validate-g6-asset-binding.sh
bash scripts/test-validate-ui-review-artifacts.sh
bash scripts/test-ui-parity-gate.sh
```

## 更新通知（飞书）

发版 / 打 tag 后，由 AI 或维护者显式执行通知脚本，把 devflow 更新通知推送到飞书群。

- **飞书 webhook 不入库**：脚本只从 `FEISHU_UPDATE_WEBHOOK` 环境变量读取；AI 执行时应从
  本机安全区 / 环境变量取值，绝不写入仓库、命令示例、日志或提交（教训 009）。
- 通知脚本：`scripts/notify-feishu-update.sh`（消息含仓库、版本、提交、触发者、构建链接）

发布后通知示例：

```bash
# 先由 AI / 维护者从安全区注入 FEISHU_UPDATE_WEBHOOK，避免真实 webhook 进入 shell history。
bash scripts/notify-feishu-update.sh \
  --repo Immmmmmortal1/devflow \
  --tag v0.1.1 \
  --sha "$(git rev-parse HEAD)" \
  --commit-url "https://github.com/Immmmmmortal1/devflow/commit/$(git rev-parse HEAD)" \
  --message "devflow 已发布 v0.1.1"
```

本地/CI 测试**必须**用假 webhook 覆盖，禁止直发生产群：

```bash
# 启动假飞书 server 并验证（缺 webhook 失败、请求结构正确、输出不泄露 webhook）
bash scripts/test-notify-feishu-update.sh

# 手动用假 webhook 跑一次（端口换成假 server 实际端口）
FEISHU_UPDATE_WEBHOOK=http://127.0.0.1:8000/ \
  bash scripts/notify-feishu-update.sh --repo owner/devflow --tag v1.0.0
```
