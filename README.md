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
7. 环境门禁前：`session_set_defaults` → `build_run_device`（有线真机）→ `dev-flow.sh record-app-launch record` → `dev-flow.sh environment-health run`
8. Figma token 用 `FIGMA_REST_TOKEN` 或 `FIGMA_ACCESS_TOKEN`

安装完成后日常命令（在 App 根目录）：

```bash
bash /path/to/devflow/scripts/dev-flow.sh session start --type bug --task "label"
bash /path/to/devflow/scripts/dev-flow.sh session start --type feature --level heavy --task "label"
bash /path/to/devflow/scripts/dev-flow.sh record-app-launch record
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

# 环境检查（按会话 level 裁剪必需项；非必需项 not-required，不参与判定）
bash scripts/environment-health-check.sh run

# 配置条件门禁后 confirm / approve-commit
bash scripts/dev-flow-session.sh configure-gates --required review,figma_ui,runtime
bash scripts/dev-flow-session.sh confirm-plan --task "short label"
bash scripts/dev-flow-session.sh approve-commit --task "short label"
bash scripts/dev-flow-session.sh end
```

Cursor 内禁止回退到共享 `local` session（见 `scripts/resolve-dev-flow-session-id.sh`）。

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
├── scripts/                 # 会话、环境、校验与测试
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
bash scripts/test-validate-g6-asset-binding.sh
bash scripts/test-validate-ui-review-artifacts.sh
bash scripts/test-ui-parity-gate.sh
```
