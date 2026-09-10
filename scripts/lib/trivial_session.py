#!/usr/bin/env python3
"""trivial fast-path session 一致性判定（scripts/lib/trivial_session.py）。

被 environment-health-check.sh 与 dev-flow-session.sh（record_environment /
approve-commit / commit / validate-trivial）共用，交叉校验 session 是否为
合法 trivial fast-path，防止单一可篡改字段（如 required_gates=[]）绕过门禁。

设计原则：fail closed。任何字段自相矛盾或非 trivial 却显式空 gates 的情况，
一律 raise SystemExit，由调用方转化为「不可 available / 不可 approve」。

契约（与 SKILL.md / skills/environment-health-check/SKILL.md 对齐）：
  - 合法 trivial：schema_version==2 且 level=="trivial" 且 fast_path==True
    且 trivial.kind in ("docs","pod-patch") 且 required_gates==[]
    → 允许空 gates；环境四项 not-required；不要求 review gate。
  - 非 trivial（standard/heavy）或旧 session：
    * required_gates 缺失（None，旧 session）→ 回退要求 review（["review"]）。
    * required_gates 显式空（[]）但非合法 trivial → fail closed。
    * required_gates 非空但缺 review → fail closed。
  - trivial 字段自相矛盾（level=trivial 或 fast_path=True 但其他字段不配套）
    → fail closed。

不依赖任何单一可篡改字段；至少交叉检查 schema_version / level / fast_path /
trivial.kind / required_gates 五项。
"""
import sys

VALID_TRIVIAL_KINDS = ("docs", "pod-patch")


def is_legitimately_trivial(state):
    """交叉校验 state 是否为合法 trivial fast-path session。

    五项必须同时满足：schema_version==2、level=="trivial"、fast_path is True、
    trivial.kind in VALID_TRIVIAL_KINDS、required_gates==[]。任一不符失败即非合法。
    """
    if not isinstance(state, dict):
        return False
    if state.get("schema_version") != 2:
        return False
    if state.get("level") != "trivial":
        return False
    if state.get("fast_path") is not True:
        return False
    trivial = state.get("trivial")
    if not isinstance(trivial, dict):
        return False
    if trivial.get("kind") not in VALID_TRIVIAL_KINDS:
        return False
    # 显式 == [] 校验：区分「合法 trivial 空 gates」与「缺字段 None」与「非空列表」
    if state.get("required_gates") != []:
        return False
    return True


def resolve_required_gates(state):
    """解析 session 的 required_gates，做一致性交叉校验。

    返回 (gates, is_trivial)：
      - 合法 trivial：([], True)
      - 非 trivial 且 required_gates 缺失（旧 session）：(["review"], False)
      - 非 trivial 且 required_gates 非空含 review：(gates, False)

    不一致情形 raise SystemExit（fail closed，调用方据此拒绝 available/approve）：
      - trivial 字段自相矛盾（level=trivial 或 fast_path=True 但非合法 trivial）
      - 非 trivial 显式空 gates（required_gates == []）
      - 非 trivial required_gates 非空但缺 review
      - required_gates 类型非法
    """
    if not isinstance(state, dict):
        raise SystemExit("session state is invalid (not an object)")

    level = state.get("level")
    fast_path = state.get("fast_path")
    raw_gates = state.get("required_gates")

    # 任何 trivial 迹象（level=trivial 或 fast_path=True）都必须整套 trivial 字段一致；
    # 否则视为自相矛盾，fail closed（不原地转 standard/heavy，不继承证据）。
    looks_trivial = (level == "trivial") or (fast_path is True)
    if looks_trivial:
        if not is_legitimately_trivial(state):
            raise SystemExit(
                "trivial session state is self-inconsistent "
                "(schema_version/level/fast_path/trivial.kind/required_gates mismatch); "
                "re-open as standard/heavy. Evidence is not inherited."
            )
        return ([], True)

    # 非 trivial（standard/heavy 或旧 session）
    if raw_gates is None:
        # 旧 session 缺字段 → 回退要求 review（与原 record_environment/caps_info 行为一致）
        return (["review"], False)
    if not isinstance(raw_gates, list):
        raise SystemExit(
            "required_gates must be a list; re-open the session as standard/heavy."
        )
    if raw_gates == []:
        # 非 trivial 显式空 gates → fail closed（不可获得 available，不可 approve）
        raise SystemExit(
            "non-trivial session has explicitly empty required_gates; "
            "re-open as standard/heavy (the review gate is required)."
        )
    # 非 trivial 必须含 review（交叉校验，防篡改把 review 抹掉）
    if "review" not in raw_gates:
        raise SystemExit(
            "non-trivial session required_gates is missing the review gate; "
            "re-open as standard/heavy."
        )
    return (list(raw_gates), False)


if __name__ == "__main__":
    # 仅供 smoke：读 state 文件并打印判定
    from pathlib import Path
    import json

    if len(sys.argv) < 2:
        print("Usage: trivial_session.py <state.json>", file=sys.stderr)
        sys.exit(2)
    st = json.loads(Path(sys.argv[1]).read_text())
    gates, is_triv = resolve_required_gates(st)
    print(json.dumps({"gates": gates, "is_trivial": is_triv}))
