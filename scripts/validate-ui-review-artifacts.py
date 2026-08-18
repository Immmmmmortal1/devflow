#!/usr/bin/env python3
"""Validate ui-review artifacts across split, parity, and repair stages."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

UNIT_KINDS = {
    "text",
    "button-text",
    "button-image",
    "button-text-icon",
    "image",
}
MARKS = {"ok", "wrong", "missing"}
BASE_LAYOUTS = {"UICollectionView", "UIScrollView"}
SPLIT_STATUSES = {"complete", "pending_children"}
REVIEW_EVIDENCE_FIELDS = ("status", "run_id", "role", "verdict", "reviewed_at")
UNIT_DECISION_FIELDS = (
    "figma_id",
    "group_id",
    "name",
    "unit_kind",
    "anchor",
    "is_minimum_unit",
    "asset_collapse_eligible",
    "has_localizable_text",
    "has_interaction",
    "split_status",
    "pending_child_ids",
)


class ValidationError(Exception):
    pass


def load_json(path: Path, label: str) -> dict[str, Any]:
    if not path.is_file():
        raise ValidationError(f"{label} does not exist: {path}")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValidationError(f"{label} is invalid JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise ValidationError(f"{label} must be a JSON object")
    return payload


def require_identity(payload: dict[str, Any], session_id: str, label: str) -> None:
    if payload.get("producer") != "ui-review":
        raise ValidationError(f"{label} producer must be ui-review")
    if payload.get("schema_version") != 1:
        raise ValidationError(f"{label} schema_version must be 1")
    if payload.get("session_id") != session_id:
        raise ValidationError(f"{label} belongs to another session")


def extract_ids(value: Any, label: str) -> set[str]:
    if not isinstance(value, list):
        raise ValidationError(f"{label} must be an array")
    result: set[str] = set()
    for item in value:
        current = item if isinstance(item, str) else item.get("figma_id") if isinstance(item, dict) else None
        if not isinstance(current, str) or not current.strip():
            raise ValidationError(f"{label} contains an invalid id")
        if current in result:
            raise ValidationError(f"{label} contains duplicate id {current}")
        result.add(current)
    return result


def bounded_path(workspace: Path, raw: Any, label: str) -> Path:
    if not isinstance(raw, str) or not raw.strip():
        raise ValidationError(f"{label} path is required")
    path = Path(raw).expanduser().resolve()
    try:
        path.relative_to(workspace)
    except ValueError as exc:
        raise ValidationError(f"{label} must be inside artifact workspace") from exc
    if not path.is_file():
        raise ValidationError(f"{label} does not exist: {path}")
    return path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_nonempty_str(payload: dict[str, Any], field: str, label: str) -> str:
    value = payload.get(field)
    if not isinstance(value, str) or not value.strip():
        raise ValidationError(f"{label} requires non-empty {field}")
    return value


def validate_review_evidence(payload: dict[str, Any], label: str, expected_role: str) -> None:
    require_fields(payload, REVIEW_EVIDENCE_FIELDS, label)
    if payload.get("status") != "pass":
        raise ValidationError(f"{label} status must be pass")
    if payload.get("verdict") != "pass":
        raise ValidationError(f"{label} verdict must be pass")
    require_nonempty_str(payload, "run_id", label)
    role = require_nonempty_str(payload, "role", label)
    if role != expected_role:
        raise ValidationError(f"{label} role must be {expected_role}")
    require_nonempty_str(payload, "reviewed_at", label)


def validate_unit_decision(unit: dict[str, Any], label: str) -> dict[str, Any]:
    require_fields(unit, UNIT_DECISION_FIELDS, label)
    figma_id = require_nonempty_str(unit, "figma_id", label)
    require_nonempty_str(unit, "group_id", label)
    require_nonempty_str(unit, "name", label)
    require_nonempty_str(unit, "anchor", label)
    if unit.get("unit_kind") not in UNIT_KINDS:
        raise ValidationError(f"{label}: invalid unit_kind")
    for field in ("is_minimum_unit", "asset_collapse_eligible", "has_localizable_text", "has_interaction"):
        if not isinstance(unit.get(field), bool):
            raise ValidationError(f"{label}: {field} must be a boolean")
    if unit.get("split_status") not in SPLIT_STATUSES:
        raise ValidationError(f"{label}: split_status must be complete|pending_children")
    pending = unit.get("pending_child_ids")
    if not isinstance(pending, list) or any(
        not isinstance(item, str) or not item.strip() for item in pending
    ):
        raise ValidationError(f"{label}: pending_child_ids must be an array of non-empty strings")

    if unit["has_localizable_text"] and unit["asset_collapse_eligible"]:
        raise ValidationError(
            f"{figma_id}: has_localizable_text=true forbids asset_collapse_eligible=true"
        )
    if (
        unit["has_localizable_text"]
        and unit["unit_kind"] == "image"
        and unit["is_minimum_unit"]
        and unit["asset_collapse_eligible"]
    ):
        raise ValidationError(
            f"{figma_id}: localizable-text composite cannot be collapsed image minimum unit"
        )
    if unit["has_localizable_text"] and unit["unit_kind"] == "image" and unit["is_minimum_unit"]:
        # Collapsed image parents with text descendants are never valid minimum units.
        raise ValidationError(
            f"{figma_id}: unit_kind=image minimum unit cannot have has_localizable_text=true"
        )
    if unit["is_minimum_unit"]:
        if unit["split_status"] != "complete":
            raise ValidationError(f"{figma_id}: minimum unit split_status must be complete")
        if pending:
            raise ValidationError(f"{figma_id}: minimum unit pending_child_ids must be empty")
    else:
        if unit["split_status"] == "complete" and pending:
            raise ValidationError(
                f"{figma_id}: non-minimum complete node cannot retain pending_child_ids"
            )
        if unit["split_status"] == "pending_children" and not pending:
            raise ValidationError(
                f"{figma_id}: pending_children requires non-empty pending_child_ids"
            )
    return unit


def load_figma_text_descendant_map(workspace: Path) -> dict[str, bool] | None:
    """Return figma_id -> has TEXT descendant when a Figma dump is present."""
    candidates = [
        workspace / "figma" / "root.depth4.json",
        workspace / "figma" / "root.json",
    ]
    dump_path = next((path for path in candidates if path.is_file()), None)
    if dump_path is None:
        return None

    payload = load_json(dump_path, "figma dump")
    roots: list[dict[str, Any]] = []
    if "nodes" in payload and isinstance(payload["nodes"], dict):
        for entry in payload["nodes"].values():
            if isinstance(entry, dict) and isinstance(entry.get("document"), dict):
                roots.append(entry["document"])
    elif isinstance(payload.get("document"), dict):
        roots.append(payload["document"])
    else:
        return None

    text_ids: set[str] = set()

    def walk(node: dict[str, Any]) -> bool:
        node_id = node.get("id")
        has_text = node.get("type") == "TEXT"
        for child in node.get("children") or []:
            if isinstance(child, dict) and walk(child):
                has_text = True
        if isinstance(node_id, str) and node_id.strip():
            if has_text:
                text_ids.add(node_id)
        return has_text

    for root in roots:
        walk(root)
    return {node_id: True for node_id in text_ids}


def validate_rules_used(
    workspace: Path, detail_minimums: dict[str, dict[str, Any]]
) -> None:
    """When rules_used.json is present, its rules_used set must equal the deduplicated
    unit_kind set across all reviewed minimum units.

    rules_used.json is produced by figma-ui-gates G2 (producer: figma-ui-gates) and is
    optional for ui-review workspaces. When present, it is cross-checked so the on-demand
    rule set declared for the page matches what the split actually classified.
    """
    rules_path = workspace / "rules_used.json"
    if not rules_path.is_file():
        return
    payload = load_json(rules_path, "rules_used")
    if payload.get("schema_version") != 1:
        raise ValidationError("rules_used.json schema_version must be 1")
    raw = payload.get("rules_used")
    if not isinstance(raw, list):
        raise ValidationError("rules_used.json rules_used must be an array")
    rules_set: set[str] = set()
    for item in raw:
        if not isinstance(item, str) or not item.strip():
            raise ValidationError("rules_used.json rules_used contains an invalid entry")
        if item not in UNIT_KINDS:
            raise ValidationError(
                f"rules_used.json rules_used has invalid unit_kind: {item} "
                f"(allowed: {sorted(UNIT_KINDS)})"
            )
        if item in rules_set:
            raise ValidationError(f"rules_used.json rules_used contains duplicate: {item}")
        rules_set.add(item)
    unit_kind_set = {decision["unit_kind"] for decision in detail_minimums.values()}
    if rules_set != unit_kind_set:
        raise ValidationError(
            "rules_used.json rules_used set does not match the unit_kind set of reviewed "
            f"minimum units (rules_used={sorted(rules_set)}, "
            f"units={sorted(unit_kind_set)})"
        )


def validate_split(workspace: Path, session_id: str) -> set[str]:
    manifest = load_json(workspace / "manifest.json", "manifest")
    require_identity(manifest, session_id, "manifest")
    for field in ("canonical_figma_url", "root_node_id", "screen_state"):
        if not isinstance(manifest.get(field), str) or not manifest[field].strip():
            raise ValidationError(f"manifest requires {field}")

    structure_review = load_json(
        workspace / "structure" / "structure-review.json",
        "structure review",
    )
    require_identity(structure_review, session_id, "structure review")
    validate_review_evidence(structure_review, "structure review", "structure")

    sweep = load_json(
        workspace / "structure" / "structure-sweep-complete.json",
        "structure sweep",
    )
    require_identity(sweep, session_id, "structure sweep")
    if sweep.get("status") != "pass":
        raise ValidationError("structure sweep status must be pass")

    classification = load_json(
        workspace / "structure" / "screen-classification.json",
        "screen classification",
    )
    require_identity(classification, session_id, "screen classification")
    if classification.get("expected_base_layout") not in BASE_LAYOUTS:
        raise ValidationError("screen classification has invalid expected_base_layout")

    index = load_json(
        workspace / "structure" / "minimum-unit-index.json",
        "minimum unit index",
    )
    require_identity(index, session_id, "minimum unit index")
    units = index.get("units")
    if not isinstance(units, list) or not units:
        raise ValidationError("minimum unit index requires a non-empty units array")

    text_map = load_figma_text_descendant_map(workspace)
    detail_minimums: dict[str, dict[str, Any]] = {}
    reviewed_groups: set[str] = set()

    ids: set[str] = set()
    for row in units:
        if not isinstance(row, dict):
            raise ValidationError("minimum unit index rows must be objects")
        figma_id = row.get("figma_id")
        if not isinstance(figma_id, str) or not figma_id.strip() or figma_id in ids:
            raise ValidationError("minimum unit index contains invalid or duplicate figma_id")
        if row.get("unit_kind") not in UNIT_KINDS:
            raise ValidationError(f"{figma_id}: invalid unit_kind")
        group_id = row.get("group_id")
        if not isinstance(group_id, str) or not group_id.strip():
            raise ValidationError(f"{figma_id}: group_id is required")

        detail_path = workspace / "groups" / group_id / "detail.json"
        review_path = workspace / "groups" / group_id / "detail-review.json"
        if not detail_path.is_file() or not review_path.is_file():
            raise ValidationError(f"{figma_id}: detail and detail-review evidence are required")

        if group_id not in reviewed_groups:
            detail = load_json(detail_path, f"detail {group_id}")
            require_identity(detail, session_id, f"detail {group_id}")
            if detail.get("split_status") != "complete":
                raise ValidationError(f"detail {group_id}: split_status must be complete")
            detail_units = detail.get("minimum_units")
            if not isinstance(detail_units, list) or not detail_units:
                raise ValidationError(f"detail {group_id}: minimum_units must be a non-empty array")
            for unit in detail_units:
                if not isinstance(unit, dict):
                    raise ValidationError(f"detail {group_id}: minimum_units rows must be objects")
                decision = validate_unit_decision(unit, f"detail {group_id} unit")
                unit_id = decision["figma_id"]
                if decision["group_id"] != group_id:
                    raise ValidationError(
                        f"{unit_id}: detail group_id must match directory {group_id}"
                    )
                if not decision["is_minimum_unit"]:
                    raise ValidationError(
                        f"{unit_id}: non-minimum units must not appear in detail.minimum_units"
                    )
                if unit_id in detail_minimums:
                    raise ValidationError(f"{unit_id}: duplicated across detail files")
                detail_minimums[unit_id] = decision
                if (
                    text_map is not None
                    and decision["unit_kind"] == "image"
                    and decision["asset_collapse_eligible"]
                    and text_map.get(unit_id)
                ):
                    raise ValidationError(
                        f"{unit_id}: Figma dump shows TEXT descendants; cannot collapse as image"
                    )

            review = load_json(review_path, f"detail-review {group_id}")
            require_identity(review, session_id, f"detail-review {group_id}")
            validate_review_evidence(review, f"detail-review {group_id}", "detail")
            reviewed_groups.add(group_id)

        decision = detail_minimums.get(figma_id)
        if decision is None:
            raise ValidationError(
                f"{figma_id}: minimum-unit-index entry missing from reviewed detail.json"
            )
        if decision["unit_kind"] != row["unit_kind"]:
            raise ValidationError(f"{figma_id}: index unit_kind does not match detail.json")
        if decision["group_id"] != group_id:
            raise ValidationError(f"{figma_id}: index group_id does not match detail.json")
        ids.add(figma_id)

    if set(detail_minimums) != ids:
        raise ValidationError(
            "minimum-unit-index must exactly equal reviewed detail.minimum_units across groups"
        )

    if sweep.get("minimum_unit_count") != len(ids):
        raise ValidationError("structure sweep minimum_unit_count does not match index")
    validate_rules_used(workspace, detail_minimums)
    return ids


def require_fields(payload: Any, fields: tuple[str, ...], label: str) -> dict[str, Any]:
    if not isinstance(payload, dict) or any(field not in payload for field in fields):
        raise ValidationError(f"{label} requires fields: {', '.join(fields)}")
    return payload


def numeric(value: Any, label: str) -> float:
    if not isinstance(value, (int, float)):
        raise ValidationError(f"{label} must be numeric")
    return float(value)


def validate_text_evidence(evidence: Any, label: str, mark: str) -> None:
    evidence = require_fields(
        evidence,
        ("runtime_path", "expected", "measured", "tolerance", "layout"),
        label,
    )
    for side in ("expected", "measured"):
        require_fields(
            evidence[side],
            ("font_name", "font_size", "color_rgba", "origin"),
            f"{label}.{side}",
        )
    tolerance = require_fields(
        evidence["tolerance"],
        ("origin_pt", "font_size_pt", "color_channel"),
        f"{label}.tolerance",
    )
    limits = {"origin_pt": 0.5, "font_size_pt": 0.1, "color_channel": 1 / 255}
    for field, limit in limits.items():
        value = numeric(tolerance[field], f"{label}.tolerance.{field}")
        if value < 0 or value > limit:
            raise ValidationError(f"{label}.tolerance.{field} exceeds canonical limit")
    if mark == "ok":
        expected, measured = evidence["expected"], evidence["measured"]
        layout = require_fields(
            evidence["layout"],
            ("number_of_lines", "hardcoded_width", "hardcoded_height", "localization_safe"),
            f"{label}.layout",
        )
        if not (
            layout["number_of_lines"] == 0
            and layout["hardcoded_width"] is False
            and layout["hardcoded_height"] is False
            and layout["localization_safe"] is True
        ):
            raise ValidationError(f"{label} layout/localization contract cannot be ok")
        if expected["font_name"] != measured["font_name"]:
            raise ValidationError(f"{label} font_name mismatch cannot be ok")
        if abs(numeric(expected["font_size"], label) - numeric(measured["font_size"], label)) > tolerance["font_size_pt"]:
            raise ValidationError(f"{label} font_size delta exceeds tolerance")
        for axis in ("x", "y"):
            expected_origin = require_fields(expected["origin"], ("x", "y"), f"{label}.expected.origin")
            measured_origin = require_fields(measured["origin"], ("x", "y"), f"{label}.measured.origin")
            if abs(numeric(expected_origin[axis], label) - numeric(measured_origin[axis], label)) > tolerance["origin_pt"]:
                raise ValidationError(f"{label} origin delta exceeds tolerance")
        expected_color = expected["color_rgba"]
        measured_color = measured["color_rgba"]
        if not (
            isinstance(expected_color, list)
            and isinstance(measured_color, list)
            and len(expected_color) == len(measured_color) == 4
        ):
            raise ValidationError(f"{label} color_rgba must contain four channels")
        if any(
            abs(numeric(left, label) - numeric(right, label)) > tolerance["color_channel"]
            for left, right in zip(expected_color, measured_color)
        ):
            raise ValidationError(f"{label} color delta exceeds tolerance")


def validate_image_evidence(evidence: Any, label: str, mark: str) -> None:
    evidence = require_fields(
        evidence,
        (
            "runtime_path",
            "figma_sha256",
            "source_asset_sha256",
            "runtime_asset_name",
            "expected_frame",
            "measured_frame",
            "tolerance",
        ),
        label,
    )
    for field in ("figma_sha256", "source_asset_sha256"):
        if not isinstance(evidence[field], str) or not re.fullmatch(r"[0-9a-f]{64}", evidence[field]):
            raise ValidationError(f"{label}.{field} must be a lowercase SHA-256")
    tolerance = require_fields(evidence["tolerance"], ("origin_pt", "size_pt"), f"{label}.tolerance")
    for field in ("origin_pt", "size_pt"):
        value = numeric(tolerance[field], f"{label}.tolerance.{field}")
        if value < 0 or value > 0.5:
            raise ValidationError(f"{label}.tolerance.{field} exceeds canonical limit")
    if mark == "ok":
        if evidence["figma_sha256"] != evidence["source_asset_sha256"]:
            raise ValidationError(f"{label} asset hash mismatch cannot be ok")
        expected = require_fields(
            evidence["expected_frame"], ("x", "y", "width", "height"), f"{label}.expected_frame"
        )
        measured = require_fields(
            evidence["measured_frame"], ("x", "y", "width", "height"), f"{label}.measured_frame"
        )
        for field in ("x", "y"):
            if abs(numeric(expected[field], label) - numeric(measured[field], label)) > tolerance["origin_pt"]:
                raise ValidationError(f"{label} frame origin delta exceeds tolerance")
        for field in ("width", "height"):
            if abs(numeric(expected[field], label) - numeric(measured[field], label)) > tolerance["size_pt"]:
                raise ValidationError(f"{label} frame size delta exceeds tolerance")


def validate_unit_evidence(evidence: Any, unit_kind: str, label: str, mark: str) -> None:
    if mark == "missing":
        evidence = require_fields(
            evidence,
            ("runtime_path", "expected", "measured", "binding_attempts"),
            label,
        )
        if evidence["measured"] is not None:
            raise ValidationError(f"{label}.measured must be null for missing")
        if not isinstance(evidence["binding_attempts"], list) or not evidence["binding_attempts"]:
            raise ValidationError(f"{label}.binding_attempts must prove the missing lookup")
        return
    if unit_kind in {"text", "button-text"}:
        validate_text_evidence(evidence, label, mark)
    elif unit_kind in {"image", "button-image"}:
        validate_image_evidence(evidence, label, mark)
    elif unit_kind == "button-text-icon":
        evidence = require_fields(evidence, ("text", "icon"), label)
        validate_text_evidence(evidence["text"], f"{label}.text", mark)
        validate_image_evidence(evidence["icon"], f"{label}.icon", mark)
    else:
        raise ValidationError(f"{label} has unsupported unit_kind")


def validate_mark_row(row: Any, label: str, unit_kind: str | None = None) -> str:
    if not isinstance(row, dict):
        raise ValidationError(f"{label} must be an object")
    if row.get("observation_status") != "observed":
        raise ValidationError(f"{label} must be observed before assigning a parity mark")
    mark = row.get("mark")
    if mark not in MARKS:
        raise ValidationError(f"{label} has invalid mark")
    if mark in {"wrong", "missing"}:
        findings = row.get("findings")
        if not isinstance(findings, list) or not findings:
            raise ValidationError(f"{label} requires non-empty findings for {mark}")
    evidence = row.get("evidence")
    if unit_kind:
        validate_unit_evidence(evidence, unit_kind, f"{label}.evidence", mark)
    else:
        evidence = require_fields(
            evidence,
            ("runtime_path", "expected", "measured"),
            f"{label}.evidence",
        )
        if not isinstance(evidence["runtime_path"], str) or not evidence["runtime_path"].strip():
            raise ValidationError(f"{label}.evidence.runtime_path is required")
    return mark


def validate_parity_payload(
    payload: dict[str, Any],
    expected_ids: set[str],
    label: str,
) -> None:
    units = payload.get("units")
    if not isinstance(units, list):
        raise ValidationError(f"{label} units must be an array")

    row_ids: set[str] = set()
    counts = {mark: 0 for mark in MARKS}
    for row in units:
        if not isinstance(row, dict):
            raise ValidationError("parity unit row must be an object")
        figma_id = row.get("figma_id")
        if not isinstance(figma_id, str) or figma_id in row_ids:
            raise ValidationError(f"{label} has invalid or duplicate figma_id")
        unit_kind = row.get("unit_kind")
        if unit_kind not in UNIT_KINDS:
            raise ValidationError(f"{label} unit {figma_id} has invalid unit_kind")
        row_ids.add(figma_id)
        counts[validate_mark_row(row, f"{label} unit {figma_id}", unit_kind)] += 1
    if row_ids != expected_ids:
        raise ValidationError(f"{label} unit ids do not exactly match minimum unit index")

    screen = payload.get("screen")
    if not isinstance(screen, dict):
        raise ValidationError(f"{label} screen must be an object")
    validate_mark_row(screen.get("background"), f"{label} screen.background")
    validate_mark_row(screen.get("base_layout"), f"{label} screen.base_layout")

    extras = payload.get("runtime_extras")
    if not isinstance(extras, list):
        raise ValidationError(f"{label} runtime_extras must be an array")
    extra_ids: set[str] = set()
    for extra in extras:
        if not isinstance(extra, dict):
            raise ValidationError("runtime extra rows must be objects")
        anchor = extra.get("runtime_anchor")
        if not isinstance(anchor, str) or not anchor.strip() or anchor in extra_ids:
            raise ValidationError("runtime extras contain invalid or duplicate anchor")
        if extra.get("disposition") not in {"finding", "allowed"}:
            raise ValidationError(f"runtime extra {anchor} requires finding|allowed disposition")
        if not extra.get("evidence") or not extra.get("reason"):
            raise ValidationError(f"runtime extra {anchor} requires evidence and reason")
        extra_ids.add(anchor)

    totals = payload.get("totals")
    if not isinstance(totals, dict) or any(totals.get(mark) != count for mark, count in counts.items()):
        raise ValidationError(f"{label} totals do not match unit rows")


def validate_parity(workspace: Path, session_id: str, expected_ids: set[str]) -> None:
    baseline_path = workspace / "parity-result.baseline.json"
    baseline = load_json(baseline_path, "parity baseline")
    require_identity(baseline, session_id, "parity baseline")
    validate_parity_payload(baseline, expected_ids, "parity baseline")

    current = load_json(workspace / "parity-result.json", "current parity result")
    require_identity(current, session_id, "current parity result")
    validate_parity_payload(current, expected_ids, "current parity result")
    digests = current.get("baseline_sha256")
    if not isinstance(digests, dict):
        raise ValidationError("current parity result requires baseline_sha256")
    if digests.get("json") != sha256(baseline_path):
        raise ValidationError("parity baseline JSON digest mismatch")
    baseline_md = workspace / "parity-result.baseline.md"
    if not baseline_md.is_file() or digests.get("md") != sha256(baseline_md):
        raise ValidationError("parity baseline Markdown digest mismatch")


def validate_repair(workspace: Path, session_id: str) -> None:
    baseline = load_json(workspace / "parity-result.baseline.json", "parity baseline")
    allowed_units: set[str] = set()
    ok_units: set[str] = set()
    for row in baseline.get("units", []):
        if isinstance(row, dict) and isinstance(row.get("figma_id"), str):
            if row.get("mark") in {"wrong", "missing"}:
                allowed_units.add(row["figma_id"])
            elif row.get("mark") == "ok":
                ok_units.add(row["figma_id"])
    screen = baseline.get("screen", {})
    for name in ("background", "base_layout"):
        row = screen.get(name) if isinstance(screen, dict) else None
        if isinstance(row, dict) and row.get("mark") in {"wrong", "missing"}:
            allowed_units.add(f"screen.{name}")
    extra_findings = {
        row["runtime_anchor"]
        for row in baseline.get("runtime_extras", [])
        if isinstance(row, dict)
        and isinstance(row.get("runtime_anchor"), str)
        and row.get("disposition") == "finding"
    }

    confirmed = load_json(workspace / "parity-confirmed.json", "parity confirmation")
    require_identity(confirmed, session_id, "parity confirmation")
    if confirmed.get("artifact_workspace") != str(workspace):
        raise ValidationError("parity confirmation artifact_workspace mismatch")
    if confirmed.get("confirmed_by") != "human" or confirmed.get("may_proceed_to_fix") is not True:
        raise ValidationError("parity confirmation requires human approval and may_proceed_to_fix=true")
    if not isinstance(confirmed.get("approval_token"), str) or not confirmed.get("approval_token").strip():
        raise ValidationError("parity confirmation requires approval_token")
    units_to_fix = extract_ids(confirmed.get("units_to_fix", []), "units_to_fix")
    extras_to_remove = extract_ids(
        confirmed.get("runtime_extras_to_remove", []),
        "runtime_extras_to_remove",
    )
    reopened = extract_ids(confirmed.get("reopened_ok_ids", []), "reopened_ok_ids")
    if not reopened <= ok_units:
        raise ValidationError("reopened_ok_ids must reference baseline ok units")
    if not units_to_fix <= allowed_units | reopened:
        raise ValidationError("units_to_fix contains an id not eligible from the baseline")
    if not extras_to_remove <= extra_findings:
        raise ValidationError("runtime_extras_to_remove contains a non-finding runtime extra")
    authorized = units_to_fix | extras_to_remove
    if not authorized:
        raise ValidationError("repair stage requires a non-empty authorized set")

    accepted_payload = load_json(workspace / "repair-accepted.json", "repair acceptance")
    require_identity(accepted_payload, session_id, "repair acceptance")
    if accepted_payload.get("artifact_workspace") != str(workspace):
        raise ValidationError("repair acceptance artifact_workspace mismatch")
    if accepted_payload.get("confirmed_by") != "human":
        raise ValidationError("repair acceptance requires confirmed_by=human")
    if not isinstance(accepted_payload.get("approval_token"), str) or not accepted_payload.get("approval_token").strip():
        raise ValidationError("repair acceptance requires approval_token")
    if accepted_payload.get("all_authorized_repairs_resolved") is not True:
        raise ValidationError("repair acceptance is not fully resolved")

    accepted = extract_ids(accepted_payload.get("units_accepted", []), "units_accepted")
    reverted = extract_ids(accepted_payload.get("units_reverted", []), "units_reverted")
    rework = extract_ids(accepted_payload.get("units_rework", []), "units_rework")
    if accepted & reverted or rework or accepted | reverted != authorized:
        raise ValidationError("accepted/reverted ids must exactly and disjointly cover authorization")

    current = load_json(workspace / "parity-result.json", "current parity result")
    current_marks = {
        row.get("figma_id"): row.get("mark")
        for row in current.get("units", [])
        if isinstance(row, dict)
    }
    baseline_marks = {
        row.get("figma_id"): row.get("mark")
        for row in baseline.get("units", [])
        if isinstance(row, dict)
    }
    current_screen = current.get("screen", {})
    baseline_screen = baseline.get("screen", {})
    for name in ("background", "base_layout"):
        if isinstance(current_screen, dict) and isinstance(current_screen.get(name), dict):
            current_marks[f"screen.{name}"] = current_screen[name].get("mark")
        if isinstance(baseline_screen, dict) and isinstance(baseline_screen.get(name), dict):
            baseline_marks[f"screen.{name}"] = baseline_screen[name].get("mark")
    current_extra_ids = {
        row.get("runtime_anchor")
        for row in current.get("runtime_extras", [])
        if isinstance(row, dict) and isinstance(row.get("runtime_anchor"), str)
    }
    for item_id in accepted:
        if item_id in extra_findings:
            if item_id in current_extra_ids:
                raise ValidationError(f"accepted runtime extra {item_id} still exists")
            continue
        if item_id in current_marks and current_marks[item_id] != "ok":
            raise ValidationError(f"accepted id {item_id} is not ok in current parity result")
    for item_id in reverted:
        if item_id in extra_findings:
            if item_id not in current_extra_ids:
                raise ValidationError(f"reverted runtime extra {item_id} was not restored")
            continue
        if item_id in current_marks and current_marks[item_id] != baseline_marks.get(item_id):
            raise ValidationError(f"reverted id {item_id} does not restore its baseline mark")

    for field, ids, result in (
        ("verification_reports", accepted, "ok"),
        ("revert_verification_reports", reverted, "reverted"),
    ):
        mapping = accepted_payload.get(field)
        if not isinstance(mapping, dict) or set(mapping) != ids:
            raise ValidationError(f"{field} keys do not match disposition ids")
        for item_id, raw in mapping.items():
            path = bounded_path(workspace, raw, f"{field}[{item_id}]")
            payload = load_json(path, f"{field}[{item_id}]")
            require_identity(payload, session_id, f"{field}[{item_id}]")
            if payload.get("figma_id") != item_id or payload.get("result") != result:
                raise ValidationError(f"{field}[{item_id}] identity/result mismatch")
            if result == "ok" and payload.get("mark_after") != "ok":
                raise ValidationError(f"{field}[{item_id}] accepted repair must have mark_after=ok")
            if not payload.get("debugbridge_evidence"):
                raise ValidationError(f"{field}[{item_id}] lacks DebugBridge evidence")


def validate(workspace: Path, stage: str, session_id: str) -> dict[str, Any]:
    errors: list[str] = []
    unit_ids: set[str] = set()
    try:
        unit_ids = validate_split(workspace, session_id)
        if stage in {"parity", "repair", "all"}:
            validate_parity(workspace, session_id, unit_ids)
        if stage in {"repair", "all"}:
            validate_repair(workspace, session_id)
    except ValidationError as exc:
        errors.append(str(exc))
    return {
        "producer": "validate-ui-review-artifacts",
        "schema_version": 1,
        "session_id": session_id,
        "artifact_workspace": str(workspace),
        "stage": stage,
        "minimum_unit_count": len(unit_ids),
        "status": "pass" if not errors else "failed",
        "errors": errors,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--stage", choices=("split", "parity", "repair", "all"), default="all")
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--report")
    args = parser.parse_args()

    workspace = Path(args.workspace).expanduser().resolve()
    result = validate(workspace, args.stage, args.session_id)
    rendered = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.report:
        Path(args.report).expanduser().write_text(rendered, encoding="utf-8")
    sys.stdout.write(rendered)
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
