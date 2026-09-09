#!/usr/bin/env python3
"""Read-only Xcode target resolver for dev-flow.

Reads <app-root>/.xcodebuildmcp/config.yaml (the same file XcodeBuildMCP 2.x reads at MCP
startup), parses the ``sessionDefaults`` block, resolves relative paths against the app root,
validates required fields, and outputs bounded JSON for the agent to use with
XcodeBuildMCP ``session_set_defaults``.

This resolver never scans for devices. If a required field (project/workspace path, scheme,
configuration, platform, or a device target) is missing, it reports ``blocked`` with the exact
reason; the agent must then ask the user or explicitly discover a target.

Usage:
  python3 scripts/xcode-target-resolver.py [--app-root <path>]

If --app-root is omitted, falls back to DEV_FLOW_PROJECT_ROOT, then cwd traversal that looks for
.xcodebuildmcp/config.yaml or .dev-flow/source-root.
"""

import json
import os
import sys
from pathlib import Path


def resolve_app_root(cli_app_root: str = "") -> Path:
    """Resolve the app root from CLI arg, env, or cwd traversal."""
    if cli_app_root:
        return Path(cli_app_root).expanduser().resolve()
    env_root = os.environ.get("DEV_FLOW_PROJECT_ROOT", "").strip()
    if env_root:
        return Path(env_root).expanduser().resolve()
    # Cwd traversal: look for .xcodebuildmcp/config.yaml or .dev-flow/source-root
    cwd = Path.cwd()
    for candidate in [cwd, *cwd.parents]:
        if (candidate / ".xcodebuildmcp" / "config.yaml").exists():
            return candidate.resolve()
        if (candidate / ".dev-flow" / "source-root").exists():
            return candidate.resolve()
    return cwd.resolve()


def parse_yaml_scalar(raw: str) -> str:
    """Parse a YAML scalar value, stripping quotes and trailing comments.

    Handles the controlled schema produced by XcodeBuildMCP: scalar values (strings),
    optionally quoted. Comments (space + hash) outside quotes are stripped.
    """
    if not raw:
        return ""
    # Double-quoted string
    if raw.startswith('"'):
        end = raw.find('"', 1)
        if end != -1:
            return raw[1:end]
        return raw[1:]
    # Single-quoted string
    if raw.startswith("'"):
        end = raw.find("'", 1)
        if end != -1:
            return raw[1:end]
        return raw[1:]
    # Unquoted — strip trailing comment (space + #)
    comment_idx = raw.find(" #")
    if comment_idx != -1:
        raw = raw[:comment_idx]
    return raw.strip()


def parse_session_defaults(text: str) -> dict:
    """Parse the ``sessionDefaults:`` block from XcodeBuildMCP config.yaml.

    Minimal line-based parser for flat scalar key-value mappings. Handles the controlled
    schema produced by XcodeBuildMCP: a top-level ``sessionDefaults:`` key with indented
    scalar children. Stops at the next top-level key.
    """
    lines = text.splitlines()
    in_block = False
    result = {}
    for line in lines:
        stripped = line.strip()
        # Skip empty lines and comment-only lines
        if not stripped or stripped.startswith("#"):
            continue
        # Check for a top-level key (no leading whitespace)
        if not line[0].isspace():
            # We were in the sessionDefaults block and hit a new top-level key → block ends
            if in_block:
                break
            # Check if this is the sessionDefaults: header
            if stripped == "sessionDefaults:" or stripped.startswith("sessionDefaults:"):
                in_block = True
            continue
        # We're in an indented block
        if not in_block:
            continue  # indented line before sessionDefaults → ignore
        # Parse key: value
        if ":" not in stripped:
            continue
        key, _, raw_value = stripped.partition(":")
        key = key.strip()
        value = parse_yaml_scalar(raw_value.strip())
        result[key] = value
    return result


def resolve_path(raw: str, app_root: Path) -> str:
    """Resolve a path against app_root; expand ~ for absolute paths."""
    if not raw:
        return ""
    p = Path(raw).expanduser()
    if not p.is_absolute():
        p = app_root / p
    return str(p)


def print_blocked(reason: str, detail: str, app_root: Path, config_path: Path = None) -> None:
    payload = {
        "status": "blocked",
        "reason": reason,
        "detail": detail,
        "app_root": str(app_root),
    }
    if config_path is not None:
        payload["config_path"] = str(config_path)
    payload["instructions"] = (
        "Resolve the blocker above, then re-run this resolver. "
        "Do NOT auto-scan for devices; ask the user or explicitly discover a target."
    )
    print(json.dumps(payload, ensure_ascii=False, indent=2))


def main() -> int:
    # Parse CLI args
    cli_app_root = ""
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--app-root" and i + 1 < len(args):
            cli_app_root = args[i + 1]
            i += 2
        elif args[i] in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            print(json.dumps({
                "status": "blocked",
                "reason": "invalid_argument",
                "detail": f"Unknown argument: {args[i]}",
            }, ensure_ascii=False, indent=2))
            return 1

    app_root = resolve_app_root(cli_app_root)
    config_path = app_root / ".xcodebuildmcp" / "config.yaml"

    if not config_path.exists():
        print_blocked(
            "config_missing",
            f".xcodebuildmcp/config.yaml not found under {app_root}. "
            "Create it with XcodeBuildMCP session_set_defaults --persist, or provide target "
            "fields manually.",
            app_root,
        )
        return 1

    try:
        text = config_path.read_text(encoding="utf-8")
    except OSError as exc:
        print_blocked("config_unreadable", str(exc), app_root, config_path)
        return 1

    try:
        session_defaults = parse_session_defaults(text)
    except Exception as exc:
        print_blocked("config_parse_failed", str(exc), app_root, config_path)
        return 1

    if not session_defaults:
        print_blocked(
            "session_defaults_empty",
            "sessionDefaults block is missing or empty in config.yaml.",
            app_root,
            config_path,
        )
        return 1

    # Extract fields
    workspace_path_raw = session_defaults.get("workspacePath", "")
    project_path_raw = session_defaults.get("projectPath", "")
    scheme = session_defaults.get("scheme", "")
    configuration = session_defaults.get("configuration", "")
    platform = session_defaults.get("platform", "")
    device_id = session_defaults.get("deviceId", "")
    simulator_id = session_defaults.get("simulatorId", "")
    simulator_name = session_defaults.get("simulatorName", "")
    bundle_id = session_defaults.get("bundleId", "")

    # Resolve relative paths against app_root
    workspace_path = resolve_path(workspace_path_raw, app_root) if workspace_path_raw else ""
    project_path = resolve_path(project_path_raw, app_root) if project_path_raw else ""

    # Validate required fields
    missing = []
    if not workspace_path and not project_path:
        missing.append("workspacePath or projectPath")
    if not scheme:
        missing.append("scheme")
    if not configuration:
        missing.append("configuration")
    if not platform:
        missing.append("platform")
    # Device target: deviceId (physical) or simulatorId/simulatorName (simulator)
    if not device_id and not simulator_id and not simulator_name:
        missing.append("deviceId or simulatorId or simulatorName")
    if missing:
        print_blocked(
            "required_field_missing",
            "Missing required field(s): " + ", ".join(missing),
            app_root,
            config_path,
        )
        return 1

    # Target 互斥：physical (deviceId) 与 simulator (simulatorId/simulatorName)
    # 不可同时存在——target 必须 exactly one kind，防止两类目标混传。
    has_physical = bool(device_id)
    has_simulator = bool(simulator_id or simulator_name)
    if has_physical and has_simulator:
        print_blocked(
            "target_conflict",
            "deviceId (physical) and simulatorId/simulatorName (simulator) are mutually "
            "exclusive; provide exactly one target kind.",
            app_root,
            config_path,
        )
        return 1

    # Determine target kind and the real XcodeBuildMCP launch action.
    if has_physical:
        target_kind = "physical"
        launch_action = "build_run_device"
    else:
        target_kind = "simulator"
        launch_action = "build_run_sim"

    # Choose the primary project path. 若 workspacePath 与 projectPath 同时存在，
    # 优先 workspace 且只输出 workspace（CocoaPods 必须用 .xcworkspace）。
    notices = []
    if workspace_path and project_path:
        notices.append(
            "workspacePath and projectPath both present; using workspacePath only "
            "(preferred for CocoaPods). projectPath is omitted from the profile."
        )
        primary_path = workspace_path
        primary_kind = "workspacePath"
    elif workspace_path:
        primary_path = workspace_path
        primary_kind = "workspacePath"
    else:
        primary_path = project_path
        primary_kind = "projectPath"

    # Validate the primary path exists
    primary = Path(primary_path)
    if not primary.exists():
        print_blocked(
            "project_path_not_found",
            f"{primary_kind} does not exist: {primary_path}",
            app_root,
            config_path,
        )
        return 1

    # Validate the primary path is an Xcode workspace/project, not a plain dir/file.
    # workspacePath must end with .xcworkspace; projectPath must end with .xcodeproj。
    if primary_kind == "workspacePath" and not primary_path.endswith(".xcworkspace"):
        print_blocked(
            "not_an_xcode_project_path",
            f"workspacePath must end with .xcworkspace: {primary_path}",
            app_root,
            config_path,
        )
        return 1
    if primary_kind == "projectPath" and not primary_path.endswith(".xcodeproj"):
        print_blocked(
            "not_an_xcode_project_path",
            f"projectPath must end with .xcodeproj: {primary_path}",
            app_root,
            config_path,
        )
        return 1

    # Validate the primary path is inside app_root (resolved, to handle symlinks)
    try:
        primary.resolve().relative_to(app_root.resolve())
    except ValueError:
        print_blocked(
            "project_path_mismatch",
            f"{primary_kind} is outside app_root: {primary_path} (app_root={app_root})",
            app_root,
            config_path,
        )
        return 1

    # Build profile fields for session_set_defaults. 只输出选定的 primary path
    # （workspace 优先时省略 projectPath），避免互斥字段同时传递。
    profile = {}
    profile[primary_kind] = primary_path
    profile["scheme"] = scheme
    profile["configuration"] = configuration
    profile["platform"] = platform
    if target_kind == "physical":
        profile["deviceId"] = device_id
    else:
        # Simulator：按 XcodeBuildMCP 契约只输出 simulatorId（可 notice 忽略 name），
        # 避免 simulatorId+simulatorName 互斥字段同时传给 session_set_defaults。
        if simulator_id:
            profile["simulatorId"] = simulator_id
            if simulator_name:
                notices.append(
                    "simulatorId and simulatorName both present; outputting simulatorId only "
                    "(XcodeBuildMCP resolves the simulator by id). simulatorName is omitted."
                )
        else:
            profile["simulatorName"] = simulator_name
            notices.append(
                "Only simulatorName is configured (no simulatorId); outputting simulatorName. "
                "Prefer simulatorId for stable selection."
            )
    if bundle_id:
        profile["bundleId"] = bundle_id

    result = {
        "status": "available",
        "app_root": str(app_root),
        "config_path": str(config_path),
        "target_kind": target_kind,
        "launch_action": launch_action,
        "profile": profile,
        "instructions": (
            f"Call XcodeBuildMCP session_set_defaults with profile=<dev-flow-session-id> "
            f"createIfNotExists=true and these profile fields. Then call session_show_defaults "
            f"to verify before {launch_action}."
        ),
    }
    if notices:
        result["notices"] = notices
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
