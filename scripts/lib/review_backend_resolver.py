#!/usr/bin/env python3
"""Review backend resolver — dev-flow 单一 adapter 选择真相源。

三层决策优先级（高→低）：
  1. CLI 显式参数（--adapter / DEV_FLOW_REVIEW_ADAPTER）
  2. 项目 <app>/.dev-flow/review-backend.local.json（schema v2）
  3. 用户 ~/.config/dev-flow/config.json host profile（schema v2）
  4. 仓库默认策略（本文件内 DEFAULT_POLICY）

稳定 adapter IDs：
  - agent/openai-reviewer
  - mcp/orchestrator
  - skill/gstack

v1 lazy 兼容：旧 .dev-flow/review-backend.json (schema v1) 的 backend 字段按映射迁移：
  reviewer → agent/openai-reviewer
  orchestrator → mcp/orchestrator
  gstack → skill/gstack
  未知 backend → fail closed。

config_digest = sha256(canonical_json({primary, fallback_policy, fallback_order, adapters}))
绑定 selection，dispatch 后配置变更则 digest 不匹配 → fail closed。

被 install-review-backend.sh / review-health-probe.sh / dev-flow-doctor.sh / record-gate 共用。

Usage:
  python3 review_backend_resolver.py resolve [--adapter ID] [--project-root PATH]
       [--user-config PATH] [--project-config PATH] [--host HOST]
  python3 review_backend_resolver.py validate --config-path PATH
"""
import hashlib
import json
import os
import sys
from pathlib import Path

# ── 稳定 adapter IDs ──
ADAPTER_AGENT = "agent/openai-reviewer"
ADAPTER_ORCH = "mcp/orchestrator"
ADAPTER_GSTACK = "skill/gstack"
KNOWN_ADAPTERS = (ADAPTER_AGENT, ADAPTER_ORCH, ADAPTER_GSTACK)

# v1 → v2 backend 迁移映射
V1_MIGRATION = {
    "reviewer": ADAPTER_AGENT,
    "orchestrator": ADAPTER_ORCH,
    "gstack": ADAPTER_GSTACK,
}

# 默认 adapter 配置（identifier / type）
DEFAULT_ADAPTERS = {
    ADAPTER_AGENT: {"type": "agent", "identifier": "openai-reviewer"},
    ADAPTER_ORCH: {"type": "mcp", "identifier": "orchestrator-mcp"},
    ADAPTER_GSTACK: {"type": "skill", "identifier": "gstack-review"},
}

# 仓库默认策略（committed default policy）
DEFAULT_POLICY = {
    "opencode": {
        "primary": ADAPTER_AGENT,
        "fallback_policy": "allow",
        "fallback_order": [ADAPTER_GSTACK],
    },
    "cursor": {
        "primary": ADAPTER_ORCH,
        "fallback_policy": "allow",
        "fallback_order": [ADAPTER_GSTACK],
    },
    "codex": {
        "primary": ADAPTER_ORCH,
        "fallback_policy": "allow",
        "fallback_order": [ADAPTER_GSTACK],
    },
}


# v2 配置顶层字段白名单
V2_TOP_LEVEL_FIELDS = frozenset({
    "schema_version", "host", "primary", "fallback_policy",
    "fallback_order", "adapters",
})

# adapter 对象字段白名单（按 type 区分）
ADAPTER_FIELDS_BY_TYPE = {
    "agent": frozenset({"type", "identifier", "config_path"}),
    "mcp": frozenset({"type", "identifier", "root"}),
    "skill": frozenset({"type", "identifier", "skill_path"}),
}
# 通用 adapter 字段（所有 type 共有）
ADAPTER_COMMON_FIELDS = frozenset({"type", "identifier"})
# 所有合法 adapter 字段（用于白名单校验）
ADAPTER_ALL_FIELDS = frozenset().union(*ADAPTER_FIELDS_BY_TYPE.values())


def fail_closed(reason, detail, **extra):
    """输出 blocked JSON 并退出 1。未知 backend / 未知字段影响决策时调用。"""
    payload = {"status": "blocked", "reason": reason, "detail": detail}
    payload.update(extra)
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    raise SystemExit(1)


def detect_host(cli_host=""):
    """检测宿主：CLI > DEV_FLOW_HOST > 明确宿主环境信号 > codex（保守）。

    不得用 ~/.config/opencode 是否存在来判断宿主——同机安装 OpenCode 目录
    不能让 Codex 误判。只有明确的宿主环境信号才算数。
    """
    if cli_host:
        return cli_host
    env_host = os.environ.get("DEV_FLOW_HOST", "").strip()
    if env_host:
        return env_host
    # 明确宿主环境信号（不是目录存在性）
    if os.environ.get("OPENCODE"):
        return "opencode"
    if os.environ.get("CURSOR_AGENT") == "1" or os.environ.get("CURSOR_CONVERSATION_ID"):
        return "cursor"
    # 无明确信号 → 保守 codex（交互向导会询问）
    return "codex"


def validate_adapter_id(adapter_id, context):
    """校验 adapter ID 是否已知，未知则 fail closed。"""
    if adapter_id not in KNOWN_ADAPTERS:
        fail_closed(
            "unknown_adapter",
            f"Unknown adapter ID in {context}: {adapter_id!r}. "
            f"Known adapters: {', '.join(KNOWN_ADAPTERS)}",
        )


def validate_adapter_object(adapter_id, adapter_cfg, source_label):
    """严格校验单个 adapter 对象：必须是 dict，按 type 白名单校验字段，type/identifier 匹配 adapter ID。

    字段白名单按 type 严格区分：agent 只允许 config_path，mcp 只允许 root，
    skill 只允许 skill_path。跨 type 字段（如 agent 携带 root）→ fail closed。
    """
    if not isinstance(adapter_cfg, dict):
        fail_closed(
            "adapter_not_object",
            f"{source_label}.adapters.{adapter_id} must be a JSON object",
        )

    # type 必须存在且匹配 adapter ID（先校验 type，再按 type 决定字段白名单）
    atype = adapter_cfg.get("type")
    if atype not in ("agent", "mcp", "skill"):
        fail_closed(
            "adapter_invalid_type",
            f"{source_label}.adapters.{adapter_id}.type must be 'agent', 'mcp', or 'skill' (got {atype!r})",
        )

    # 按 type 限定字段白名单（不允许跨 type 携带字段）
    allowed = ADAPTER_FIELDS_BY_TYPE.get(atype, frozenset())
    unknown = set(adapter_cfg.keys()) - allowed
    if unknown:
        fail_closed(
            "adapter_unknown_field",
            f"{source_label}.adapters.{adapter_id} (type={atype!r}) has fields not allowed for this type: {sorted(unknown)}. "
            f"Allowed for {atype}: {sorted(allowed)}",
        )

    # type 与 adapter ID 一致性校验
    expected_prefix = atype + "/"
    if not adapter_id.startswith(expected_prefix):
        fail_closed(
            "adapter_type_id_mismatch",
            f"{source_label}.adapters.{adapter_id}: type={atype!r} does not match adapter ID prefix "
            f"(expected {expected_prefix!r})",
        )

    # identifier 必须存在且非空字符串
    identifier = adapter_cfg.get("identifier")
    if not isinstance(identifier, str) or not identifier.strip():
        fail_closed(
            "adapter_missing_identifier",
            f"{source_label}.adapters.{adapter_id}.identifier must be a non-empty string",
        )

    # type-specific 字段类型校验
    type_specific = ADAPTER_FIELDS_BY_TYPE.get(atype, frozenset()) - ADAPTER_COMMON_FIELDS
    for field in type_specific:
        if field in adapter_cfg:
            val = adapter_cfg[field]
            if not isinstance(val, str) or not val.strip():
                fail_closed(
                    "adapter_invalid_field",
                    f"{source_label}.adapters.{adapter_id}.{field} must be a non-empty string",
                )


def validate_v2_config(config, source_label):
    """严格校验 schema v2 配置。未知顶层字段 / 未知 adapter 字段 / 类型不匹配均 fail closed。

    不静默 merge 默认值掩盖坏配置：如果用户写了 adapters 字段但格式不对，
    直接拒绝，不回退到 DEFAULT_ADAPTERS。
    """
    if not isinstance(config, dict):
        fail_closed("config_not_object", f"{source_label} config is not a JSON object")

    # 顶层字段白名单校验
    unknown_top = set(config.keys()) - V2_TOP_LEVEL_FIELDS
    if unknown_top:
        fail_closed(
            "unknown_top_level_field",
            f"{source_label} has unknown top-level fields: {sorted(unknown_top)}. "
            f"Allowed: {sorted(V2_TOP_LEVEL_FIELDS)}",
        )

    sv = config.get("schema_version")
    if sv != 2:
        fail_closed(
            "unsupported_schema_version",
            f"{source_label} schema_version must be 2 (got {sv!r})",
        )

    primary = config.get("primary")
    if not isinstance(primary, str) or not primary.strip():
        fail_closed(
            "primary_required",
            f"{source_label}.primary is required and must be a non-empty string. "
            "fallback_order cannot substitute for primary.",
        )
    validate_adapter_id(primary, f"{source_label}.primary")

    fallback_policy = config.get("fallback_policy")
    if fallback_policy is not None and fallback_policy not in ("allow", "deny"):
        fail_closed(
            "unknown_fallback_policy",
            f"{source_label}.fallback_policy must be 'allow' or 'deny' (got {fallback_policy!r})",
        )

    fallback_order = config.get("fallback_order")
    if fallback_order is not None:
        if not isinstance(fallback_order, list):
            fail_closed(
                "fallback_order_not_list",
                f"{source_label}.fallback_order must be an array",
            )
        for item in fallback_order:
            validate_adapter_id(item, f"{source_label}.fallback_order")

    adapters = config.get("adapters")
    if adapters is not None:
        if not isinstance(adapters, dict):
            fail_closed(
                "adapters_not_object",
                f"{source_label}.adapters must be an object",
            )
        for key in adapters:
            validate_adapter_id(key, f"{source_label}.adapters")
            # 严格校验每个 adapter 对象
            validate_adapter_object(key, adapters[key], source_label)


def migrate_v1(backend_value, source_label):
    """v1 backend → v2 adapter ID；未知 backend fail closed。"""
    if not isinstance(backend_value, str) or not backend_value:
        fail_closed(
            "v1_backend_empty",
            f"{source_label} v1 backend field is empty or not a string",
        )
    mapped = V1_MIGRATION.get(backend_value)
    if mapped is None:
        fail_closed(
            "unknown_v1_backend",
            f"{source_label} v1 backend {backend_value!r} is not a known backend. "
            f"Known v1 backends: {', '.join(V1_MIGRATION)}",
        )
    return mapped


def read_project_config(project_root, project_config_override):
    """读取项目级配置（v2 .local.json 优先，v1 .json lazy 兼容）。返回 (config, source, reason) 或 None。"""
    # v2 优先
    v2_path = project_config_override or ""
    if not v2_path and project_root:
        v2_path = str(Path(project_root) / ".dev-flow" / "review-backend.local.json")
    if v2_path and Path(v2_path).is_file():
        try:
            raw = json.loads(Path(v2_path).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            fail_closed("config_invalid_json", f"project config {v2_path}: {exc}")
        validate_v2_config(raw, f"project config ({v2_path})")
        return raw, "project", "project_config_primary"

    # v1 lazy 兼容
    v1_path = ""
    if project_root:
        v1_path = str(Path(project_root) / ".dev-flow" / "review-backend.json")
    if v1_path and Path(v1_path).is_file():
        try:
            raw = json.loads(Path(v1_path).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            fail_closed("config_invalid_json", f"project v1 config {v1_path}: {exc}")
        # v1 config 必须是 JSON object（dict）；array/string/number 等结构化 fail closed
        if not isinstance(raw, dict):
            fail_closed(
                "v1_config_not_object",
                f"project v1 config {v1_path} is not a JSON object (got {type(raw).__name__})",
            )
        sv = raw.get("schema_version")
        backend = raw.get("backend")
        if sv == 1 and backend:
            adapter_id = migrate_v1(backend, f"project v1 config ({v1_path})")
            return {
                "schema_version": 2,
                "primary": adapter_id,
                "fallback_policy": "allow",
                "fallback_order": [a for a in KNOWN_ADAPTERS if a != adapter_id],
                "adapters": dict(DEFAULT_ADAPTERS),
                "_migrated_from_v1": True,
                "_v1_path": v1_path,
            }, "project", "project_config_v1_migrated"

    return None


def read_user_config(user_config_override, host):
    """读取用户级配置（~/.config/dev-flow/config.json，支持 host profiles）。"""
    user_path = user_config_override or ""
    if not user_path:
        user_path = str(Path.home() / ".config" / "dev-flow" / "config.json")
    if not Path(user_path).is_file():
        return None

    try:
        raw = json.loads(Path(user_path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail_closed("config_invalid_json", f"user config {user_path}: {exc}")

    if not isinstance(raw, dict):
        fail_closed("config_not_object", f"user config {user_path} is not a JSON object")

    sv = raw.get("schema_version")
    if sv != 2:
        fail_closed(
            "unsupported_schema_version",
            f"user config {user_path} schema_version must be 2 (got {sv!r})",
        )

    # 支持 host profiles：hosts.<host> 优先，否则顶层平铺
    hosts = raw.get("hosts")
    if isinstance(hosts, dict) and host in hosts:
        profile = hosts[host]
        if not isinstance(profile, dict):
            fail_closed("host_profile_not_object", f"user config hosts.{host} is not an object")
        # 合并 schema_version
        profile = dict(profile)
        profile["schema_version"] = 2
        validate_v2_config(profile, f"user config hosts.{host}")
        return profile, "user", "user_config_primary"
    elif "primary" in raw:
        # 顶层平铺（单 profile）
        validate_v2_config(raw, f"user config ({user_path})")
        return raw, "user", "user_config_primary"

    return None


def compute_digest(selection_config):
    """计算 config_digest = sha256(canonical_json(决策影响字段))。"""
    digest_input = {
        "primary": selection_config.get("primary"),
        "fallback_policy": selection_config.get("fallback_policy"),
        "fallback_order": selection_config.get("fallback_order"),
        "adapters": selection_config.get("adapters"),
    }
    canonical = json.dumps(digest_input, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return "sha256:" + hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def resolve_agent_config_path(adapters):
    """统一 agent config path 优先级：显式环境变量 > adapter 持久化 config_path > 默认路径。

    若 DEV_FLOW_OPENCODE_CONFIG / OPENCODE_CONFIG 显式指定了路径，覆盖 adapter 中的 config_path，
    使 selection/digest 反映实际生效的路径。

    Args:
        adapters: adapters dict（会被原地修改）

    Returns:
        修改后的 adapters dict
    """
    env_oc_config = os.environ.get("DEV_FLOW_OPENCODE_CONFIG") or os.environ.get("OPENCODE_CONFIG") or ""
    if env_oc_config:
        agent_key = "agent/openai-reviewer"
        if agent_key in adapters and isinstance(adapters[agent_key], dict):
            adapters[agent_key]["config_path"] = env_oc_config
    return adapters


def merge_adapters(base, override):
    """合并 adapter 配置：override 补充/覆盖 base。不静默忽略未知 key。

    override 中的每个 key 必须是已知 adapter ID，且 value 必须是 dict（已在 validate_v2_config 校验）。
    不做"静默 merge 默认值掩盖坏配置"——如果 override 有问题，validate_v2_config 已 fail closed。
    """
    result = dict(base)
    if isinstance(override, dict):
        for key, val in override.items():
            if key in KNOWN_ADAPTERS and isinstance(val, dict):
                # 合并：以 override 的字段补充/覆盖 base 的默认字段
                merged = dict(result.get(key, {}))
                merged.update(val)
                result[key] = merged
    return result


def cmd_resolve(args):
    """执行 resolve：三层优先级 → 输出 selection JSON。"""
    cli_adapter = ""
    cli_host = ""
    project_root = ""
    user_config = ""
    project_config = ""
    i = 0
    while i < len(args):
        if args[i] == "--adapter" and i + 1 < len(args):
            cli_adapter = args[i + 1]
            i += 2
        elif args[i] == "--host" and i + 1 < len(args):
            cli_host = args[i + 1]
            i += 2
        elif args[i] == "--project-root" and i + 1 < len(args):
            project_root = args[i + 1]
            i += 2
        elif args[i] == "--user-config" and i + 1 < len(args):
            user_config = args[i + 1]
            i += 2
        elif args[i] == "--project-config" and i + 1 < len(args):
            project_config = args[i + 1]
            i += 2
        else:
            fail_closed("invalid_argument", f"Unknown argument: {args[i]}")

    # env var 覆盖（用于测试）
    if not project_root:
        project_root = os.environ.get("DEV_FLOW_PROJECT_ROOT", "")
    if not user_config:
        user_config = os.environ.get("DEV_FLOW_USER_CONFIG_PATH", "")
    if not project_config:
        project_config = os.environ.get("DEV_FLOW_PROJECT_CONFIG_PATH", "")
    env_adapter = os.environ.get("DEV_FLOW_REVIEW_ADAPTER", "")
    if not cli_adapter and env_adapter:
        cli_adapter = env_adapter

    host = detect_host(cli_host)

    # ── Tier 1: CLI 显式 ──
    if cli_adapter:
        validate_adapter_id(cli_adapter, "CLI --adapter / DEV_FLOW_REVIEW_ADAPTER")
        adapters = dict(DEFAULT_ADAPTERS)
        resolve_agent_config_path(adapters)
        selection = {
            "schema_version": 2,
            "primary": cli_adapter,
            "fallback_policy": "deny",
            "fallback_order": [],
            "adapters": adapters,
            "host": host,
        }
        digest = compute_digest(selection)
        result = {
            "status": "available",
            "selected_adapter": cli_adapter,
            "selection_reason": "cli_explicit",
            "config_digest": digest,
            "primary": cli_adapter,
            "fallback_policy": "deny",
            "fallback_order": [],
            "adapters": selection["adapters"],
            "source": "cli",
            "host": host,
            "migrated_from_v1": False,
        }
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0

    # ── Tier 2: 项目级配置 ──
    proj = read_project_config(project_root, project_config)
    if proj is not None:
        config, source, reason = proj
        migrated = config.pop("_migrated_from_v1", False)
        config.pop("_v1_path", None)
        adapters = merge_adapters(DEFAULT_ADAPTERS, config.get("adapters"))
        resolve_agent_config_path(adapters)
        selection = {
            "schema_version": 2,
            "primary": config.get("primary"),
            "fallback_policy": config.get("fallback_policy", "allow"),
            "fallback_order": config.get("fallback_order", []),
            "adapters": adapters,
            "host": host,
        }
        digest = compute_digest(selection)
        result = {
            "status": "available",
            "selected_adapter": selection["primary"],
            "selection_reason": reason,
            "config_digest": digest,
            "primary": selection["primary"],
            "fallback_policy": selection["fallback_policy"],
            "fallback_order": selection["fallback_order"],
            "adapters": adapters,
            "source": source,
            "host": host,
            "migrated_from_v1": migrated,
        }
        if migrated:
            result["v1_migration_note"] = (
                "Project config was migrated from schema v1. "
                "Re-run install-review-backend.sh to write a schema v2 *.local.json config."
            )
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0

    # ── Tier 3: 用户级配置 ──
    usr = read_user_config(user_config, host)
    if usr is not None:
        config, source, reason = usr
        adapters = merge_adapters(DEFAULT_ADAPTERS, config.get("adapters"))
        resolve_agent_config_path(adapters)
        selection = {
            "schema_version": 2,
            "primary": config.get("primary"),
            "fallback_policy": config.get("fallback_policy", "allow"),
            "fallback_order": config.get("fallback_order", []),
            "adapters": adapters,
            "host": host,
        }
        digest = compute_digest(selection)
        result = {
            "status": "available",
            "selected_adapter": selection["primary"],
            "selection_reason": reason,
            "config_digest": digest,
            "primary": selection["primary"],
            "fallback_policy": selection["fallback_policy"],
            "fallback_order": selection["fallback_order"],
            "adapters": adapters,
            "source": source,
            "host": host,
            "migrated_from_v1": False,
        }
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0

    # ── Tier 4: 仓库默认策略 ──
    # 仓库默认策略仅供交互向导提示 / 显式消费。install 和 environment gate 不得把 default
    # 当成"已配置"静默 pass——没有项目/用户/CLI 选择时必须 fail closed。
    default = DEFAULT_POLICY.get(host)
    if default is None:
        fail_closed(
            "unknown_host",
            f"Unknown host {host!r}. Known hosts: {', '.join(DEFAULT_POLICY)}",
        )
    adapters = dict(DEFAULT_ADAPTERS)
    resolve_agent_config_path(adapters)
    selection = {
        "schema_version": 2,
        "primary": default["primary"],
        "fallback_policy": default["fallback_policy"],
        "fallback_order": default["fallback_order"],
        "adapters": adapters,
        "host": host,
    }
    digest = compute_digest(selection)
    result = {
        "status": "available",
        "selected_adapter": default["primary"],
        "selection_reason": "default_policy",
        "config_digest": digest,
        "primary": default["primary"],
        "fallback_policy": default["fallback_policy"],
        "fallback_order": default["fallback_order"],
        "adapters": adapters,
        "source": "default",
        "host": host,
        "migrated_from_v1": False,
        "default_policy_note": (
            "No project or user review config found; using committed default policy. "
            "Run install-review-backend.sh to configure a review adapter."
        ),
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


def cmd_validate(args):
    """校验一个配置文件。"""
    config_path = ""
    i = 0
    while i < len(args):
        if args[i] == "--config-path" and i + 1 < len(args):
            config_path = args[i + 1]
            i += 2
        else:
            fail_closed("invalid_argument", f"Unknown argument: {args[i]}")
    if not config_path or not Path(config_path).is_file():
        fail_closed("config_missing", f"Config file not found: {config_path}")
    try:
        raw = json.loads(Path(config_path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail_closed("config_invalid_json", str(exc))
    validate_v2_config(raw, f"config ({config_path})")
    print(json.dumps({"status": "valid", "config_path": config_path}, ensure_ascii=False))
    return 0


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    sub = args[0]
    rest = args[1:]
    if sub == "resolve":
        return cmd_resolve(rest)
    elif sub == "validate":
        return cmd_validate(rest)
    else:
        fail_closed("unknown_subcommand", f"Unknown subcommand: {sub}. Use resolve or validate.")


if __name__ == "__main__":
    sys.exit(main())
