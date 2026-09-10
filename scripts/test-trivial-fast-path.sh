#!/usr/bin/env bash
# trivial fast-path 测试：覆盖合同 9 全部场景
# - 参数约束（trivial 必须带 --trivial-kind；pod-patch 必须带 dependency/from/to；standard 带 trivial-kind 拒绝）
# - schema v2 + fast_path + required_gates=[]；empty gates env 四项 not-required + available
# - trivial 禁止 configure-gates；未 validate 拒 approve
# - docs 允许（.md 新增/修改、根 README）；docs 控制面/delete/rename/mode/symlink/binary/self-repo 拒绝
# - pod-patch pass；minor/major/其他包/lock 结构变化拒绝
# - dirty（unstaged tracked）/untracked 拒绝；digest 漂移拒绝
# - standard review 回归；commit-blocked 禁止重复 commit
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$TMP_ROOT"' EXIT

/usr/bin/git -C "$TMP_ROOT" init -q -b main 2>/dev/null || { /usr/bin/git -C "$TMP_ROOT" init -q && /usr/bin/git -C "$TMP_ROOT" checkout -qb main; }
/usr/bin/git -C "$TMP_ROOT" config user.email "test@example.com"
/usr/bin/git -C "$TMP_ROOT" config user.name "test"
printf 'base\n' > "$TMP_ROOT/base.txt"
printf '.dev-flow/\nbin/\n__pycache__/\n*.pyc\n' > "$TMP_ROOT/.gitignore"
/usr/bin/git -C "$TMP_ROOT" add base.txt .gitignore
/usr/bin/git -C "$TMP_ROOT" commit -qm "init"

/bin/mkdir -p "$TMP_ROOT/.dev-flow/sessions" "$TMP_ROOT/bin"

# ok-probe（standard review 回归用）
cat > "$TMP_ROOT/bin/ok-probe" <<'EOF'
#!/usr/bin/env bash
/usr/bin/python3 - "${DEV_FLOW_SESSION_ID:-test}" <<'PY'
import json, sys
print(json.dumps({"status":"available","evidence":"test_probe",
                   "selected_adapter":"agent/openai-reviewer",
                   "config_digest":"sha256:3442e1b8bf278f94262e920076cfb201202958e4d5b5c43be1af25767202a7e9",
                   "source":"project"}))
PY
EOF
/bin/chmod +x "$TMP_ROOT/bin/ok-probe"

cp "$ROOT/rules/global-rules.md" "$TMP_ROOT/.dev-flow/global-rules.md"
cp "$ROOT/.dev-flow/rules.md" "$TMP_ROOT/.dev-flow/rules.md"

export DEV_FLOW_GLOBAL_RULES_FILE="$TMP_ROOT/.dev-flow/global-rules.md"
export DEV_FLOW_PROJECT_RULES_FILE="$TMP_ROOT/.dev-flow/rules.md"
export DEV_FLOW_PROJECT_ROOT="$TMP_ROOT"
export DEV_FLOW_SOURCE_ROOT="$ROOT"

run() {
  local sid="$1"; shift
  DEV_FLOW_SESSION_ID="$sid" /bin/bash "$ROOT/scripts/dev-flow-session.sh" "$@"
}

# shellcheck source=test-helper-inject-ticket.sh
source "$ROOT/scripts/test-helper-inject-ticket.sh"

run_health() {
  local sid="$1"
  DEV_FLOW_SESSION_ID="$sid" DEV_FLOW_TEST_MODE=1 \
    /bin/bash "$ROOT/scripts/environment-health-check.sh" run
}

clean_repo() {
  # reset 到根 commit（pods/docs 之前），保证 setup_pods_head 等能重新干净 commit
  local base
  base="$(/usr/bin/git -C "$TMP_ROOT" rev-list --max-parents=0 HEAD)"
  /usr/bin/git -C "$TMP_ROOT" reset -q --hard "$base"
  /usr/bin/git -C "$TMP_ROOT" clean -qfdx -- . ':!.dev-flow' ':!bin'
}

start_docs_session() {
  local sid="$1"
  run "$sid" start --type feature --level trivial --trivial-kind docs --task "docs" >/dev/null
  run "$sid" confirm-plan >/dev/null
  run_health "$sid" >/dev/null
}

assert_fail() { # assert_fail <label> <cmd...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "FAIL: $label should have been rejected" >&2
    exit 1
  fi
}

# ── 1. 参数约束 ──
assert_fail "trivial without --trivial-kind" run t-param1 start --type feature --level trivial --task "no kind"
assert_fail "trivial --trivial-kind bogus" run t-param2 start --type feature --level trivial --trivial-kind bogus --task "bad kind"
assert_fail "pod-patch without --dependency" run t-param3 start --type feature --level trivial --trivial-kind pod-patch --from-version 5.0.0 --to-version 5.0.1 --task "no dep"
assert_fail "pod-patch without --from-version" run t-param4 start --type feature --level trivial --trivial-kind pod-patch --dependency Alamofire --to-version 5.0.1 --task "no from"
assert_fail "pod-patch without --to-version" run t-param5 start --type feature --level trivial --trivial-kind pod-patch --dependency Alamofire --from-version 5.0.0 --task "no to"
assert_fail "standard with --trivial-kind" run t-param6 start --type feature --level standard --trivial-kind docs --task "std with kind"
echo "PASS: 1. 参数约束"

# ── 2. schema v2 + fast_path + empty gates env ──
run t2 start --type feature --level trivial --trivial-kind docs --task "schema" >/dev/null
run t2 confirm-plan >/dev/null
run_health t2 >/dev/null
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/t2.json" <<'PY'
import json, sys
from pathlib import Path
s = json.loads(Path(sys.argv[1]).read_text())
assert s["schema_version"] == 2, s
assert s["fast_path"] is True, s
assert s["required_gates"] == [], s
assert s["trivial"]["kind"] == "docs", s
assert s["trivial_validation"] is None, s
# trivial 空 gates 时 review gate result 必须为 not-required（与 required_gates=[] 语义一致）
assert s["gate_results"]["review"]["status"] == "not-required", s["gate_results"]
eh = s["environment_health"]
assert eh["status"] == "available", eh
for c in ("app_launch", "debugbridge", "review_mcp", "figma_rest_api"):
    assert eh["checks"][c]["status"] == "not-required", (c, eh["checks"][c])
PY
echo "PASS: 2. schema v2 + fast_path + empty gates env 四项 not-required + review gate not-required"

# ── 3. trivial 禁止 configure-gates ──
run t3 start --type feature --level trivial --trivial-kind docs --task "no cfg" >/dev/null
assert_fail "trivial configure-gates" run t3 configure-gates --required review
echo "PASS: 3. trivial 禁止 configure-gates"

# ── 4. 未 validate 拒 approve ──
start_docs_session t4
assert_fail "approve without validate" run t4 approve-commit
echo "PASS: 4. 未 validate 拒 approve"

# ── 5. docs 允许：.md 新增/修改、根 README ──
start_docs_session t5a
printf '# A\n\nbody\n' > "$TMP_ROOT/NOTES.md"
/usr/bin/git -C "$TMP_ROOT" add NOTES.md
run t5a validate-trivial >/dev/null
echo "PASS: 5a. docs .md 新增允许"

start_docs_session t5b
printf 'existing\n' > "$TMP_ROOT/EXISTING.md"
/usr/bin/git -C "$TMP_ROOT" add EXISTING.md
/usr/bin/git -C "$TMP_ROOT" commit -qm "add md"
printf 'existing\nchanged\n' > "$TMP_ROOT/EXISTING.md"
/usr/bin/git -C "$TMP_ROOT" add EXISTING.md
run t5b validate-trivial >/dev/null
echo "PASS: 5b. docs .md 修改允许"

start_docs_session t5c
printf 'readme\n' > "$TMP_ROOT/README"
/usr/bin/git -C "$TMP_ROOT" add README
run t5c validate-trivial >/dev/null
echo "PASS: 5c. docs 根 README 允许"

# ── 6. docs 控制面拒绝 ──
for f in SKILL.md AGENTS.md; do
  start_docs_session "t6-$f"
  printf 'x\n' > "$TMP_ROOT/$f"
  /usr/bin/git -C "$TMP_ROOT" add "$f"
  assert_fail "docs control-plane $f" run "t6-$f" validate-trivial
  clean_repo
done
echo "PASS: 6a. docs 控制面文件（SKILL.md/AGENTS.md）拒绝"

for d in scripts tests rules .github; do
  start_docs_session "t6d-$d"
  /bin/mkdir -p "$TMP_ROOT/$d"
  printf 'x\n' > "$TMP_ROOT/$d/foo.md"
  /usr/bin/git -C "$TMP_ROOT" add "$d/foo.md"
  assert_fail "docs control-plane dir $d" run "t6d-$d" validate-trivial
  clean_repo
done
echo "PASS: 6b. docs 控制面目录（scripts/tests/rules/.github）拒绝"

# 控制面配置文件
for f in Makefile Gemfile package.json Podfile Dockerfile; do
  start_docs_session "t6c-$f"
  printf 'x\n' > "$TMP_ROOT/$f"
  /usr/bin/git -C "$TMP_ROOT" add "$f"
  assert_fail "docs config file $f" run "t6c-$f" validate-trivial
  clean_repo
done
echo "PASS: 6c. docs 控制面配置文件拒绝"

# 非 docs 扩展名拒绝
start_docs_session t6e
printf 'code\n' > "$TMP_ROOT/code.txt"
/usr/bin/git -C "$TMP_ROOT" add code.txt
assert_fail "docs non-md extension" run t6e validate-trivial
clean_repo
echo "PASS: 6d. docs 非文档扩展名拒绝"

# ── 7. docs delete/rename/mode/symlink/binary 拒绝 ──
start_docs_session t7del
printf 'doc\n' > "$TMP_ROOT/TODEL.md"
/usr/bin/git -C "$TMP_ROOT" add TODEL.md
/usr/bin/git -C "$TMP_ROOT" commit -qm "add todel"
/usr/bin/git -C "$TMP_ROOT" rm TODEL.md >/dev/null
assert_fail "docs delete" run t7del validate-trivial
clean_repo
echo "PASS: 7a. docs delete 拒绝"

start_docs_session t7ren
printf 'doc\n' > "$TMP_ROOT/OLD.md"
/usr/bin/git -C "$TMP_ROOT" add OLD.md
/usr/bin/git -C "$TMP_ROOT" commit -qm "add old"
/usr/bin/git -C "$TMP_ROOT" mv OLD.md NEW.md >/dev/null
assert_fail "docs rename" run t7ren validate-trivial
clean_repo
echo "PASS: 7b. docs rename 拒绝"

start_docs_session t7sym
ln -s /etc/hosts "$TMP_ROOT/LINK.md"
/usr/bin/git -C "$TMP_ROOT" add LINK.md
assert_fail "docs symlink" run t7sym validate-trivial
clean_repo
echo "PASS: 7c. docs symlink 拒绝"

start_docs_session t7bin
printf 'ab\n\x00\x01\x02\n' > "$TMP_ROOT/BIN.md"
/usr/bin/git -C "$TMP_ROOT" add BIN.md
assert_fail "docs binary" run t7bin validate-trivial
clean_repo
echo "PASS: 7d. docs binary 拒绝"

# ── 8. 本仓库自身文档不能走 trivial（self-repo 判定）──
start_docs_session t8self
/bin/mkdir -p "$TMP_ROOT/skills"
/bin/mkdir -p "$TMP_ROOT/scripts"
printf 'stub\n' > "$TMP_ROOT/scripts/dev-flow-session.sh"
printf '# doc\n' > "$TMP_ROOT/SELFNOTES.md"
/usr/bin/git -C "$TMP_ROOT" add scripts/dev-flow-session.sh SELFNOTES.md
assert_fail "self-repo docs" run t8self validate-trivial
clean_repo
echo "PASS: 8. 本仓库自身文档不能走 trivial"

# ── 9. pod-patch pass ──
# podfile_sha1：计算 Podfile 内容 SHA-1，模拟 pod install 自动生成的 PODFILE CHECKSUM
podfile_sha1() {
  /usr/bin/python3 -c 'import hashlib,sys; print(hashlib.sha1(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}
setup_pods_head() {
  cat > "$TMP_ROOT/Podfile" <<'EOF'
platform :ios, '13.0'
target 'App' do
  use_frameworks!
  pod 'Alamofire', '5.0.0'
  pod 'SwiftyJSON', '5.0.0'
end
EOF
  local pfc; ppc="$(podfile_sha1 "$TMP_ROOT/Podfile")"
  cat > "$TMP_ROOT/Podfile.lock" <<EOF
PODS:
  - Alamofire (5.0.0)
  - SwiftyJSON (5.0.0)

DEPENDENCIES:
  - Alamofire (= 5.0.0)
  - SwiftyJSON (= 5.0.0)

SPEC REPOS:
  trunk:
    - Alamofire
    - SwiftyJSON

SPEC CHECKSUMS:
  Alamofire: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  SwiftyJSON: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

PODFILE CHECKSUM: $ppc

COCOAPODS: 1.10.0
EOF
  /usr/bin/git -C "$TMP_ROOT" add Podfile Podfile.lock
  /usr/bin/git -C "$TMP_ROOT" commit -qm "pods"
}

start_pod_session() {
  local sid="$1" fv="$2" tv="$3"
  run "$sid" start --type feature --level trivial --trivial-kind pod-patch \
    --dependency Alamofire --from-version "$fv" --to-version "$tv" --task "pod" >/dev/null
  run "$sid" confirm-plan >/dev/null
  run_health "$sid" >/dev/null
}

clean_repo
setup_pods_head
/usr/bin/sed -i '' "s/pod 'Alamofire', '5.0.0'/pod 'Alamofire', '5.0.1'/" "$TMP_ROOT/Podfile"
local_pfc="$(podfile_sha1 "$TMP_ROOT/Podfile")"
cat > "$TMP_ROOT/Podfile.lock" <<EOF
PODS:
  - Alamofire (5.0.1)
  - SwiftyJSON (5.0.0)

DEPENDENCIES:
  - Alamofire (= 5.0.1)
  - SwiftyJSON (= 5.0.0)

SPEC REPOS:
  trunk:
    - Alamofire
    - SwiftyJSON

SPEC CHECKSUMS:
  Alamofire: cccccccccccccccccccccccccccccccccccccccc
  SwiftyJSON: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

PODFILE CHECKSUM: $local_pfc

COCOAPODS: 1.10.0
EOF
/usr/bin/git -C "$TMP_ROOT" add Podfile Podfile.lock
start_pod_session t9 5.0.0 5.0.1
run t9 validate-trivial >/dev/null
run t9 approve-commit >/dev/null
run t9 commit --message "pod: bump Alamofire 5.0.0->5.0.1" >/dev/null
echo "PASS: 9. pod-patch pass 全链路"

# ── 10. pod-patch minor 变化拒绝 ──
clean_repo
setup_pods_head
/usr/bin/sed -i '' "s/pod 'Alamofire', '5.0.0'/pod 'Alamofire', '5.1.0'/" "$TMP_ROOT/Podfile"
/usr/bin/sed -i '' 's/Alamofire (5.0.0)/Alamofire (5.1.0)/' "$TMP_ROOT/Podfile.lock"
# 同步更新 PODFILE CHECKSUM（确保因版本问题而非 checksum 不匹配被拒）
/usr/bin/sed -i '' "s/^PODFILE CHECKSUM: .*/PODFILE CHECKSUM: $(podfile_sha1 "$TMP_ROOT/Podfile")/" "$TMP_ROOT/Podfile.lock"
/usr/bin/git -C "$TMP_ROOT" add Podfile Podfile.lock
start_pod_session t10 5.0.0 5.1.0
assert_fail "pod minor bump" run t10 validate-trivial
echo "PASS: 10. pod-patch minor 变化拒绝"

# ── 11. pod-patch major 变化拒绝 ──
clean_repo
setup_pods_head
/usr/bin/sed -i '' "s/pod 'Alamofire', '5.0.0'/pod 'Alamofire', '6.0.0'/" "$TMP_ROOT/Podfile"
/usr/bin/sed -i '' 's/Alamofire (5.0.0)/Alamofire (6.0.0)/' "$TMP_ROOT/Podfile.lock"
/usr/bin/sed -i '' "s/^PODFILE CHECKSUM: .*/PODFILE CHECKSUM: $(podfile_sha1 "$TMP_ROOT/Podfile")/" "$TMP_ROOT/Podfile.lock"
/usr/bin/git -C "$TMP_ROOT" add Podfile Podfile.lock
start_pod_session t11 5.0.0 6.0.0
assert_fail "pod major bump" run t11 validate-trivial
echo "PASS: 11. pod-patch major 变化拒绝"

# ── 12. pod-patch 其他包变化拒绝 ──
clean_repo
setup_pods_head
/usr/bin/sed -i '' "s/pod 'Alamofire', '5.0.0'/pod 'Alamofire', '5.0.1'/" "$TMP_ROOT/Podfile"
/usr/bin/sed -i '' "s/pod 'SwiftyJSON', '5.0.0'/pod 'SwiftyJSON', '5.0.1'/" "$TMP_ROOT/Podfile"
/usr/bin/sed -i '' 's/Alamofire (5.0.0)/Alamofire (5.0.1)/' "$TMP_ROOT/Podfile.lock"
/usr/bin/sed -i '' 's/SwiftyJSON (5.0.0)/SwiftyJSON (5.0.1)/' "$TMP_ROOT/Podfile.lock"
/usr/bin/sed -i '' "s/^PODFILE CHECKSUM: .*/PODFILE CHECKSUM: $(podfile_sha1 "$TMP_ROOT/Podfile")/" "$TMP_ROOT/Podfile.lock"
/usr/bin/git -C "$TMP_ROOT" add Podfile Podfile.lock
start_pod_session t12 5.0.0 5.0.1
assert_fail "pod other package change" run t12 validate-trivial
echo "PASS: 12. pod-patch 其他包变化拒绝"

# ── 13. pod-patch lock 结构变化（COCOAPODS）拒绝 ──
clean_repo
setup_pods_head
/usr/bin/sed -i '' "s/pod 'Alamofire', '5.0.0'/pod 'Alamofire', '5.0.1'/" "$TMP_ROOT/Podfile"
/usr/bin/sed -i '' 's/Alamofire (5.0.0)/Alamofire (5.0.1)/' "$TMP_ROOT/Podfile.lock"
/usr/bin/sed -i '' 's/COCOAPODS: 1.10.0/COCOAPODS: 1.11.0/' "$TMP_ROOT/Podfile.lock"
/usr/bin/sed -i '' "s/^PODFILE CHECKSUM: .*/PODFILE CHECKSUM: $(podfile_sha1 "$TMP_ROOT/Podfile")/" "$TMP_ROOT/Podfile.lock"
/usr/bin/git -C "$TMP_ROOT" add Podfile Podfile.lock
start_pod_session t13 5.0.0 5.0.1
assert_fail "pod lock COCOAPODS change" run t13 validate-trivial
echo "PASS: 13. pod-patch lockfile COCOAPODS 变化拒绝"

# ── 14. dirty（unstaged tracked）拒绝 ──
clean_repo
start_docs_session t14
printf 'doc\n' > "$TMP_ROOT/D.md"
/usr/bin/git -C "$TMP_ROOT" add D.md
run t14 validate-trivial >/dev/null
printf 'dirty\n' >> "$TMP_ROOT/D.md"  # unstaged tracked change after validate
assert_fail "approve with dirty worktree" run t14 approve-commit
echo "PASS: 14. dirty（unstaged）拒绝 approve"

# ── 15. untracked 拒绝 ──
clean_repo
start_docs_session t15
printf 'doc\n' > "$TMP_ROOT/U.md"
/usr/bin/git -C "$TMP_ROOT" add U.md
run t15 validate-trivial >/dev/null
printf 'untracked\n' > "$TMP_ROOT/UNTRACKED.md"  # non-ignored untracked after validate
assert_fail "approve with untracked" run t15 approve-commit
echo "PASS: 15. untracked 拒绝 approve"

# ── 16. digest 漂移拒绝（validate 后改暂存区内容）──
clean_repo
start_docs_session t16
printf 'doc v1\n' > "$TMP_ROOT/V.md"
/usr/bin/git -C "$TMP_ROOT" add V.md
run t16 validate-trivial >/dev/null
printf 'doc v2 changed\n' > "$TMP_ROOT/V.md"
/usr/bin/git -C "$TMP_ROOT" add V.md  # re-stage different content → digest drift
assert_fail "approve with digest drift" run t16 approve-commit
echo "PASS: 16. digest 漂移拒绝 approve"

# ── 17. standard review 回归（standard 仍走 review gate）──
clean_repo
run t17 start --type feature --level standard --task "std review" >/dev/null
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/t17.json" <<'PY'
import json, sys
from pathlib import Path
s = json.loads(Path(sys.argv[1]).read_text())
assert s["fast_path"] is False, s
assert s["required_gates"] == ["review"], s
assert s.get("trivial") is None, s
PY
run t17 confirm-plan >/dev/null
DEV_FLOW_SESSION_ID=t17 DEV_FLOW_TEST_MODE=1 \
  DEV_FLOW_REVIEW_MCP_HEALTH_CMD="$TMP_ROOT/bin/ok-probe" \
  /bin/bash "$ROOT/scripts/environment-health-check.sh" run >/dev/null
# standard 未 record review gate → approve 拒绝
assert_fail "standard approve without review gate" run t17 approve-commit
# 注入 review ticket + pass
ticket_info="$(inject_review_ticket "t17" "agent/openai-reviewer" "sha256:3442e1b8bf278f94262e920076cfb201202958e4d5b5c43be1af25767202a7e9" "code-quality-review" "$TMP_ROOT/.dev-flow/sessions/t17.json" "$TMP_ROOT")"
tt="${ticket_info% *}"
td="${ticket_info#* }"
ra_info="$(inject_result_artifact "t17" "$TMP_ROOT/.dev-flow/sessions/t17.json" "$TMP_ROOT" "pass" "t17-run" "std review pass")"
ra_path="${ra_info% *}"
ra_digest="${ra_info#* }"
/usr/bin/python3 - "$TMP_ROOT" "t17" "$tt" "$td" "$ra_path" "$ra_digest" <<'PY'
import json, sys, hashlib
from pathlib import Path
root = Path(sys.argv[1]); sid = sys.argv[2]
tt, td, ra_path, ra_digest = sys.argv[3:7]
run_id = "t17-run"; ref = f"test-host-ref-{run_id}"
digest = "sha256:" + hashlib.sha256(f"test-handoff-{run_id}".encode()).hexdigest()
(root / ".dev-flow" / "sessions" / f"review-{sid}.json").write_text(json.dumps({
    "producer": "code-review-workflow", "schema_version": 1, "session_id": sid, "gate": "review",
    "status": "pass", "reviewer_result": "pass", "evidence": "std review pass",
    "selected_adapter": "agent/openai-reviewer",
    "config_digest": "sha256:3442e1b8bf278f94262e920076cfb201202958e4d5b5c43be1af25767202a7e9",
    "run_id": run_id, "diff_evidence": "sha256:" + hashlib.sha256(b"std-diff").hexdigest(),
    "adapter_result_ref": ref, "adapter_result_digest": digest,
    "ticket_token": tt, "ticket_digest": td,
    "result_artifact": ra_path, "result_artifact_digest": ra_digest,
}) + "\n")
PY
run t17 record-gate --name review --report "$TMP_ROOT/.dev-flow/sessions/review-t17.json" >/dev/null
run t17 approve-commit >/dev/null
echo "PASS: 17. standard review 回归"

# ── 18. commit-blocked 禁止重复 commit ──
start_docs_session t18
printf 'doc\n' > "$TMP_ROOT/CB.md"
/usr/bin/git -C "$TMP_ROOT" add CB.md
run t18 validate-trivial >/dev/null
run t18 approve-commit >/dev/null
# 手动注入 commit_blocked 状态（模拟 hook 改写后的冻结态）
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/t18.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
s = json.loads(p.read_text())
s["commit_blocked"] = {
    "commit_hash": "deadbeef", "expected_parent": "aaa", "actual_parent": "bbb",
    "expected_tree": "ccc", "actual_tree": "ddd",
    "blocked_at": "2026-01-01T00:00:00Z",
    "reason": "simulated post-commit mismatch",
}
p.write_text(json.dumps(s, ensure_ascii=False, indent=2) + "\n")
PY
assert_fail "commit when commit-blocked" run t18 commit --message "should fail"
echo "PASS: 18. commit-blocked 禁止重复 commit"

# ── 19. 冻结态（requires-standard）禁止 approve/commit/validate ──
start_docs_session t19
printf 'src\n' > "$TMP_ROOT/src.txt"  # non-doc → out of scope
/usr/bin/git -C "$TMP_ROOT" add src.txt
run t19 validate-trivial >/dev/null 2>&1 || true  # validate 失败并标记冻结
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/t19.json" <<'PY'
import json, sys
from pathlib import Path
s = json.loads(Path(sys.argv[1]).read_text())
tv = s.get("trivial_validation") or {}
assert tv.get("escalation") == "requires-standard", tv
PY
assert_fail "approve when frozen" run t19 approve-commit
assert_fail "commit when frozen" run t19 commit --message "no"
assert_fail "validate when frozen" run t19 validate-trivial
echo "PASS: 19. 冻结态（requires-standard）禁止 approve/commit/validate"

# ── 20. 混合合法 docs + staged .dev-flow/ 控制面必拒（issue #1）──
# 旧实现跳过 staged .dev-flow/ 条目，混合一个合法 docs 即可把控制面带入提交；
# 修复后不得跳过任何 staged 条目，.dev-flow/ staged 由 docs 控制面规则拒绝。
clean_repo
start_docs_session t20
printf 'doc\n' > "$TMP_ROOT/NOTES.md"
/usr/bin/git -C "$TMP_ROOT" add NOTES.md
# 强制 stage .dev-flow/ 控制面文件（.dev-flow/ 已 gitignore，需 -f）
printf 'control\n' > "$TMP_ROOT/.dev-flow/sneaky.md"
/usr/bin/git -C "$TMP_ROOT" add -f .dev-flow/sneaky.md
assert_fail "mixed docs + staged .dev-flow/" run t20 validate-trivial
clean_repo
echo "PASS: 20. 混合合法 docs + staged .dev-flow/ 控制面必拒"

# ── 21. lockfile 注释/任意行带 dependency 名必拒（issue #2）──
# 旧实现只要求变更行包含依赖子串，带依赖名的注释/伪装行会被忽略而通过；
# 修复后每个 +/- 行必须精确分类为 PODS/DEPENDENCIES/checksum，否则 fail closed。
clean_repo
setup_pods_head
/usr/bin/sed -i '' "s/pod 'Alamofire', '5.0.0'/pod 'Alamofire', '5.0.1'/" "$TMP_ROOT/Podfile"
cat > "$TMP_ROOT/Podfile.lock" <<'EOF'
PODS:
  - Alamofire (5.0.1)
  - SwiftyJSON (5.0.0)

DEPENDENCIES:
  - Alamofire (= 5.0.1)
  - SwiftyJSON (= 5.0.0)

SPEC REPOS:
  trunk:
    - Alamofire
    - SwiftyJSON

SPEC CHECKSUMS:
  Alamofire: cccccccccccccccccccccccccccccccccccccccc
  SwiftyJSON: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

PODFILE CHECKSUM: 0123456789abcdef0123456789abcdef01234567

COCOAPODS: 1.10.0
# Alamofire: disguised malicious note
EOF
/usr/bin/git -C "$TMP_ROOT" add Podfile Podfile.lock
start_pod_session t21 5.0.0 5.0.1
assert_fail "lockfile comment line with dep name" run t21 validate-trivial
echo "PASS: 21. lockfile 注释/任意行带 dependency 名必拒"

# ── 22. lockfile 重复核心版本行必拒（issue #2）──
# 旧实现用 dict 覆盖无法证明版本行唯一；修复后 PODS 版本行必须有且仅有一对。
clean_repo
# 自定义 HEAD：PODS 段 Alamofire 出现两次（模拟 subspec 嵌套）
cat > "$TMP_ROOT/Podfile" <<'EOF'
platform :ios, '13.0'
target 'App' do
  use_frameworks!
  pod 'Alamofire', '5.0.0'
  pod 'SomeSub', '1.0.0'
end
EOF
cat > "$TMP_ROOT/Podfile.lock" <<'EOF'
PODS:
  - Alamofire (5.0.0)
  - SomeSub (1.0.0):
    - Alamofire (5.0.0)

DEPENDENCIES:
  - Alamofire (= 5.0.0)
  - SomeSub (= 5.0.0)

SPEC REPOS:
  trunk:
    - Alamofire
    - SomeSub

SPEC CHECKSUMS:
  Alamofire: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  SomeSub: ssssssssssssssssssssssssssssssssssssssss

PODFILE CHECKSUM: 0123456789abcdef0123456789abcdef01234567

COCOAPODS: 1.10.0
EOF
/usr/bin/git -C "$TMP_ROOT" add Podfile Podfile.lock
/usr/bin/git -C "$TMP_ROOT" commit -qm "pods dup"
# index：两处 Alamofire 都 bump 到 5.0.1
/usr/bin/sed -i '' "s/pod 'Alamofire', '5.0.0'/pod 'Alamofire', '5.0.1'/" "$TMP_ROOT/Podfile"
/usr/bin/sed -i '' 's/Alamofire (5.0.0)/Alamofire (5.0.1)/g' "$TMP_ROOT/Podfile.lock"
/usr/bin/sed -i '' 's/Alamofire (= 5.0.0)/Alamofire (= 5.0.1)/g' "$TMP_ROOT/Podfile.lock"
/usr/bin/git -C "$TMP_ROOT" add Podfile Podfile.lock
start_pod_session t22 5.0.0 5.0.1
assert_fail "lockfile duplicate core version lines" run t22 validate-trivial
echo "PASS: 22. lockfile 重复核心版本行必拒"

# ── 23. lockfile 错误 DEPENDENCIES 版本对必拒（issue #2）──
# PODS 正确 5.0.0→5.0.1，但 DEPENDENCIES 写成 5.0.0→5.0.2（≠ to_version）。
clean_repo
setup_pods_head
/usr/bin/sed -i '' "s/pod 'Alamofire', '5.0.0'/pod 'Alamofire', '5.0.1'/" "$TMP_ROOT/Podfile"
cat > "$TMP_ROOT/Podfile.lock" <<'EOF'
PODS:
  - Alamofire (5.0.1)
  - SwiftyJSON (5.0.0)

DEPENDENCIES:
  - Alamofire (= 5.0.2)
  - SwiftyJSON (= 5.0.0)

SPEC REPOS:
  trunk:
    - Alamofire
    - SwiftyJSON

SPEC CHECKSUMS:
  Alamofire: cccccccccccccccccccccccccccccccccccccccc
  SwiftyJSON: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

PODFILE CHECKSUM: 0123456789abcdef0123456789abcdef01234567

COCOAPODS: 1.10.0
EOF
/usr/bin/git -C "$TMP_ROOT" add Podfile Podfile.lock
start_pod_session t23 5.0.0 5.0.1
assert_fail "lockfile wrong DEPENDENCIES version pair" run t23 validate-trivial
echo "PASS: 23. lockfile 错误 DEPENDENCIES 版本对必拒"

# ── 24. 手工篡改 standard session required_gates=[] 后 environment-health 必拒（issue #3）──
clean_repo
run t24 start --type feature --level standard --task "tamper std" >/dev/null
run t24 confirm-plan >/dev/null
# 手工篡改：把 standard 的 required_gates 改成空（模拟绕过），同步篡改 gate_results
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/t24.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
s = json.loads(p.read_text())
s["required_gates"] = []
s["gate_results"] = {k: {"status": "not-required", "evidence": None, "recorded_at": None}
                     for k in ("figma_ui", "review", "runtime", "ui_parity")}
p.write_text(json.dumps(s, ensure_ascii=False, indent=2) + "\n")
PY
assert_fail "tampered standard empty gates env-health" run_health t24
echo "PASS: 24. 篡改 standard required_gates=[] 后 environment-health 必拒"

# ── 25. 篡改 standard required_gates=[] + 注入伪 env 后 approve 必拒（issue #3）──
# 既篡改 gates 又伪造 available env（模拟完整绕过），测 approve 的 resolve 深度防御。
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/t24.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
s = json.loads(p.read_text())
s["environment_health"] = {
    "status": "available", "checked_at": "2026-09-10T00:00:00Z",
    "checks": {c: {"status": "not-required", "evidence": "tampered"} for c in
               ("app_launch", "debugbridge", "review_mcp", "figma_rest_api")},
    "required_gates": [], "required_capabilities": [],
}
# confirmed_at 不晚于 checked_at，通过 env 门禁时序校验，逼出 resolve 防御
s["confirmed_at"] = "2026-09-10T00:00:00Z"
p.write_text(json.dumps(s, ensure_ascii=False, indent=2) + "\n")
PY
assert_fail "tampered standard empty gates approve" run t24 approve-commit
echo "PASS: 25. 篡改 standard required_gates=[] + 伪 env 后 approve 必拒"

# ── 26. 自相矛盾 trivial state 必拒（issue #3）──
# trivial session 的 required_gates 被改成 ["review"]（与 trivial 空 gates 自相矛盾）。
clean_repo
run t26 start --type feature --level trivial --trivial-kind docs --task "contradict" >/dev/null
run t26 confirm-plan >/dev/null
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/t26.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
s = json.loads(p.read_text())
s["required_gates"] = ["review"]
p.write_text(json.dumps(s, ensure_ascii=False, indent=2) + "\n")
PY
assert_fail "contradictory trivial env-health" run_health t26
assert_fail "contradictory trivial validate" run t26 validate-trivial
echo "PASS: 26. 自相矛盾 trivial state 必拒（env-health + validate）"

# ── 27. Podfile 同一 dependency 重复声明必拒（issue #1 收口）──
# 旧实现 _podfile_version_line 取第一个匹配，修改第二个声明时 HEAD from 绑定仍通过。
# 修复后 HEAD 与 index 中目标 dependency 精确版本声明必须各恰好 1 条。
clean_repo
cat > "$TMP_ROOT/Podfile" <<'EOF'
platform :ios, '13.0'
target 'App' do
  use_frameworks!
  pod 'Alamofire', '5.0.0'
  pod 'Alamofire', '5.0.0'
  pod 'SwiftyJSON', '5.0.0'
end
EOF
cat > "$TMP_ROOT/Podfile.lock" <<'EOF'
PODS:
  - Alamofire (5.0.0)
  - SwiftyJSON (5.0.0)

DEPENDENCIES:
  - Alamofire (= 5.0.0)
  - SwiftyJSON (= 5.0.0)

SPEC REPOS:
  trunk:
    - Alamofire
    - SwiftyJSON

SPEC CHECKSUMS:
  Alamofire: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  SwiftyJSON: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

PODFILE CHECKSUM: 0123456789abcdef0123456789abcdef01234567

COCOAPODS: 1.10.0
EOF
/usr/bin/git -C "$TMP_ROOT" add Podfile Podfile.lock
/usr/bin/git -C "$TMP_ROOT" commit -qm "pods dup decl"
# index：只改第二个 Alamofire 声明 → HEAD 仍有两条 5.0.0，index 仍两条但一条变 5.0.1
/usr/bin/sed -i '' '0,/pod .Alamofire., .5.0.0./!s/pod .Alamofire., .5.0.0./pod '"'"'Alamofire'"'"', '"'"'5.0.1'"'"'/' "$TMP_ROOT/Podfile" 2>/dev/null || \
  /usr/bin/python3 -c "
import re
p='$TMP_ROOT/Podfile'
lines=open(p).read().splitlines()
seen=0
for i,l in enumerate(lines):
    if \"pod 'Alamofire', '5.0.0'\" in l:
        if seen==1:
            lines[i]=l.replace('5.0.0','5.0.1')
        seen+=1
open(p,'w').write('\n'.join(lines)+'\n')
"
/usr/bin/sed -i '' 's/Alamofire (5.0.0)/Alamofire (5.0.1)/' "$TMP_ROOT/Podfile.lock"
/usr/bin/sed -i '' 's/Alamofire (= 5.0.0)/Alamofire (= 5.0.1)/' "$TMP_ROOT/Podfile.lock"
/usr/bin/sed -i '' 's/Alamofire: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/Alamofire: cccccccccccccccccccccccccccccccccccccccc/' "$TMP_ROOT/Podfile.lock"
/usr/bin/git -C "$TMP_ROOT" add Podfile Podfile.lock
start_pod_session t27 5.0.0 5.0.1
assert_fail "Podfile duplicate declaration" run t27 validate-trivial
echo "PASS: 27. Podfile 同一 dependency 重复声明必拒"

# ── 28. lockfile 伪造 checksum 形状放在 COCOAPODS/未知 section 后必拒（issue #2/#3 收口）──
# 旧解析器不正确终止 section，COCOAPODS: 后的缩进行会被误算进前一个 section。
# 修复后 _parse_lockfile_sections 正确终止 block，COCOAPODS: 归入 <scalar>；
# 伪造的 `Alamofire: <hex>` checksum 形状行在 COCOAPODS 后不会进入 SPEC CHECKSUMS，
# 但会出现在 diff 内容行中被 ck_pat 误匹配 → ck_plus 变 2 条，与 ck_minus 不平衡 → 拒绝。
# PODFILE CHECKSUM 用真实 SHA-1，确保因伪造 checksum 行被拒而非 checksum 标量不匹配。
clean_repo
setup_pods_head
/usr/bin/sed -i '' "s/pod 'Alamofire', '5.0.0'/pod 'Alamofire', '5.0.1'/" "$TMP_ROOT/Podfile"
local_pfc="$(podfile_sha1 "$TMP_ROOT/Podfile")"
cat > "$TMP_ROOT/Podfile.lock" <<EOF
PODS:
  - Alamofire (5.0.1)
  - SwiftyJSON (5.0.0)

DEPENDENCIES:
  - Alamofire (= 5.0.1)
  - SwiftyJSON (= 5.0.0)

SPEC REPOS:
  trunk:
    - Alamofire
    - SwiftyJSON

SPEC CHECKSUMS:
  Alamofire: cccccccccccccccccccccccccccccccccccccccc
  SwiftyJSON: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

PODFILE CHECKSUM: $local_pfc

COCOAPODS: 1.10.0
  Alamofire: ffffffffffffffffffffffffffffffffffffffff
EOF
/usr/bin/git -C "$TMP_ROOT" add Podfile Podfile.lock
start_pod_session t28 5.0.0 5.0.1
assert_fail "lockfile fake checksum shape after COCOAPODS" run t28 validate-trivial
echo "PASS: 28. lockfile 伪造 checksum 形状放在 COCOAPODS 后必拒"

# ── 29. validate A→approve→stage B→revalidate 后未重新 approve 的 commit 必拒（issue #3 收口）──
# 攻击路径：validate A → approve（绑定 A 的 scope）→ 修改并重新 stage B → validate B（清除旧 approval）
# → commit。修复后 revalidate 清除 approved_scope，commit 因无 approved_scope 绑定而拒绝；
# 重新 approve 后（绑定 B 的 scope）才可继续。
clean_repo
start_docs_session t29
printf 'doc A\n' > "$TMP_ROOT/ADOC.md"
/usr/bin/git -C "$TMP_ROOT" add ADOC.md
run t29 validate-trivial >/dev/null
run t29 approve-commit >/dev/null
# 验证 approved_scope 已绑定（绑定 A 的 scope）
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/t29.json" <<'PY'
import json, sys
from pathlib import Path
s = json.loads(Path(sys.argv[1]).read_text())
assert s.get("commit_approved_at") is not None, s
assert s.get("approved_scope", {}).get("scope_digest"), s
PY
# 修改并重新 stage B（不同内容 → digest 漂移）
printf 'doc B different\n' > "$TMP_ROOT/ADOC.md"
/usr/bin/git -C "$TMP_ROOT" add ADOC.md
# revalidate B：成功（B 仍是合法 docs），但必须清除旧 commit approval
run t29 validate-trivial >/dev/null
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/t29.json" <<'PY'
import json, sys
from pathlib import Path
s = json.loads(Path(sys.argv[1]).read_text())
# revalidate 后旧 approval 必须被清除（issue #3）
assert s.get("commit_approved_at") is None, s
assert s.get("approved_scope") is None, s
# trivial_validation 应反映 B 的 scope（result==pass）
assert s["trivial_validation"]["result"] == "pass", s["trivial_validation"]
PY
# commit 必拒：revalidate 后未重新 approve，approved_scope 为 None
assert_fail "commit after revalidate without re-approve" run t29 commit --message "should fail"
# 重新 approve 后才可继续（绑定 B 的 scope）
run t29 approve-commit >/dev/null
/usr/bin/python3 - "$TMP_ROOT/.dev-flow/sessions/t29.json" <<'PY'
import json, sys
from pathlib import Path
s = json.loads(Path(sys.argv[1]).read_text())
assert s.get("commit_approved_at") is not None, s
assert s.get("approved_scope", {}).get("scope_digest") == s["trivial_validation"]["scope_digest"], s
PY
echo "PASS: 29. validate A→approve→stage B→revalidate 后未重新 approve 的 commit 必拒；重新 approve 后可继续"

# ── 30. 真实 CocoaPods Podfile.lock 格式全链路通过（issue #1/#2/#4 真实格式回归）──
# 真实格式：PODS/DEPENDENCIES/SPEC REPOS/SPEC CHECKSUMS block + PODFILE CHECKSUM/COCOAPODS 顶层标量。
# PODFILE CHECKSUM 用真实 SHA-1(HEAD Podfile) / SHA-1(index Podfile)，Podfile 变化后二者不同。
# 确保真实格式（含 SPEC REPOS 含 cdn 子项、PODFILE CHECKSUM 标量变化）正常通过
# validate/approve/commit，不会因 section 解析或 PODFILE CHECKSUM 绑定而 fail closed。
clean_repo
cat > "$TMP_ROOT/Podfile" <<'EOF'
platform :ios, '13.0'
target 'App' do
  use_frameworks!
  pod 'Alamofire', '5.0.0'
  pod 'SwiftyJSON', '5.0.0'
end
EOF
head_pfc="$(podfile_sha1 "$TMP_ROOT/Podfile")"
cat > "$TMP_ROOT/Podfile.lock" <<EOF
PODS:
  - Alamofire (5.0.0)
  - SwiftyJSON (5.0.0)

DEPENDENCIES:
  - Alamofire (= 5.0.0)
  - SwiftyJSON (= 5.0.0)

SPEC REPOS:
  https://cdn.cocoapods.org/:
    - Alamofire
    - SwiftyJSON

SPEC CHECKSUMS:
  Alamofire: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  SwiftyJSON: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

PODFILE CHECKSUM: $head_pfc

COCOAPODS: 1.11.2
EOF
/usr/bin/git -C "$TMP_ROOT" add Podfile Podfile.lock
/usr/bin/git -C "$TMP_ROOT" commit -qm "real pods"
/usr/bin/sed -i '' "s/pod 'Alamofire', '5.0.0'/pod 'Alamofire', '5.0.1'/" "$TMP_ROOT/Podfile"
/usr/bin/sed -i '' 's/Alamofire (5.0.0)/Alamofire (5.0.1)/' "$TMP_ROOT/Podfile.lock"
/usr/bin/sed -i '' 's/Alamofire (= 5.0.0)/Alamofire (= 5.0.1)/' "$TMP_ROOT/Podfile.lock"
/usr/bin/sed -i '' 's/Alamofire: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/Alamofire: cccccccccccccccccccccccccccccccccccccccc/' "$TMP_ROOT/Podfile.lock"
# Podfile 变了 → PODFILE CHECKSUM 必须更新为 SHA-1(index Podfile)
index_pfc="$(podfile_sha1 "$TMP_ROOT/Podfile")"
/usr/bin/sed -i '' "s/^PODFILE CHECKSUM: .*/PODFILE CHECKSUM: $index_pfc/" "$TMP_ROOT/Podfile.lock"
/usr/bin/git -C "$TMP_ROOT" add Podfile Podfile.lock
start_pod_session t30 5.0.0 5.0.1
run t30 validate-trivial >/dev/null
run t30 approve-commit >/dev/null
run t30 commit --message "pod: bump Alamofire 5.0.0->5.0.1 (real format)" >/dev/null
echo "PASS: 30. 真实 CocoaPods Podfile.lock 格式全链路通过"

# ── 31. PODFILE CHECKSUM 缺失必拒（issue #4）──
# Podfile.lock 没有 PODFILE CHECKSUM scalar 行 → fail closed
clean_repo
cat > "$TMP_ROOT/Podfile" <<'EOF'
platform :ios, '13.0'
target 'App' do
  use_frameworks!
  pod 'Alamofire', '5.0.0'
  pod 'SwiftyJSON', '5.0.0'
end
EOF
# 故意不放 PODFILE CHECKSUM 行
cat > "$TMP_ROOT/Podfile.lock" <<'EOF'
PODS:
  - Alamofire (5.0.0)
  - SwiftyJSON (5.0.0)

DEPENDENCIES:
  - Alamofire (= 5.0.0)
  - SwiftyJSON (= 5.0.0)

SPEC CHECKSUMS:
  Alamofire: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  SwiftyJSON: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

COCOAPODS: 1.10.0
EOF
/usr/bin/git -C "$TMP_ROOT" add Podfile Podfile.lock
/usr/bin/git -C "$TMP_ROOT" commit -qm "pods no checksum"
/usr/bin/sed -i '' "s/pod 'Alamofire', '5.0.0'/pod 'Alamofire', '5.0.1'/" "$TMP_ROOT/Podfile"
/usr/bin/sed -i '' 's/Alamofire (5.0.0)/Alamofire (5.0.1)/' "$TMP_ROOT/Podfile.lock"
/usr/bin/sed -i '' 's/Alamofire: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/Alamofire: cccccccccccccccccccccccccccccccccccccccc/' "$TMP_ROOT/Podfile.lock"
/usr/bin/git -C "$TMP_ROOT" add Podfile Podfile.lock
start_pod_session t31 5.0.0 5.0.1
assert_fail "pod-patch missing PODFILE CHECKSUM" run t31 validate-trivial
echo "PASS: 31. PODFILE CHECKSUM 缺失必拒"

# ── 32. PODFILE CHECKSUM 值不匹配 SHA-1(Podfile) 必拒（issue #4）──
# PODFILE CHECKSUM 存在但值是假的（不等于 SHA-1(HEAD Podfile)）
clean_repo
setup_pods_head
# 用 sed 把 PODFILE CHECKSUM 改成假值（40 hex 但不是真实 SHA-1）
/usr/bin/sed -i '' 's/^PODFILE CHECKSUM: .*/PODFILE CHECKSUM: fedcba0987654321fedcba0987654321fedcba09/' "$TMP_ROOT/Podfile.lock"
/usr/bin/git -C "$TMP_ROOT" add Podfile.lock
/usr/bin/git -C "$TMP_ROOT" commit -qm "pods fake checksum" -- Podfile.lock
# 现在再改 Podfile + lockfile 做正常 patch
/usr/bin/sed -i '' "s/pod 'Alamofire', '5.0.0'/pod 'Alamofire', '5.0.1'/" "$TMP_ROOT/Podfile"
/usr/bin/sed -i '' 's/Alamofire (5.0.0)/Alamofire (5.0.1)/' "$TMP_ROOT/Podfile.lock"
/usr/bin/sed -i '' 's/Alamofire: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/Alamofire: cccccccccccccccccccccccccccccccccccccccc/' "$TMP_ROOT/Podfile.lock"
# index PODFILE CHECKSUM 也用假值
/usr/bin/sed -i '' 's/^PODFILE CHECKSUM: .*/PODFILE CHECKSUM: 0123456789abcdef0123456789abcdef01234567/' "$TMP_ROOT/Podfile.lock"
/usr/bin/git -C "$TMP_ROOT" add Podfile Podfile.lock
start_pod_session t32 5.0.0 5.0.1
assert_fail "pod-patch wrong PODFILE CHECKSUM" run t32 validate-trivial
echo "PASS: 32. PODFILE CHECKSUM 值不匹配 SHA-1(Podfile) 必拒"

# ── 33. PODFILE CHECKSUM 重复必拒（issue #4）──
# Podfile.lock 有两条 PODFILE CHECKSUM 行 → fail closed
clean_repo
setup_pods_head
/usr/bin/sed -i '' "s/pod 'Alamofire', '5.0.0'/pod 'Alamofire', '5.0.1'/" "$TMP_ROOT/Podfile"
local_pfc="$(podfile_sha1 "$TMP_ROOT/Podfile")"
head_pfc_old="$(/usr/bin/git -C "$TMP_ROOT" show HEAD:Podfile.lock | grep '^PODFILE CHECKSUM:' | awk '{print $2}')"
cat > "$TMP_ROOT/Podfile.lock" <<EOF
PODS:
  - Alamofire (5.0.1)
  - SwiftyJSON (5.0.0)

DEPENDENCIES:
  - Alamofire (= 5.0.1)
  - SwiftyJSON (= 5.0.0)

SPEC REPOS:
  trunk:
    - Alamofire
    - SwiftyJSON

SPEC CHECKSUMS:
  Alamofire: cccccccccccccccccccccccccccccccccccccccc
  SwiftyJSON: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

PODFILE CHECKSUM: $local_pfc
PODFILE CHECKSUM: $head_pfc_old

COCOAPODS: 1.10.0
EOF
/usr/bin/git -C "$TMP_ROOT" add Podfile Podfile.lock
start_pod_session t33 5.0.0 5.0.1
assert_fail "pod-patch duplicate PODFILE CHECKSUM" run t33 validate-trivial
echo "PASS: 33. PODFILE CHECKSUM 重复必拒"

# ── 34. PODFILE CHECKSUM 放在 block 内（非顶层）必拒（issue #4）──
# PODFILE CHECKSUM 行缩进后放进 SPEC CHECKSUMS block → _extract_podfile_checksum 找不到顶层 scalar → 拒绝
clean_repo
setup_pods_head
/usr/bin/sed -i '' "s/pod 'Alamofire', '5.0.0'/pod 'Alamofire', '5.0.1'/" "$TMP_ROOT/Podfile"
local_pfc="$(podfile_sha1 "$TMP_ROOT/Podfile")"
cat > "$TMP_ROOT/Podfile.lock" <<EOF
PODS:
  - Alamofire (5.0.1)
  - SwiftyJSON (5.0.0)

DEPENDENCIES:
  - Alamofire (= 5.0.1)
  - SwiftyJSON (= 5.0.0)

SPEC REPOS:
  trunk:
    - Alamofire
    - SwiftyJSON

SPEC CHECKSUMS:
  Alamofire: cccccccccccccccccccccccccccccccccccccccc
  SwiftyJSON: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  PODFILE CHECKSUM: $local_pfc

COCOAPODS: 1.10.0
EOF
/usr/bin/git -C "$TMP_ROOT" add Podfile Podfile.lock
start_pod_session t34 5.0.0 5.0.1
assert_fail "pod-patch PODFILE CHECKSUM inside block" run t34 validate-trivial
echo "PASS: 34. PODFILE CHECKSUM 放在 block 内（非顶层）必拒"

# ── 35. PODFILE CHECKSUM 未变（diff 无 pair）必拒（issue #4）──
# Podfile 变了但 Podfile.lock 的 PODFILE CHECKSUM 没更新 → HEAD==index scalar，
# validator 要求 Podfile 变化时 pair 必须存在（一减一加） → 拒绝
clean_repo
setup_pods_head
/usr/bin/sed -i '' "s/pod 'Alamofire', '5.0.0'/pod 'Alamofire', '5.0.1'/" "$TMP_ROOT/Podfile"
# 只改 PODS/SPEC CHECKSUMS，PODFILE CHECKSUM 保持 HEAD 值不变
/usr/bin/sed -i '' 's/Alamofire (5.0.0)/Alamofire (5.0.1)/' "$TMP_ROOT/Podfile.lock"
/usr/bin/sed -i '' 's/Alamofire: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/Alamofire: cccccccccccccccccccccccccccccccccccccccc/' "$TMP_ROOT/Podfile.lock"
/usr/bin/git -C "$TMP_ROOT" add Podfile Podfile.lock
start_pod_session t35 5.0.0 5.0.1
assert_fail "pod-patch PODFILE CHECKSUM unchanged" run t35 validate-trivial
echo "PASS: 35. PODFILE CHECKSUM 未变（diff 无 pair）必拒"

# ── 36. SPEC CHECKSUMS 短 checksum（<40 位）必拒（Review Round 1 Finding 1）──
# 真实 CocoaPods SPEC CHECKSUMS 是 40 位小写 SHA-1。index 用 39 位 → regex [0-9a-f]{40} 不匹配
# → full-file refs 空 → len(index_ck)!=1 → 拒绝。同时 diff 行 ck_pat 也不匹配 → 拒绝。
clean_repo
setup_pods_head
/usr/bin/sed -i '' "s/pod 'Alamofire', '5.0.0'/pod 'Alamofire', '5.0.1'/" "$TMP_ROOT/Podfile"
local_pfc="$(podfile_sha1 "$TMP_ROOT/Podfile")"
cat > "$TMP_ROOT/Podfile.lock" <<EOF
PODS:
  - Alamofire (5.0.1)
  - SwiftyJSON (5.0.0)

DEPENDENCIES:
  - Alamofire (= 5.0.1)
  - SwiftyJSON (= 5.0.0)

SPEC REPOS:
  trunk:
    - Alamofire
    - SwiftyJSON

SPEC CHECKSUMS:
  Alamofire: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  SwiftyJSON: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

PODFILE CHECKSUM: $local_pfc

COCOAPODS: 1.10.0
EOF
/usr/bin/git -C "$TMP_ROOT" add Podfile Podfile.lock
start_pod_session t36 5.0.0 5.0.1
assert_fail "pod-patch short SPEC CHECKSUMS" run t36 validate-trivial
echo "PASS: 36. SPEC CHECKSUMS 短 checksum（<40 位）必拒"

# ── 37. SPEC CHECKSUMS 超长 checksum（>40 位）必拒（Review Round 1 Finding 1）──
clean_repo
setup_pods_head
/usr/bin/sed -i '' "s/pod 'Alamofire', '5.0.0'/pod 'Alamofire', '5.0.1'/" "$TMP_ROOT/Podfile"
local_pfc="$(podfile_sha1 "$TMP_ROOT/Podfile")"
cat > "$TMP_ROOT/Podfile.lock" <<EOF
PODS:
  - Alamofire (5.0.1)
  - SwiftyJSON (5.0.0)

DEPENDENCIES:
  - Alamofire (= 5.0.1)
  - SwiftyJSON (= 5.0.0)

SPEC REPOS:
  trunk:
    - Alamofire
    - SwiftyJSON

SPEC CHECKSUMS:
  Alamofire: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  SwiftyJSON: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

PODFILE CHECKSUM: $local_pfc

COCOAPODS: 1.10.0
EOF
/usr/bin/git -C "$TMP_ROOT" add Podfile Podfile.lock
start_pod_session t37 5.0.0 5.0.1
assert_fail "pod-patch long SPEC CHECKSUMS" run t37 validate-trivial
echo "PASS: 37. SPEC CHECKSUMS 超长 checksum（>40 位）必拒"

# ── 38. SPEC CHECKSUMS 大写 checksum 必拒（Review Round 1 Finding 1）──
# 真实 CocoaPods checksum 是小写 SHA-1。index 用 40 位大写 A → regex [0-9a-f]{40} 不匹配 → 拒绝
clean_repo
setup_pods_head
/usr/bin/sed -i '' "s/pod 'Alamofire', '5.0.0'/pod 'Alamofire', '5.0.1'/" "$TMP_ROOT/Podfile"
local_pfc="$(podfile_sha1 "$TMP_ROOT/Podfile")"
cat > "$TMP_ROOT/Podfile.lock" <<EOF
PODS:
  - Alamofire (5.0.1)
  - SwiftyJSON (5.0.0)

DEPENDENCIES:
  - Alamofire (= 5.0.1)
  - SwiftyJSON (= 5.0.0)

SPEC REPOS:
  trunk:
    - Alamofire
    - SwiftyJSON

SPEC CHECKSUMS:
  Alamofire: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
  SwiftyJSON: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

PODFILE CHECKSUM: $local_pfc

COCOAPODS: 1.10.0
EOF
/usr/bin/git -C "$TMP_ROOT" add Podfile Podfile.lock
start_pod_session t38 5.0.0 5.0.1
assert_fail "pod-patch uppercase SPEC CHECKSUMS" run t38 validate-trivial
echo "PASS: 38. SPEC CHECKSUMS 大写 checksum 必拒"

# ── 39. 未 ignored `.dev-flow/` untracked 必拒（Review Round 1 Finding 2）──
# check_clean_worktree 不再二次过滤 .dev-flow/；任何 non-ignored untracked 都拒绝。
# 旧代码 startswith(b".dev-flow/") 白名单会放过 .dev-flow/ 路径下的 non-ignored 文件。
# 验证：validate 通过后，临时从 .gitignore 删 .dev-flow/ 排除规则 → session artifact 变 non-ignored
# → approve-commit 的 check_clean_worktree 重算时拒绝。
clean_repo
start_docs_session t39
printf 'doc\n' > "$TMP_ROOT/D39.md"
/usr/bin/git -C "$TMP_ROOT" add D39.md
run t39 validate-trivial >/dev/null
# 临时从 .gitignore 删 .dev-flow/ 行，让 .dev-flow/ 下文件变 non-ignored untracked
/usr/bin/sed -i '' '/^\.dev-flow\/$/d' "$TMP_ROOT/.gitignore"
assert_fail "approve with non-ignored .dev-flow/ untracked" run t39 approve-commit
echo "PASS: 39. 未 ignored .dev-flow/ untracked 必拒"

# ── 40. 已 ignored `.dev-flow/` artifact 不阻塞（Review Round 1 Finding 2 正面验证）──
# .gitignore 正确排除 .dev-flow/ 时，.dev-flow/ 下运行 artifact 不阻塞 approve-commit。
# （现有 #9/#30 隐式覆盖，此处显式验证：validate 后创建 .dev-flow/artifact，approve 通过）
clean_repo
start_docs_session t40
printf 'doc\n' > "$TMP_ROOT/D40.md"
/usr/bin/git -C "$TMP_ROOT" add D40.md
run t40 validate-trivial >/dev/null
printf 'runtime artifact\n' > "$TMP_ROOT/.dev-flow/runtime-artifact.txt"
run t40 approve-commit >/dev/null
run t40 commit --message "docs: D40" >/dev/null
echo "PASS: 40. 已 ignored .dev-flow/ artifact 不阻塞"

echo "PASS: trivial fast-path 全部场景"
