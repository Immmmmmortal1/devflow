#!/usr/bin/env python3
"""trivial fast-path 范围校验器（scripts/lib/trivial_scope_validator.py）。

被 dev-flow-session.sh validate-trivial / approve-commit / commit 调用，对暂存区做
严格范围校验，并记录可重算的 digest 供 approve/commit 漂移比对。

设计原则：fail closed。任何不确定、超界、非纯文档/非纯 pod-patch 的情况一律拒绝，
并提示重开 standard（必要时 requires-heavy）。

校验项（通用）：
  1. staged 非空（git diff --cached --quiet 返回 1）
  2. 无 tracked unstaged（git diff --quiet 返回 0）
  3. 无 non-ignored untracked（git ls-files --others --exclude-standard 为空）
  4. ignored 不阻塞（不检查 ignored）
  5. 记录 HEAD、index tree（write-tree）、每个 staged 文件 path/mode/type/content digest

docs 校验：
  - 仅普通文件新增(A)/修改(M)；拒绝 delete/rename/copy/type-change/symlink/submodule/binary
  - 大小写敏感扩展名 .md/.markdown，以及根目录精确 README/CHANGELOG/LICENSE（无扩展名）
  - 优先拒绝控制面：SKILL.md、AGENTS.md、.dev-flow/、rules/、scripts/、tests/、
    .github/workflows/、CI/安全/发布/构建配置文件
  - 本仓库（devflow 源码仓库自身）修改自身文档不能走 trivial → requires-standard

pod-patch 校验（声明仅交叉校验，不解析 Ruby/YAML 语义）：
  - from 绑定 HEAD 版本，to 绑定 index 版本；严格 x.y.z；同 major/minor；patch 递增
  - 仅 Podfile/Podfile.lock 变化
  - Podfile：目标依赖单行版本替换且除版本外完全一致
  - lockfile：只允许目标依赖版本引用（PODS/可选 DEPENDENCIES）、目标 SPEC CHECKSUMS 对、
    以及自动生成且严格绑定的 PODFILE CHECKSUM 对（Podfile SHA-1 from→to）；
    SPEC CHECKSUMS 与 PODFILE CHECKSUM 均为 40 位小写 SHA-1，拒绝短/超长/大写；
    禁止其他包版本/checksum、结构增删、SPEC REPOS/EXTERNAL SOURCES/CHECKOUT OPTIONS/COCOAPODS 变化

Usage:
  python3 trivial_scope_validator.py <project_root> <kind> [params_json]
  # params_json 例: {"dependency":"Alamofire","from_version":"5.0.0","to_version":"5.0.1"}
  python3 trivial_scope_validator.py <project_root> --digest
  # 仅重算 digest（approve/commit 漂移比对用），不做范围校验
"""
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

VALIDATOR_VERSION = "1"

# ── 控制面拒绝清单（docs） ──
# 任意路径段精确文件名（大小写敏感）
CONTROL_PLANE_FILES = {
    "SKILL.md",
    "AGENTS.md",
}
# 路径前缀（以 / 分隔的目录前缀）
CONTROL_PLANE_PREFIXES = (
    ".dev-flow/",
    "rules/",
    "scripts/",
    "tests/",
    "test/",
    ".github/workflows/",
    ".github/",
    ".gitlab-ci/",
    ".circleci/",
)
# CI/安全/发布/构建配置文件（任意位置精确文件名）
CONTROL_PLANE_CONFIG_FILES = {
    ".travis.yml",
    "Makefile",
    "Gemfile",
    "Gemfile.lock",
    "package.json",
    "package-lock.json",
    "yarn.lock",
    "pnpm-lock.yaml",
    "Fastfile",
    "Appfile",
    "Matchfile",
    "Deliverfile",
    "SnapshotHelper.swift",
    "Podfile",
    "Podfile.lock",
    "Dockerfile",
    "docker-compose.yml",
    ".xcodebuildmcp",
}

# docs 允许的扩展名（大小写敏感）
DOCS_EXTENSIONS = (".md", ".markdown")
# docs 允许的根目录精确文件名（无扩展名）
DOCS_ROOT_EXACT = ("README", "CHANGELOG", "LICENSE")

# pod-patch 允许的文件
POD_FILES = ("Podfile", "Podfile.lock")


def _git(project_root, args, binary=False):
    """运行 git，返回 stdout。失败 raise SystemExit。"""
    r = subprocess.run(
        ["/usr/bin/git", "-C", str(project_root)] + args,
        capture_output=True,
    )
    if r.returncode != 0:
        raise SystemExit(
            f"git {' '.join(args)} failed: {r.stderr.decode('utf-8', 'replace').strip()[-500:]}"
        )
    return r.stdout if binary else r.stdout.decode("utf-8", "surrogateescape")


def _git_rc(project_root, args):
    """运行 git，只关心 returncode。"""
    return subprocess.run(
        ["/usr/bin/git", "-C", str(project_root)] + args,
        capture_output=True,
    ).returncode


def _hash_bytes(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def _is_binary(data: bytes) -> bool:
    """检测二进制内容：含 NUL 字节即视为二进制。"""
    return b"\x00" in data


def _parse_name_status(raw: bytes):
    """解析 git diff --name-status -z 输出，返回 [(status, new_path, old_path), ...]。"""
    entries = []
    parts = raw.split(b"\0")
    i = 0
    while i < len(parts):
        part = parts[i]
        if not part:
            i += 1
            continue
        decoded = part.decode("utf-8", "surrogateescape")
        first = decoded[0]
        if first in ("R", "C"):
            status = first
            old_path = parts[i + 1].decode("utf-8", "surrogateescape") if i + 1 < len(parts) else ""
            new_path = parts[i + 2].decode("utf-8", "surrogateescape") if i + 2 < len(parts) else ""
            entries.append((status, new_path, old_path))
            i += 3
        else:
            status = first
            path = parts[i + 1].decode("utf-8", "surrogateescape") if i + 1 < len(parts) else ""
            entries.append((status, path, None))
            i += 2
    return entries


def _mode_type(mode: str):
    """根据 git mode 返回 (mode, type)。"""
    if not mode or mode == "missing":
        return mode, "missing"
    if mode.startswith("120"):
        return mode, "symlink"
    if mode.startswith("160"):
        return mode, "submodule"
    if mode.startswith("100"):
        return mode, "file"
    return mode, "other"


def _index_blob_content(project_root, blob_id: str) -> bytes:
    """读取 index blob 的原始内容（二进制安全）。"""
    if not blob_id or blob_id == "missing":
        return b""
    return _git(project_root, ["cat-file", "blob", blob_id], binary=True)


def compute_staged_state(project_root):
    """枚举暂存区，返回结构化 staged entries + head + index_tree。

    Returns:
        {
          "head": "<HEAD sha>",
          "index_tree": "<git write-tree sha>",
          "entries": [{"path","status","mode","type","content_digest"}],
        }
    """
    project_root = Path(project_root)
    if not project_root.is_dir():
        raise SystemExit(f"project root is not a directory: {project_root}")

    # HEAD commit
    try:
        head = _git(project_root, ["rev-parse", "--verify", "--quiet", "HEAD"]).strip()
    except SystemExit:
        head = ""
    if not head:
        # 无任何 commit（空仓库）——trivial 要求有基线 HEAD 绑定 from 版本；fail closed
        raise SystemExit("project has no HEAD commit; trivial fast-path requires a baseline commit")

    # index tree（write-tree 从 index 生成确定性 tree sha）
    index_tree = _git(project_root, ["write-tree"]).strip()

    # staged name-status
    staged_raw = _git(project_root, ["diff", "--cached", "--name-status", "-z"], binary=True)
    staged_ns = _parse_name_status(staged_raw)

    # 收集 staged 文件的 index blob id + mode
    # 注意：不得跳过任何 staged 条目。运行 artifact 只应通过 .gitignore 排除
    #（check_clean_worktree 用 --exclude-standard 排除 ignored 项，不做二次白名单过滤），
    # 而不能从 staged diff 隐藏——否则混合一个合法 docs 即可把 .dev-flow/ 控制面改动
    # 带入提交（.dev-flow/ 已在 docs 控制面拒绝清单中，staged 时由 validate_docs 拒绝）。
    entries = []
    for status, new_path, old_path in staged_ns:
        # ls-files -s 获取 index mode + blob id
        ls = _git(
            project_root,
            ["ls-files", "-s", "-z", "--", new_path],
            binary=True,
        )
        # 格式: <mode> <hash> <stage>\0<path>\0
        rec_mode = "missing"
        rec_blob = "missing"
        for chunk in ls.split(b"\0"):
            if not chunk:
                continue
            # 第一块含 metadata
            parts = chunk.decode("utf-8", "surrogateescape").split()
            if len(parts) >= 3:
                rec_mode = parts[0]
                rec_blob = parts[1]
                break
        mode, ftype = _mode_type(rec_mode)
        content = _index_blob_content(project_root, rec_blob)
        content_digest = _hash_bytes(content) if content or rec_blob != "missing" else "sha256:empty"
        entries.append({
            "path": new_path,
            "status": status,  # A/M/D/R/C/T
            "mode": mode,
            "type": ftype,
            "content_digest": content_digest,
            "old_path": old_path,  # rename 时旧路径
        })

    return {"head": head, "index_tree": index_tree, "entries": entries}


def check_clean_worktree(project_root):
    """校验工作树干净：无 tracked unstaged + 无 non-ignored untracked。

    ignored 不阻塞（--exclude-standard 已排除 .gitignore 项）。返回 (ok, reason)。
    所有 git ls-files --others --exclude-standard 返回的文件都拒绝——不做二次过滤，
    运行 artifact 必须靠 .gitignore 排除，不能靠代码白名单（否则会放过 non-ignored untracked）。
    """
    project_root = Path(project_root)
    # tracked unstaged: git diff --quiet (worktree vs index) 返回 0 表示无 unstaged
    rc_unstaged = _git_rc(project_root, ["diff", "--quiet"])
    if rc_unstaged == 0:
        pass  # 干净
    elif rc_unstaged == 1:
        return False, "tracked unstaged changes present; stage or stash before validate-trivial"
    else:
        return False, "git diff --quiet failed unexpectedly"

    # non-ignored untracked（--exclude-standard 已排除 .gitignore 项）
    untracked_raw = _git(
        project_root,
        ["ls-files", "--others", "--exclude-standard", "-z"],
        binary=True,
    )
    untracked = [p for p in untracked_raw.split(b"\0") if p]
    if untracked:
        names = ", ".join(p.decode("utf-8", "surrogateescape") for p in untracked[:5])
        return False, f"non-ignored untracked files present ({names}...); add or ignore before validate-trivial"

    return True, ""


def _is_devflow_self_repo(project_root) -> bool:
    """判定 project_root 是否是 devflow 源码仓库自身。

    探测 scripts/dev-flow-session.sh 与 skills/ 目录同时存在。本仓库修改自身文档
    不能走 trivial（属于控制面改动）。
    """
    root = Path(project_root)
    return (root / "scripts" / "dev-flow-session.sh").is_file() and (root / "skills").is_dir()


def _path_is_control_plane(rel_path: str) -> bool:
    """docs 控制面路径匹配。"""
    name = rel_path.split("/")[-1]
    if name in CONTROL_PLANE_FILES:
        return True
    if name in CONTROL_PLANE_CONFIG_FILES:
        return True
    for prefix in CONTROL_PLANE_PREFIXES:
        if rel_path.startswith(prefix):
            return True
    return False


def _is_docs_allowed_path(rel_path: str) -> bool:
    """docs 允许的路径：大小写敏感扩展名或根目录精确文件名。"""
    name = rel_path.split("/")[-1]
    # 根目录精确文件名（无扩展名，仅在根目录）
    if "/" not in rel_path and name in DOCS_ROOT_EXACT:
        return True
    # 大小写敏感扩展名
    for ext in DOCS_EXTENSIONS:
        if name.endswith(ext):
            return True
    return False


def validate_docs(project_root, staged):
    """docs 范围校验。返回 (result, escalation, reason)。"""
    entries = staged["entries"]

    # 本仓库自身文档不能走 trivial
    if _is_devflow_self_repo(project_root):
        return (
            "fail",
            "requires-standard",
            "this is the devflow source repository; modifying its own docs "
            "is a control-plane change and cannot use the trivial fast-path; "
            "re-open as standard/heavy",
        )

    if not entries:
        return ("fail", None, "no staged files; stage documentation changes first")

    for e in entries:
        path = e["path"]
        status = e["status"]
        mode = e["mode"]
        ftype = e["type"]

        # 拒绝 delete / rename / copy / type-change
        if status == "D":
            return ("fail", "requires-standard", f"deletion not allowed in trivial docs: {path}; re-open as standard")
        if status in ("R", "C"):
            return ("fail", "requires-standard", f"rename/copy not allowed in trivial docs: {path}; re-open as standard")
        if status == "T":
            return ("fail", "requires-standard", f"type-change not allowed in trivial docs: {path}; re-open as standard")
        if status not in ("A", "M"):
            return ("fail", "requires-standard", f"unsupported staged status {status} for {path}; re-open as standard")

        # 拒绝 symlink / submodule
        if ftype == "symlink":
            return ("fail", "requires-standard", f"symlink not allowed in trivial docs: {path}; re-open as standard")
        if ftype == "submodule":
            return ("fail", "requires-standard", f"submodule not allowed in trivial docs: {path}; re-open as standard")
        if ftype not in ("file",):
            return ("fail", "requires-standard", f"non-regular file type {ftype} for {path}; re-open as standard")

        # 拒绝 binary
        # 读 index blob 内容检测
        content = _git(project_root, ["cat-file", "blob", _index_blob_id(project_root, path)], binary=True)
        if _is_binary(content):
            return ("fail", "requires-standard", f"binary content not allowed in trivial docs: {path}; re-open as standard")

        # 控制面优先拒绝
        if _path_is_control_plane(path):
            return (
                "fail",
                "requires-standard",
                f"control-plane path not allowed in trivial docs: {path}; re-open as standard",
            )

        # 允许的文档路径
        if not _is_docs_allowed_path(path):
            return (
                "fail",
                "requires-standard",
                f"path not allowed in trivial docs (only .md/.markdown and root README/CHANGELOG/LICENSE): {path}; re-open as standard",
            )

    return ("pass", None, "")


def _index_blob_id(project_root, rel_path):
    """获取 index 中文件的 blob id。"""
    ls = _git(project_root, ["ls-files", "-s", "-z", "--", rel_path], binary=True)
    for chunk in ls.split(b"\0"):
        if not chunk:
            continue
        parts = chunk.decode("utf-8", "surrogateescape").split()
        if len(parts) >= 3:
            return parts[1]
    return "missing"


_VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")


def _parse_version(v):
    """严格 x.y.z 解析，返回 (major, minor, patch) 或 None。"""
    if not isinstance(v, str) or not _VERSION_RE.match(v):
        return None
    return tuple(int(x) for x in v.split("."))


def _podfile_version_declarations(project_root, treeish, dependency):
    """从指定 treeish 的 Podfile 中提取目标 dependency 的所有精确版本声明行。

    精确版本声明 = `pod 'Name', 'x.y.z'`（单引号或双引号）。
    排除 subspec（`pod 'Name/Sub', ...`）——正则要求依赖名被引号精确包围。
    返回 [(full_line, version), ...]，按出现顺序。treeish 读取失败返回 []。
    """
    try:
        content = _git(project_root, ["show", f"{treeish}:Podfile"], binary=True)
    except SystemExit:
        return []
    text = content.decode("utf-8", "surrogateescape")
    dep_re = re.escape(dependency)
    pat = re.compile(rf"^\s*pod\s+['\"]{dep_re}['\"]\s*,\s*['\"]([^'\"]+)['\"]\s*(.*)$", re.MULTILINE)
    out = []
    for line in text.splitlines():
        m = pat.match(line)
        if m:
            out.append((line, m.group(1)))
    return out


def _podfile_index_declarations(project_root, dependency):
    """从 index（暂存区）Podfile 中提取目标 dependency 的所有精确版本声明行。

    index Podfile 通过 `git show :Podfile` 读取（暂存区版本）。返回同上。
    """
    try:
        content = _git(project_root, ["show", ":Podfile"], binary=True)
    except SystemExit:
        return []
    text = content.decode("utf-8", "surrogateescape")
    dep_re = re.escape(dependency)
    pat = re.compile(rf"^\s*pod\s+['\"]{dep_re}['\"]\s*,\s*['\"]([^'\"]+)['\"]\s*(.*)$", re.MULTILINE)
    out = []
    for line in text.splitlines():
        m = pat.match(line)
        if m:
            out.append((line, m.group(1)))
    return out


def _validate_podfile_diff(project_root, dependency, from_version, to_version):
    """校验 Podfile staged diff：仅目标依赖单行版本替换且除版本外一致。"""
    # staged diff (HEAD vs index)
    diff = _git(
        project_root,
        ["diff", "--cached", "-U0", "--", "Podfile"],
        binary=True,
    ).decode("utf-8", "surrogateescape")

    if not diff.strip():
        return ("fail", "requires-standard", "Podfile has no staged changes")

    # 解析 hunk 中的 - 行和 + 行（排除 diff 头和 @@ 行）
    minus_lines = []
    plus_lines = []
    for line in diff.splitlines():
        if line.startswith("@@") or line.startswith("+++") or line.startswith("---") \
                or line.startswith("diff ") or line.startswith("index "):
            continue
        if line.startswith("-"):
            minus_lines.append(line[1:])
        elif line.startswith("+"):
            plus_lines.append(line[1:])

    # 恰好一对行替换
    if len(minus_lines) != 1 or len(plus_lines) != 1:
        return (
            "fail", "requires-standard",
            f"Podfile trivial patch must be a single line replacement "
            f"(got {len(minus_lines)} removed, {len(plus_lines)} added); re-open as standard",
        )

    old_line = minus_lines[0]
    new_line = plus_lines[0]

    dep_re = re.escape(dependency)
    old_pat = re.compile(rf"^(\s*pod\s+['\"]{dep_re}['\"]\s*,\s*['\"])([^'\"]+)(['\"]\s*)(.*)$")
    new_pat = old_pat

    om = old_pat.match(old_line)
    nm = new_pat.match(new_line)
    if not om or not nm:
        return (
            "fail", "requires-standard",
            f"Podfile changed line is not a single-dependency version line for {dependency}; re-open as standard",
        )

    # 除版本外完全一致
    prefix_old, ver_old, suffix_old, trail_old = om.groups()
    prefix_new, ver_new, suffix_new, trail_new = nm.groups()
    if prefix_old != prefix_new or suffix_old != suffix_new or trail_old != trail_new:
        return (
            "fail", "requires-standard",
            f"Podfile line for {dependency} changed more than the version; re-open as standard",
        )

    # 版本绑定校验：from 绑 HEAD，to 绑 index。
    # 唯一性校验（issue #1）：HEAD 与 index 中目标 dependency 的精确版本声明必须各恰好 1 条，
    # HEAD 声明版本==from_version、index 声明版本==to_version。任何重复/歧义 fail closed
    #（防止修改第二个声明而第一个声明仍匹配 from 时绕过 HEAD 绑定）。
    head_decls = _podfile_version_declarations(project_root, "HEAD", dependency)
    if len(head_decls) != 1:
        return (
            "fail", "requires-standard",
            f"Podfile HEAD must declare {dependency} exactly once "
            f"(got {len(head_decls)}); re-open as standard",
        )
    if head_decls[0][1] != from_version:
        return (
            "fail", "requires-standard",
            f"from_version {from_version!r} does not match HEAD Podfile version "
            f"{head_decls[0][1]!r} for {dependency}; re-open as standard",
        )
    index_decls = _podfile_index_declarations(project_root, dependency)
    if len(index_decls) != 1:
        return (
            "fail", "requires-standard",
            f"Podfile index must declare {dependency} exactly once "
            f"(got {len(index_decls)}); re-open as standard",
        )
    if index_decls[0][1] != to_version:
        return (
            "fail", "requires-standard",
            f"to_version {to_version!r} does not match index Podfile version "
            f"{index_decls[0][1]!r} for {dependency}; re-open as standard",
        )
    if ver_old != from_version:
        return (
            "fail", "requires-standard",
            f"staged removal version {ver_old!r} != declared from_version {from_version!r}; re-open as standard",
        )
    if ver_new != to_version:
        return (
            "fail", "requires-standard",
            f"staged addition version {ver_new!r} != declared to_version {to_version!r}; re-open as standard",
        )

    # 版本递增校验
    fp = _parse_version(from_version)
    tp = _parse_version(to_version)
    if not fp or not tp:
        return ("fail", "requires-standard", f"versions must be strict x.y.z: from={from_version} to={to_version}; re-open as standard")
    if fp[0] != tp[0] or fp[1] != tp[1]:
        return (
            "fail", "requires-standard",
            f"only patch bump allowed (same major.minor): {from_version} -> {to_version}; re-open as standard",
        )
    if tp[2] != fp[2] + 1:
        return (
            "fail", "requires-standard",
            f"patch must increment by exactly 1: {from_version} -> {to_version}; re-open as standard",
        )

    return ("pass", None, "")


def _parse_lockfile_sections(text):
    """解析 Podfile.lock 文本为 {section_name: [content_lines]}。

    真实 CocoaPods Podfile.lock 顶层结构：
      block sections（以 `NAME:` 结尾的顶层无缩进行）：PODS、DEPENDENCIES、SPEC REPOS、
      EXTERNAL SOURCES、CHECKOUT OPTIONS、SPEC CHECKSUMS。
      scalar lines（无缩进、非冒号结尾 block）：`PODFILE CHECKSUM: <hex>`、`COCOAPODS: <ver>`。

    section 终止语义（fail-closed，防止标量/unknown 后的缩进行被误算进前 section）：
      - 任何无缩进顶层行（不以空格/tab/- 开头）若不是已知 block header → 退出当前 block：
        `PODFILE CHECKSUM:`/`COCOAPODS:` 归入 "<scalar>"；未知 header 归入 "<unknown>"。
        其后的缩进行归入对应 scalar/unknown，不延续前一个 block。
      - block 之间的空行不计入 content。
    文件头至第一个 block header 之前的内容归入 "<header>"。
    """
    sections = {}
    current = None
    # 已知 block section headers（真实 CocoaPods 名，无虚构 POD CHECKSUMS）
    KNOWN_BLOCKS = ("PODS:", "DEPENDENCIES:", "SPEC REPOS:",
                     "EXTERNAL SOURCES:", "CHECKOUT OPTIONS:",
                     "SPEC CHECKSUMS:")
    for line in text.splitlines():
        stripped = line.strip()
        is_top_level = bool(line) and not line[0].isspace() and not line.startswith("-")
        # 顶层行分三类：block header（以 `:` 结尾）、scalar 行（PODFILE CHECKSUM:/COCOAPODS: 带值）、
        # 其他未知顶层行。block header 以 `:` 结尾；scalar 行不以 `:` 结尾但前缀匹配已知 scalar 名。
        # ⚠️ 不能只看 endswith(":") —— `PODFILE CHECKSUM: <hex>` 不以 `:` 结尾，
        # 旧代码会把它误塞进前一个 block（SPEC CHECKSUMS）。必须前缀匹配 scalar 名。
        SCALAR_PREFIXES = ("PODFILE CHECKSUM:", "COCOAPODS:")
        is_scalar_line = is_top_level and any(
            stripped == p or stripped.startswith(p + " ") for p in SCALAR_PREFIXES
        )
        if is_top_level and stripped.endswith(":"):
            if stripped in KNOWN_BLOCKS:
                current = stripped
                sections.setdefault(current, [])
                continue
            # 已知 scalar header（PODFILE CHECKSUM: / COCOAPODS:）→ 归入 <scalar>，退出 block
            # 未知顶层 header → 归入 <unknown>，退出 block（其后续行也隔离）
            current = "<scalar>" if stripped in SCALAR_PREFIXES else "<unknown>"
            sections.setdefault(current, [])
            sections[current].append(line)
            continue
        if is_scalar_line:
            # 带值的 scalar 行（如 `PODFILE CHECKSUM: <hex>`、`COCOAPODS: 1.10.0`）：
            # 归入 <scalar>，退出当前 block，其后缩进行也归入 <scalar> 不延续前 block。
            current = "<scalar>"
            sections.setdefault(current, [])
            sections[current].append(line)
            continue
        if current is None:
            sections.setdefault("<header>", [])
            sections["<header>"].append(line)
        else:
            # 跳过 section 之间的空行（不污染 content）
            if stripped:
                sections.setdefault(current, [])
                sections[current].append(line)
    return sections


def _lockfile_dep_refs(section_lines, dep, ref_type):
    """在某个 section 的行列表中，提取目标 dependency 的指定类型引用。

    ref_type: "pods" → `  - Name (x.y.z)`；"dep" → `  - Name (= x.y.z)`；"checksum" → `  Name: <40位小写hex>`
    真实 CocoaPods SPEC CHECKSUMS 是 40 位小写 SHA-1，严格匹配 [0-9a-f]{40}。
    返回匹配行列表（version 或 checksum 字符串）。fail-closed：任何无法精确分类的行不匹配。
    """
    dep_re = re.escape(dep)
    if ref_type == "pods":
        pat = re.compile(rf"^\s*-\s*{dep_re}\s*\((\d+\.\d+\.\d+)\)\s*$")
    elif ref_type == "dep":
        pat = re.compile(rf"^\s*-\s*{dep_re}\s*\(\s*=\s*(\d+\.\d+\.\d+)\)\s*$")
    elif ref_type == "checksum":
        # 真实 CocoaPods checksum 是 40 位小写 SHA-1；拒绝短/超长/大写
        pat = re.compile(rf"^\s*{dep_re}:\s*([0-9a-f]{{40}})\s*$")
    else:
        return []
    out = []
    for line in section_lines:
        m = pat.match(line)
        if m:
            out.append(m.group(1))
    return out


def _lockfile_blob(project_root, treeish):
    """读取 Podfile.lock 的完整文本。

    treeish 为 git ref（如 "HEAD"）→ 用 `git show <treeish>:Podfile.lock`；
    treeish 为 ":Podfile.lock" → 用 `git show :Podfile.lock`（index 版本）。
    失败返回 None。
    """
    try:
        if treeish == ":Podfile.lock":
            content = _git(project_root, ["show", ":Podfile.lock"], binary=True)
        else:
            content = _git(project_root, ["show", f"{treeish}:Podfile.lock"], binary=True)
        return content.decode("utf-8", "surrogateescape")
    except SystemExit:
        return None


def _podfile_blob_bytes(project_root, treeish):
    """读取 Podfile 原始 bytes（用于计算 CocoaPods 用的 SHA-1）。

    treeish 为 git ref（如 "HEAD"）→ `git show <treeish>:Podfile`；
    treeish 为 ":Podfile" → `git show :Podfile`（index 版本）。
    失败返回 None。
    """
    try:
        if treeish == ":Podfile":
            return _git(project_root, ["show", ":Podfile"], binary=True)
        return _git(project_root, ["show", f"{treeish}:Podfile"], binary=True)
    except SystemExit:
        return None


def _podfile_sha1(project_root, treeish):
    """计算指定 treeish 的 Podfile 内容 SHA-1（40 位小写 hex）。

    CocoaPods 的 PODFILE CHECKSUM 是 Podfile 文件内容的 SHA-1 哈希。
    treeish: "HEAD" 或 ":Podfile"（index）。
    失败返回 None。
    """
    data = _podfile_blob_bytes(project_root, treeish)
    if data is None:
        return None
    return hashlib.sha1(data).hexdigest()


# PODFILE CHECKSUM scalar 行精确模式：`PODFILE CHECKSUM: <40位小写hex>`
_PODFILE_CHECKSUM_RE = re.compile(r"^PODFILE CHECKSUM:\s*([0-9a-f]{40})\s*$")


def _extract_podfile_checksum(sections):
    """从 _parse_lockfile_sections 结果中提取 PODFILE CHECKSUM scalar 值。

    必须位于顶层 <scalar> 区（PODFILE CHECKSUM: / COCOAPODS: 归属），
    恰好 1 条，且为 40 位小写 hex。返回 checksum 字符串或 None。
    fail-closed：0 条、>1 条、格式非法均返回 None。
    """
    scalar_lines = sections.get("<scalar>", [])
    found = []
    for line in scalar_lines:
        m = _PODFILE_CHECKSUM_RE.match(line)
        if m:
            found.append(m.group(1))
    if len(found) == 1:
        return found[0]
    return None


def _validate_lockfile_diff(project_root, dependency, from_version, to_version):
    """校验 Podfile.lock staged diff：只允许目标依赖版本引用、目标 checksum、PODFILE CHECKSUM 变化。

    两层 fail-closed：
      A. diff 行分类：每个 +/- 内容行必须精确匹配 PODS/DEPENDENCIES/SPEC CHECKSUMS/PODFILE CHECKSUM
         四类形状之一，否则拒绝。拒绝 section header、COCOAPODS、其他包、注释伪装等。
      B. section 归属 + 唯一性交叉校验：读取 HEAD 和 index 的完整 Podfile.lock，按顶层 section
         边界解析，确认：
         - PODS section 中目标依赖恰好 1 条，HEAD==from、index==to
         - DEPENDENCIES section 中目标依赖至多 1 条；若 HEAD 有则 index 必有且 from→to
         - SPEC CHECKSUMS section 中目标依赖恰好 1 条（HEAD/index 各 1）。
           checksum 绑定：若 diff 无 checksum pair，full HEAD/index checksum 必须相同；
           若 diff 有一对，minus/plus 必须分别精确等于 full HEAD/index checksum 且二者不同。
         - PODFILE CHECKSUM scalar（顶层）：HEAD/index 必须各恰好 1 条，分别等于
           SHA-1(HEAD Podfile bytes) / SHA-1(index Podfile bytes)。
           diff 必须恰好一减一加（Podfile 确实变化，二者应不同）；minus==full HEAD scalar
           ==SHA-1(HEAD Podfile)，plus==full index scalar==SHA-1(index Podfile)。
           缺失/重复/错误值/放在 block 内或未知 section 内都 fail closed。
         若无法确定 section 归属则拒绝。
    """
    diff = _git(
        project_root,
        ["diff", "--cached", "-U0", "--", "Podfile.lock"],
        binary=True,
    ).decode("utf-8", "surrogateescape")

    if not diff.strip():
        return ("fail", "requires-standard", "Podfile.lock has no staged changes")

    # ── B. section 归属 + 唯一性交叉校验（读取完整文件）──
    head_text = _lockfile_blob(project_root, "HEAD")
    index_text = _lockfile_blob(project_root, ":Podfile.lock")
    if head_text is None:
        return ("fail", "requires-standard", "cannot read HEAD Podfile.lock; re-open as standard")
    if index_text is None:
        return ("fail", "requires-standard", "cannot read index Podfile.lock; re-open as standard")

    head_secs = _parse_lockfile_sections(head_text)
    index_secs = _parse_lockfile_sections(index_text)

    dep = dependency

    def refs(secs, section, ref_type):
        return _lockfile_dep_refs(secs.get(section, []), dep, ref_type)

    # PODS：HEAD 恰好 1 条 == from，index 恰好 1 条 == to
    head_pods = refs(head_secs, "PODS:", "pods")
    index_pods = refs(index_secs, "PODS:", "pods")
    if len(head_pods) != 1:
        return ("fail", "requires-standard", f"lockfile PODS must have exactly one {dep} ref in HEAD (got {len(head_pods)}); re-open as standard")
    if head_pods[0] != from_version:
        return ("fail", "requires-standard", f"lockfile PODS HEAD version {head_pods[0]!r} != declared from {from_version!r}; re-open as standard")
    if len(index_pods) != 1:
        return ("fail", "requires-standard", f"lockfile PODS must have exactly one {dep} ref in index (got {len(index_pods)}); re-open as standard")
    if index_pods[0] != to_version:
        return ("fail", "requires-standard", f"lockfile PODS index version {index_pods[0]!r} != declared to {to_version!r}; re-open as standard")

    # DEPENDENCIES：至多 1 条；若 HEAD 有则 index 必有且 from→to
    head_dep = refs(head_secs, "DEPENDENCIES:", "dep")
    index_dep = refs(index_secs, "DEPENDENCIES:", "dep")
    if len(head_pods) and len(head_dep) > 1:
        return ("fail", "requires-standard", f"lockfile DEPENDENCIES {dep} ref count > 1 in HEAD; re-open as standard")
    if len(index_dep) > 1:
        return ("fail", "requires-standard", f"lockfile DEPENDENCIES {dep} ref count > 1 in index; re-open as standard")
    if head_dep:
        if not index_dep:
            return ("fail", "requires-standard", f"lockfile DEPENDENCIES {dep} ref disappeared in index; re-open as standard")
        if head_dep[0] != from_version:
            return ("fail", "requires-standard", f"lockfile DEPENDENCIES HEAD version {head_dep[0]!r} != declared from {from_version!r}; re-open as standard")
        if index_dep[0] != to_version:
            return ("fail", "requires-standard", f"lockfile DEPENDENCIES index version {index_dep[0]!r} != declared to {to_version!r}; re-open as standard")
    elif index_dep:
        # HEAD 无但 index 有 → 新增引用，不符合 from→to
        return ("fail", "requires-standard", f"lockfile DEPENDENCIES {dep} ref appeared in index without HEAD counterpart; re-open as standard")

    # SPEC CHECKSUMS：HEAD/index 必须各恰好 1 条（真实 CocoaPods section 名）。
    # checksum 绑定（issue #3）：把 diff 变化真正绑定到正确 section，杜绝其他 section/标量后
    # 伪造 checksum 形状。若 diff 无 checksum pair，full HEAD/index checksum 必须相同；
    # 若 diff 有一对，minus/plus 必须分别精确等于 full HEAD/index checksum 且二者不同。
    head_ck = refs(head_secs, "SPEC CHECKSUMS:", "checksum")
    index_ck = refs(index_secs, "SPEC CHECKSUMS:", "checksum")
    if len(head_ck) != 1:
        return ("fail", "requires-standard", f"lockfile SPEC CHECKSUMS must have exactly one {dep} ref in HEAD (got {len(head_ck)}); re-open as standard")
    if len(index_ck) != 1:
        return ("fail", "requires-standard", f"lockfile SPEC CHECKSUMS must have exactly one {dep} ref in index (got {len(index_ck)}); re-open as standard")

    # PODFILE CHECKSUM scalar 绑定（section B）：必须位于顶层 <scalar> 区，HEAD/index 各恰好 1 条，
    # 分别等于 SHA-1(HEAD Podfile bytes) / SHA-1(index Podfile bytes)。
    head_pfc = _extract_podfile_checksum(head_secs)
    index_pfc = _extract_podfile_checksum(index_secs)
    if head_pfc is None:
        return ("fail", "requires-standard", f"lockfile PODFILE CHECKSUM must be exactly one 40-hex scalar in HEAD <scalar> section; re-open as standard")
    if index_pfc is None:
        return ("fail", "requires-standard", f"lockfile PODFILE CHECKSUM must be exactly one 40-hex scalar in index <scalar> section; re-open as standard")
    head_pfc_calc = _podfile_sha1(project_root, "HEAD")
    index_pfc_calc = _podfile_sha1(project_root, ":Podfile")
    if head_pfc_calc is None:
        return ("fail", "requires-standard", "cannot compute SHA-1 of HEAD Podfile; re-open as standard")
    if index_pfc_calc is None:
        return ("fail", "requires-standard", "cannot compute SHA-1 of index Podfile; re-open as standard")
    if head_pfc != head_pfc_calc:
        return ("fail", "requires-standard", f"lockfile PODFILE CHECKSUM {head_pfc!r} != SHA-1(HEAD Podfile) {head_pfc_calc!r}; re-open as standard")
    if index_pfc != index_pfc_calc:
        return ("fail", "requires-standard", f"lockfile PODFILE CHECKSUM {index_pfc!r} != SHA-1(index Podfile) {index_pfc_calc!r}; re-open as standard")

    # ── A. diff 行分类（保留 fail-closed：非目标行必拒）──
    # 真实 CocoaPods block headers + scalar header（COCOAPODS 拒绝出现在 diff 内容行）。
    # PODFILE CHECKSUM 不在此拒绝列表——它是合法的第四类 diff 行（自动生成且严格绑定）。
    SECTION_HEADERS = ("PODS:", "DEPENDENCIES:", "SPEC REPOS:",
                       "EXTERNAL SOURCES:", "CHECKOUT OPTIONS:",
                       "SPEC CHECKSUMS:", "COCOAPODS:")
    dep_re = re.escape(dep)
    pods_ver_pat = re.compile(rf"^\s*-\s*{dep_re}\s*\((\d+\.\d+\.\d+)\)\s*$")
    dep_ver_pat = re.compile(rf"^\s*-\s*{dep_re}\s*\(\s*=\s*(\d+\.\d+\.\d+)\)\s*$")
    # 真实 CocoaPods SPEC CHECKSUMS 是 40 位小写 SHA-1；拒绝短/超长/大写
    ck_pat = re.compile(rf"^\s*{dep_re}:\s*([0-9a-f]{{40}})\s*$")
    # PODFILE CHECKSUM scalar 行（顶层无缩进，40 位小写 hex）
    pfc_pat = re.compile(r"^PODFILE CHECKSUM:\s*([0-9a-f]{40})\s*$")

    pods_minus, pods_plus = [], []
    dep_minus, dep_plus = [], []
    ck_minus, ck_plus = [], []
    pfc_minus, pfc_plus = [], []

    def classify(content, pods_b, dep_b, ck_b, pfc_b):
        stripped = content.strip()
        for h in SECTION_HEADERS:
            if stripped == h:
                return False
        m = pods_ver_pat.match(content)
        if m:
            pods_b.append(m.group(1)); return True
        m = dep_ver_pat.match(content)
        if m:
            dep_b.append(m.group(1)); return True
        m = ck_pat.match(content)
        if m:
            ck_b.append(m.group(1)); return True
        m = pfc_pat.match(content)
        if m:
            pfc_b.append(m.group(1)); return True
        return False

    for line in diff.splitlines():
        if line.startswith("@@") or line.startswith("+++") or line.startswith("---") \
                or line.startswith("diff ") or line.startswith("index "):
            continue
        if line.startswith("-"):
            content = line[1:]
            if not classify(content, pods_minus, dep_minus, ck_minus, pfc_minus):
                return (
                    "fail", "requires-standard",
                    f"lockfile removed line is not an allowed {dep} version/checksum or PODFILE CHECKSUM reference: "
                    f"{content!r}; re-open as standard",
                )
        elif line.startswith("+"):
            content = line[1:]
            if not classify(content, pods_plus, dep_plus, ck_plus, pfc_plus):
                return (
                    "fail", "requires-standard",
                    f"lockfile added line is not an allowed {dep} version/checksum or PODFILE CHECKSUM reference: "
                    f"{content!r}; re-open as standard",
                )

    # PODS 核心版本行：必须有且仅有一对 from→to（与完整文件解析一致）
    if len(pods_minus) != 1 or len(pods_plus) != 1:
        return (
            "fail", "requires-standard",
            f"lockfile must have exactly one {dep} PODS version pair "
            f"(got {len(pods_minus)} removed, {len(pods_plus)} added); re-open as standard",
        )
    if pods_minus[0] != from_version:
        return ("fail", "requires-standard", f"lockfile PODS diff from version {pods_minus[0]!r} != declared {from_version!r}; re-open as standard")
    if pods_plus[0] != to_version:
        return ("fail", "requires-standard", f"lockfile PODS diff to version {pods_plus[0]!r} != declared {to_version!r}; re-open as standard")

    # DEPENDENCIES 版本引用：若变化必须严格 from→to 成对（0 或 1 对）
    if len(dep_minus) != len(dep_plus):
        return ("fail", "requires-standard", f"lockfile {dep} DEPENDENCIES version lines unbalanced ({len(dep_minus)} removed, {len(dep_plus)} added); re-open as standard")
    if len(dep_minus) > 1:
        return ("fail", "requires-standard", f"lockfile {dep} DEPENDENCIES version pair count > 1; re-open as standard")
    if len(dep_minus) == 1:
        if dep_minus[0] != from_version:
            return ("fail", "requires-standard", f"lockfile DEPENDENCIES diff from version {dep_minus[0]!r} != declared {from_version!r}; re-open as standard")
        if dep_plus[0] != to_version:
            return ("fail", "requires-standard", f"lockfile DEPENDENCIES diff to version {dep_plus[0]!r} != declared {to_version!r}; re-open as standard")

    # checksum：若变化必须严格一减一加且只限目标依赖。
    # 绑定校验（issue #3）：minus 必须精确等于 full HEAD checksum，plus 必须精确等于
    # full index checksum，且二者不同。无 pair 时 full HEAD/index checksum 必须相同。
    if len(ck_minus) != len(ck_plus):
        return ("fail", "requires-standard", f"lockfile {dep} checksum lines unbalanced ({len(ck_minus)} removed, {len(ck_plus)} added); re-open as standard")
    if len(ck_minus) > 1:
        return ("fail", "requires-standard", f"lockfile {dep} checksum pair count > 1; re-open as standard")
    if len(ck_minus) == 1:
        if ck_minus[0] != head_ck[0]:
            return ("fail", "requires-standard", f"lockfile {dep} checksum minus {ck_minus[0]!r} != full HEAD checksum {head_ck[0]!r}; re-open as standard")
        if ck_plus[0] != index_ck[0]:
            return ("fail", "requires-standard", f"lockfile {dep} checksum plus {ck_plus[0]!r} != full index checksum {index_ck[0]!r}; re-open as standard")
        if ck_minus[0] == ck_plus[0]:
            return ("fail", "requires-standard", f"lockfile {dep} checksum present in diff but unchanged; re-open as standard")
    else:
        # 无 checksum diff pair → full HEAD/index checksum 必须相同（未变）
        if head_ck[0] != index_ck[0]:
            return ("fail", "requires-standard", f"lockfile {dep} full checksum changed (HEAD {head_ck[0]!r} -> index {index_ck[0]!r}) but no diff pair; re-open as standard")

    # PODFILE CHECKSUM diff pair：Podfile 确实变化（版本 bump），故必须恰好一减一加。
    # minus 必须精确等于 full HEAD scalar == SHA-1(HEAD Podfile)；
    # plus 必须精确等于 full index scalar == SHA-1(index Podfile)；且二者不同。
    # 缺失/重复/错误值都 fail closed（真实 pod install 场景该 pair 必存在）。
    if len(pfc_minus) != 1 or len(pfc_plus) != 1:
        return (
            "fail", "requires-standard",
            f"lockfile PODFILE CHECKSUM must have exactly one from->to pair "
            f"(got {len(pfc_minus)} removed, {len(pfc_plus)} added); "
            "a real pod install updates PODFILE CHECKSUM; re-open as standard",
        )
    if pfc_minus[0] != head_pfc:
        return ("fail", "requires-standard", f"lockfile PODFILE CHECKSUM minus {pfc_minus[0]!r} != full HEAD scalar {head_pfc!r}; re-open as standard")
    if pfc_plus[0] != index_pfc:
        return ("fail", "requires-standard", f"lockfile PODFILE CHECKSUM plus {pfc_plus[0]!r} != full index scalar {index_pfc!r}; re-open as standard")
    if pfc_minus[0] == pfc_plus[0]:
        return ("fail", "requires-standard", "lockfile PODFILE CHECKSUM present in diff but unchanged; Podfile changed so checksum must differ; re-open as standard")

    return ("pass", None, "")


def validate_pod_patch(project_root, staged, params):
    """pod-patch 范围校验。返回 (result, escalation, reason)。"""
    dependency = params.get("dependency", "")
    from_version = params.get("from_version", "")
    to_version = params.get("to_version", "")

    if not dependency or not from_version or not to_version:
        return ("fail", None, "pod-patch requires dependency/from_version/to_version")

    # 仅 Podfile/Podfile.lock 变化
    paths = [e["path"] for e in staged["entries"]]
    bad = [p for p in paths if p not in POD_FILES]
    if bad:
        return (
            "fail", "requires-standard",
            f"pod-patch allows only Podfile/Podfile.lock; found {bad}; re-open as standard",
        )
    if "Podfile" not in paths or "Podfile.lock" not in paths:
        return (
            "fail", "requires-standard",
            "pod-patch requires both Podfile and Podfile.lock changes; re-open as standard",
        )

    # 文件类型/mode/status 校验：必须是普通文件的 modified
    for e in staged["entries"]:
        if e["status"] != "M":
            return ("fail", "requires-standard", f"pod-patch files must be modified (M), got {e['status']} for {e['path']}; re-open as standard")
        if e["type"] != "file":
            return ("fail", "requires-standard", f"pod-patch files must be regular files, got {e['type']} for {e['path']}; re-open as standard")

    # Podfile diff 校验
    res, esc, reason = _validate_podfile_diff(project_root, dependency, from_version, to_version)
    if res != "pass":
        return res, esc, reason

    # Podfile.lock diff 校验
    res, esc, reason = _validate_lockfile_diff(project_root, dependency, from_version, to_version)
    if res != "pass":
        return res, esc, reason

    return ("pass", None, "")


def compute_scope_digest(staged):
    """计算 scope digest：head + index_tree + entries canonical 的 sha256。"""
    canonical = json.dumps(
        {
            "head": staged["head"],
            "index_tree": staged["index_tree"],
            "entries": staged["entries"],
        },
        sort_keys=True, ensure_ascii=False, separators=(",", ":"),
    )
    return _hash_bytes(canonical.encode("utf-8", "surrogateescape"))


def validate(project_root, kind, params=None):
    """主校验入口。返回完整结果 dict。"""
    params = params or {}
    project_root = Path(project_root)

    if kind not in ("docs", "pod-patch"):
        raise SystemExit(f"unknown trivial-kind: {kind}; use docs|pod-patch")

    # 通用：staged 非空 + 工作树干净
    staged = compute_staged_state(project_root)
    if not staged["entries"]:
        return {
            "validator_version": VALIDATOR_VERSION,
            "kind": kind,
            "head": staged["head"],
            "index_tree": staged["index_tree"],
            "entries": [],
            "scope_digest": compute_scope_digest(staged),
            "result": "fail",
            "escalation": None,
            "reason": "no staged files; stage changes before validate-trivial",
            "params": params,
        }

    clean_ok, clean_reason = check_clean_worktree(project_root)
    if not clean_ok:
        return {
            "validator_version": VALIDATOR_VERSION,
            "kind": kind,
            "head": staged["head"],
            "index_tree": staged["index_tree"],
            "entries": staged["entries"],
            "scope_digest": compute_scope_digest(staged),
            "result": "fail",
            "escalation": None,
            "reason": clean_reason,
            "params": params,
        }

    # 范围校验
    if kind == "docs":
        result, escalation, reason = validate_docs(project_root, staged)
    else:
        result, escalation, reason = validate_pod_patch(project_root, staged, params)

    return {
        "validator_version": VALIDATOR_VERSION,
        "kind": kind,
        "head": staged["head"],
        "index_tree": staged["index_tree"],
        "entries": staged["entries"],
        "scope_digest": compute_scope_digest(staged),
        "result": result,
        "escalation": escalation,
        "reason": reason,
        "params": params,
    }


def compute_digest_only(project_root):
    """仅重算 digest（approve/commit 漂移比对用），不做范围校验。

    返回 {validator_version, head, index_tree, entries, scope_digest}。
    """
    staged = compute_staged_state(project_root)
    return {
        "validator_version": VALIDATOR_VERSION,
        "head": staged["head"],
        "index_tree": staged["index_tree"],
        "entries": staged["entries"],
        "scope_digest": compute_scope_digest(staged),
    }


def main():
    if len(sys.argv) < 3:
        print(
            "Usage: trivial_scope_validator.py <project_root> <kind|'--digest'> [params_json]",
            file=sys.stderr,
        )
        sys.exit(2)
    project_root = sys.argv[1]
    kind = sys.argv[2]

    if kind == "--digest":
        result = compute_digest_only(project_root)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return

    params = {}
    if len(sys.argv) > 3:
        try:
            params = json.loads(sys.argv[3])
        except json.JSONDecodeError as e:
            print(f"ERROR: invalid params_json: {e}", file=sys.stderr)
            sys.exit(2)
    result = validate(project_root, kind, params)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if result["result"] != "pass":
        sys.exit(1)


if __name__ == "__main__":
    main()
