# Dev Flow

`dev-flow` 是面向 iOS 开发的顶层路由与自动化门禁包：按任务类型进入固定流水线，用可机械校验的产物与脚本卡住捷径。

本仓库是 skill / 脚本的源码真相源（source of truth）。安装时通过 `scripts/link-global-skills.sh`（Codex）或 `scripts/link-cursor-skills.sh`（Cursor）链到本地 skills 目录。

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
bash scripts/dev-flow-session.sh start --type feature|bug|ui_review --task "short label"

# 环境四项：App 启动预检 + DebugBridge + Review MCP + figma-rest-api
bash scripts/environment-health-check.sh run

# 配置条件门禁后 confirm / approve-commit
bash scripts/dev-flow-session.sh configure-gates --required review,figma_ui,runtime
bash scripts/dev-flow-session.sh confirm-plan --task "short label"
bash scripts/dev-flow-session.sh approve-commit --task "short label"
bash scripts/dev-flow-session.sh end
```

Cursor 内禁止回退到共享 `local` session（见 `scripts/resolve-dev-flow-session-id.sh`）。

## 安装到本机 skills

```bash
# 1. 克隆 devflow，链 skills（Codex / Cursor）
bash scripts/link-global-skills.sh
bash scripts/link-cursor-skills.sh

# 2. 每个 iOS 工程只注册绑定（不复制 scripts/）
bash scripts/dev-flow-init-project.sh /path/to/YourApp

# 3. 在 App 根目录跑门禁（脚本始终从 devflow 仓执行）
cd /path/to/YourApp
bash /path/to/devflow/scripts/dev-flow.sh doctor
bash /path/to/devflow/scripts/dev-flow.sh session start --type bug --task "label"
# build_run_device 成功后：
bash /path/to/devflow/scripts/dev-flow.sh record-app-launch record
bash /path/to/devflow/scripts/dev-flow.sh environment-health run
```

**App 仓库里只有 `.dev-flow/` 状态目录，没有 gate 脚本副本。** 全团队共用一份 devflow clone。

`link-project-scripts.sh` 已废弃，等价于 `dev-flow-init-project.sh`。

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
