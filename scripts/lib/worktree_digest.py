#!/usr/bin/env python3
"""统一工作树审查摘要（shared worktree digest）。

被 issue-review-ticket.sh、run-review-fallback.sh、dev-flow-session.sh record-gate 共享。

摘要覆盖：
  - tracked: 枚举相对 merge-base 发生变化的 tracked paths（含 commit→HEAD、index、worktree
    删除/重命名），对每个 path 记录结构化字段（base/HEAD/index blob id+mode、worktree
    存在性/lstat mode/文件内容 sha256 或 symlink target hash），二进制安全。
  - untracked: 所有 untracked 文件的相对路径 + mode + 内容 sha256（二进制安全）
排除 .git/ 和 .dev-flow/ 运行 artifact。
要求项目为 git 仓库且 base ref 可解析；非 git 仓库直接 fail。

base_ref 稳定性：ticket 签发时解析 base ref → merge_base commit SHA，record-gate 重算时
用同一 merge_base SHA（不依赖 branch 移动），防止漂移。
"""
import hashlib
import json
import os
import stat
import subprocess
import sys
from pathlib import Path

# ── ref 注入防护 ──
_INVALID_REF_CHARS = set(" ..@{} \t\n~^:*?*[]\\")

def _validate_ref(ref: str) -> None:
    if not ref or ref.startswith("-") or any(c in _INVALID_REF_CHARS for c in ref):
        raise SystemExit(f"invalid git ref for review base: {ref!r}")

def resolve_base(project_root, override=""):
    """解析 base ref，返回 (ref_name, merge_base_sha)。

    merge_base SHA 固化到 ticket，record-gate 重算时用同一 SHA，不因 branch 移动漂移。
    """
    if override:
        _validate_ref(override)
        # override 可以是 ref 或 SHA
        base_ref = override
    else:
        base_ref = ""
        for candidate in ("origin/main", "origin/master", "main", "master"):
            r = subprocess.run(
                ["git", "-C", str(project_root), "rev-parse", "--verify", "--quiet", candidate],
                capture_output=True, text=True,
            )
            if r.returncode == 0:
                base_ref = candidate
                break
        if not base_ref:
            raise SystemExit(
                "cannot resolve a base ref for worktree digest; set DEV_FLOW_REVIEW_BASE"
            )

    # 验证 base 指向真实 commit
    verify = subprocess.run(
        ["git", "-C", str(project_root), "rev-parse", "--verify", "--quiet", f"{base_ref}^{{commit}}"],
        capture_output=True, text=True,
    )
    if verify.returncode != 0:
        raise SystemExit(f"review base does not resolve to a commit: {base_ref}")

    # 计算 merge-base SHA（固化）
    mb = subprocess.run(
        ["git", "-C", str(project_root), "merge-base", base_ref, "HEAD"],
        capture_output=True, text=True,
    )
    if mb.returncode != 0:
        raise SystemExit(f"cannot compute merge-base: {mb.stderr}")
    merge_base_sha = mb.stdout.strip()

    return base_ref, merge_base_sha


def _git_bytes(project_root, args):
    """Run git, return stdout as raw bytes (binary-safe)."""
    r = subprocess.run(
        ["git", "-C", str(project_root)] + args,
        capture_output=True,
    )
    if r.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed: {r.stderr.decode('utf-8', 'replace')}")
    return r.stdout


def _git_text(project_root, args):
    """Run git, return stdout as text."""
    r = subprocess.run(
        ["git", "-C", str(project_root)] + args,
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed: {r.stderr}")
    return r.stdout


def _hash_bytes(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def _hash_file_binary(path: Path) -> str:
    """Binary-safe content hash of a file."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return "sha256:" + h.hexdigest()


def _hash_symlink_target(path: Path) -> str:
    """Hash the symlink target string (not the file content)."""
    try:
        target = os.readlink(str(path))
        return "sha256:symlink:" + hashlib.sha256(target.encode("utf-8", "surrogateescape")).hexdigest()
    except OSError:
        return "sha256:symlink:unreadable"


def _get_blob_id_mode(project_root, treeish, rel_path):
    """获取指定 treeish 中文件的 blob id 和 mode。

    Returns: (blob_id, mode) 或 (None, None) 如果文件不存在。
    """
    r = subprocess.run(
        ["git", "-C", str(project_root), "ls-tree", "--format=%(objectmode) %(objectname)", treeish, "--", rel_path],
        capture_output=True, text=True,
    )
    if r.returncode != 0 or not r.stdout.strip():
        return (None, None)
    parts = r.stdout.strip().split(" ", 1)
    if len(parts) != 2:
        return (None, None)
    return (parts[1], parts[0])


def _get_index_blob_id_mode(project_root, rel_path):
    """获取 index 中文件的 blob id 和 mode。

    Returns: (blob_id, mode) 或 (None, None) 如果文件不在 index 中。
    """
    r = subprocess.run(
        ["git", "-C", str(project_root), "ls-files", "-s", "--", rel_path],
        capture_output=True, text=True,
    )
    if r.returncode != 0 or not r.stdout.strip():
        return (None, None)
    # 格式: <mode> <hash> <stage>\t<path>
    parts = r.stdout.strip().split()
    if len(parts) < 3:
        return (None, None)
    return (parts[1], parts[0])


def _parse_name_status(raw: bytes):
    """解析 git diff --name-status -z 输出，返回 [(status, path), ...]。

    处理 R（rename）格式: R<score>\0old_path\0new_path
    """
    entries = []
    parts = raw.split(b"\0")
    i = 0
    while i < len(parts):
        part = parts[i]
        if not part:
            i += 1
            continue
        decoded = part.decode("utf-8", "surrogateescape")
        if decoded[0] in ("R", "C"):
            # R100\0old_path\0new_path
            status = decoded[0]
            old_path = parts[i + 1].decode("utf-8", "surrogateescape") if i + 1 < len(parts) else ""
            new_path = parts[i + 2].decode("utf-8", "surrogateescape") if i + 2 < len(parts) else ""
            entries.append((status, new_path, old_path))
            i += 3
        else:
            status = decoded[0]
            path = parts[i + 1].decode("utf-8", "surrogateescape") if i + 1 < len(parts) else ""
            entries.append((status, path, None))
            i += 2
    return entries


def compute_worktree_digest(project_root, base_override="", merge_base_override=""):
    """Compute the unified worktree digest.

    Args:
        project_root: 项目根目录
        base_override: 显式 base ref（可选）
        merge_base_override: 显式 merge_base SHA（record-gate 重算时用，防止 branch 漂移）

    Returns dict with: base_ref, merge_base, worktree_digest, tracked_digest, untracked_digest
    """
    project_root = Path(project_root)
    if not project_root.is_dir():
        raise SystemExit(f"project root is not a directory: {project_root}")

    # 解析 base ref 和 merge_base
    if merge_base_override:
        # record-gate 重算：用固化的 merge_base SHA
        _validate_ref(merge_base_override)
        merge_base = merge_base_override
        # base_ref 仅用于信息记录，实际用 merge_base
        base_ref = merge_base_override
    else:
        base_ref, merge_base = resolve_base(project_root, base_override)

    # ── tracked: 枚举 merge_base → HEAD + index + worktree 的变化 paths ──
    # 用 git diff --name-status -z 获取 merge_base 到 HEAD 的变化
    # 再用 git diff --name-status -z --cached merge_base 获取 index 变化
    # 再用 git diff --name-status -z merge_base 获取 worktree 变化
    # 合并所有 path 去重

    changed_paths = set()

    # merge_base → HEAD (committed changes)
    raw_head = _git_bytes(project_root, ["diff", "--name-status", "-z", merge_base, "HEAD"])
    for entry in _parse_name_status(raw_head):
        changed_paths.add(entry[1])  # new_path
        if entry[2]:  # old_path for rename
            changed_paths.add(entry[2])

    # merge_base → index (staged changes)
    raw_index = _git_bytes(project_root, ["diff", "--name-status", "-z", "--cached", merge_base])
    for entry in _parse_name_status(raw_index):
        changed_paths.add(entry[1])
        if entry[2]:
            changed_paths.add(entry[2])

    # merge_base → worktree (unstaged changes, includes committed)
    raw_worktree = _git_bytes(project_root, ["diff", "--name-status", "-z", merge_base])
    for entry in _parse_name_status(raw_worktree):
        changed_paths.add(entry[1])
        if entry[2]:
            changed_paths.add(entry[2])

    # 对每个 path 构建结构化记录
    tracked_entries = []
    for rel_path in sorted(changed_paths):
        # 跳过 .dev-flow/ 路径
        if rel_path.startswith(".dev-flow/"):
            continue

        entry = {"path": rel_path}

        # base (merge_base) blob id + mode
        base_blob, base_mode = _get_blob_id_mode(project_root, merge_base, rel_path)
        entry["base_blob"] = base_blob or "missing"
        entry["base_mode"] = base_mode or "missing"

        # HEAD blob id + mode
        head_blob, head_mode = _get_blob_id_mode(project_root, "HEAD", rel_path)
        entry["head_blob"] = head_blob or "missing"
        entry["head_mode"] = head_mode or "missing"

        # index blob id + mode
        idx_blob, idx_mode = _get_index_blob_id_mode(project_root, rel_path)
        entry["index_blob"] = idx_blob or "missing"
        entry["index_mode"] = idx_mode or "missing"

        # worktree 存在性 + lstat mode + 内容 hash
        abs_path = project_root / rel_path
        if abs_path.exists() or abs_path.is_symlink():
            try:
                st = os.lstat(abs_path)
                entry["wt_mode"] = oct(st.st_mode & 0o7777)
            except OSError:
                entry["wt_mode"] = "lstat_failed"

            if abs_path.is_symlink():
                entry["wt_type"] = "symlink"
                entry["wt_content_hash"] = _hash_symlink_target(abs_path)
            elif abs_path.is_file():
                entry["wt_type"] = "file"
                entry["wt_content_hash"] = _hash_file_binary(abs_path)
            else:
                entry["wt_type"] = "other"
                entry["wt_content_hash"] = "sha256:non-file"
        else:
            entry["wt_type"] = "deleted"
            entry["wt_mode"] = "missing"
            entry["wt_content_hash"] = "sha256:deleted"

        tracked_entries.append(entry)

    # 序列化 tracked entries 为确定性字符串
    tracked_canonical = json.dumps(tracked_entries, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    tracked_digest = _hash_bytes(tracked_canonical.encode("utf-8", "surrogateescape"))

    # ── untracked files (exclude .dev-flow, binary-safe) ──
    # 用 -z 输出 NUL 分隔的路径列表（bytes 模式，安全处理任意文件名）
    untracked_raw = _git_bytes(project_root, [
        "ls-files", "--others", "--exclude-standard", "-z",
        "--", ":(exclude).dev-flow",
    ])
    untracked_paths = [p for p in untracked_raw.split(b"\0") if p]

    # 逐文件计算: relative_path(mode) + type + content_hash
    # untracked symlink 不能跳过（continue）——必须纳入 canonical digest：
    #   相对路径（bytes 安全表示）+ lstat mode + symlink target hash
    # 若 lstat/readlink 失败则 fail closed（不静默跳过）。
    untracked_entries = []
    for raw_path in sorted(untracked_paths):  # 排序保证确定性
        rel_path = raw_path.decode("utf-8", "surrogateescape")
        abs_path = project_root / rel_path
        try:
            st = os.lstat(abs_path)
        except OSError:
            # 文件在 git ls-files 与 lstat 之间消失（竞态）——fail closed
            raise SystemExit(f"untracked file disappeared during digest: {rel_path}")
        mode = oct(st.st_mode & 0o7777)
        if stat.S_ISLNK(st.st_mode):
            # untracked symlink：纳入 digest（不可跳过）
            target_hash = _hash_symlink_target(abs_path)
            if target_hash == "sha256:symlink:unreadable":
                raise SystemExit(f"cannot read symlink target (fail closed): {rel_path}")
            untracked_entries.append(f"{rel_path}\t{mode}\tsymlink\t{target_hash}")
        elif stat.S_ISDIR(st.st_mode):
            # 跳过目录——目录本身没有内容
            continue
        else:
            content_hash = _hash_file_binary(abs_path)
            untracked_entries.append(f"{rel_path}\t{mode}\tfile\t{content_hash}")

    untracked_canonical = "\n".join(untracked_entries)
    untracked_digest = _hash_bytes(untracked_canonical.encode("utf-8", "surrogateescape"))

    # ── 合并 tracked + untracked → worktree_digest ──
    combined = f"tracked:{tracked_digest}\nuntracked:{untracked_digest}"
    worktree_digest = _hash_bytes(combined.encode("utf-8"))

    return {
        "base_ref": base_ref,
        "merge_base": merge_base,
        "worktree_digest": worktree_digest,
        "tracked_digest": tracked_digest,
        "untracked_digest": untracked_digest,
    }


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: worktree_digest.py <project_root> [<base_ref_override>] [<merge_base_override>]", file=sys.stderr)
        sys.exit(2)
    root = sys.argv[1]
    override = sys.argv[2] if len(sys.argv) > 2 else ""
    env_override = os.environ.get("DEV_FLOW_REVIEW_BASE", "")
    merge_base_override = sys.argv[3] if len(sys.argv) > 3 else ""
    result = compute_worktree_digest(root, override or env_override, merge_base_override)
    print(json.dumps(result, ensure_ascii=False, indent=2))
