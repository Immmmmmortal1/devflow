#!/usr/bin/env python3
"""统一安全原子 JSON 写辅助模块。

被 issue-review-ticket.sh、cancel-review-ticket.sh、record-review-result.sh、
dev-flow-session.sh、install-review-backend.sh、run-review-fallback.sh 共享。

安全模型（两阶段检查）：
  1. 显式 trusted root（不接受隐式推断）
  2. trusted root 自身必须 lstat 非 symlink
  3. 第一阶段：沿原始未 resolve 路径从 trusted_root 到 target parent，
     逐级 lstat 拒绝任何 symlink（包括指向 trusted_root 内部的 symlink）
  4. 第二阶段：resolve 后做边界校验，确认 target/parent 在 trusted root 内
  5. 目标拒绝 symlink
  6. mkdir 逐级安全创建（每级 lstat 检查）
  7. mkstemp 同目录 + fsync + chmod 0600 + os.replace
  8. 尽量 fsync parent 目录
  9. 不检查 trusted root 之上的系统祖先（避免 /var → /private/var 问题）

Usage（作为模块 import 或直接 python3 -c 调用）:
  from atomic_json_write import safe_atomic_write_json, safe_mkdir, safe_read_json, safe_read_bytes
  safe_atomic_write_json(trusted_root, target_path, data, mode=0o600)
  data = safe_read_json(trusted_root, target_path)

  # 命令行模式（从 stdin 读 JSON）:
  python3 atomic_json_write.py <trusted_root> <target_path>
"""
import json
import os
import sys
import tempfile
from pathlib import Path


def _lstat_is_symlink(path) -> bool:
    """用 lstat 检查是否 symlink（不跟随）。"""
    try:
        return os.lstat(str(path)).st_mode & 0o170000 == 0o120000
    except OSError:
        return False


def _validate_trusted_root(trusted_root: Path) -> None:
    """验证 trusted root：必须存在、是目录、lstat 非 symlink。"""
    if not trusted_root.exists():
        raise SystemExit(f"trusted root does not exist: {trusted_root}")
    if not trusted_root.is_dir():
        raise SystemExit(f"trusted root is not a directory: {trusted_root}")
    if _lstat_is_symlink(trusted_root):
        raise SystemExit(f"refusing to use symlinked trusted root: {trusted_root}")


def _check_original_path(trusted_root: Path, target_path: Path) -> None:
    """第一阶段：沿原始未 resolve 路径逐级 lstat，拒绝任何 symlink。

    从 trusted_root 到 target_path 的每个已有 path component 用 lstat 检查。
    包括指向 trusted_root 内部的 symlink 也拒绝（symlink 可被交换）。
    用 normpath 去掉 . 和 .. 但不 resolve symlink。
    """
    root_norm = Path(os.path.normpath(str(trusted_root)))
    target_norm = Path(os.path.normpath(str(target_path)))

    # 尝试计算原始路径的相对路径
    try:
        rel = target_norm.relative_to(root_norm)
    except ValueError:
        # 原始路径不以 trusted_root 为前缀——无法沿原始路径逐级检查
        # 交由第二阶段 resolve 边界校验处理
        return

    # 逐级 lstat 检查原始路径（包括 trusted_root 自身）
    current = root_norm
    # 先检查 trusted_root 自身
    if _lstat_is_symlink(current):
        raise SystemExit(f"refusing to write through symlinked trusted root: {current}")
    for part in rel.parts:
        current = current / part
        if current.exists() and _lstat_is_symlink(current):
            raise SystemExit(
                f"refusing to write through symlinked path component: {current}"
            )


def _check_resolved_boundary(trusted_root: Path, target_path: Path) -> None:
    """第二阶段：resolve 后做边界校验，确认在 trusted root 内。"""
    root_resolved = trusted_root.resolve()
    target_resolved = target_path.resolve()
    try:
        target_resolved.relative_to(root_resolved)
    except ValueError:
        raise SystemExit(
            f"target {target_resolved} resolves outside trusted root {root_resolved}"
        )


def safe_mkdir(trusted_root: Path, dir_path: Path) -> None:
    """安全创建目录：沿原始路径逐级创建，每级 lstat 检查 symlink。

    不检查 trusted root 之上的系统祖先。
    """
    _validate_trusted_root(trusted_root)

    root_norm = Path(os.path.normpath(str(trusted_root)))
    dir_norm = Path(os.path.normpath(str(dir_path)))

    # 如果目标已存在
    if dir_norm.exists():
        if not dir_norm.is_dir():
            raise SystemExit(f"path exists but is not a directory: {dir_norm}")
        if _lstat_is_symlink(dir_norm):
            raise SystemExit(f"refusing to create through symlink: {dir_norm}")
        # 验证在 trusted root 内（resolve 边界）
        _check_resolved_boundary(trusted_root, dir_norm)
        return

    # 沿原始路径逐级创建
    try:
        rel = dir_norm.relative_to(root_norm)
    except ValueError:
        raise SystemExit(
            f"target directory {dir_norm} is outside trusted root {root_norm} (original path)"
        )

    current = root_norm
    for part in rel.parts:
        current = current / part
        if current.exists():
            if not current.is_dir():
                raise SystemExit(f"path component is not a directory: {current}")
            if _lstat_is_symlink(current):
                raise SystemExit(
                    f"refusing to create through symlinked component: {current}"
                )
        else:
            os.mkdir(str(current), mode=0o700)


def safe_atomic_write_json(trusted_root, target_path, data, mode=0o600, indent=2):
    """安全原子写入 JSON 文件。

    Args:
        trusted_root: 显式 trusted root（Path 或 str）
        target_path: 目标文件路径（Path 或 str）
        data: 要写入的 dict/list（会被 json.dumps）
        mode: 文件权限（默认 0600）
        indent: JSON 缩进（默认 2）

    Returns:
        Path: 写入的目标文件路径

    Raises:
        SystemExit: 任何安全检查失败
    """
    trusted_root = Path(trusted_root)
    target_path = Path(target_path)

    _validate_trusted_root(trusted_root)

    # 目标自身拒绝 symlink
    if _lstat_is_symlink(target_path):
        raise SystemExit(f"refusing to write through a symlink: {target_path}")

    # 确保 parent 目录存在（安全创建）
    target_parent = target_path.parent
    if not target_parent.exists():
        safe_mkdir(trusted_root, target_parent)

    # 第一阶段：沿原始路径逐级 lstat
    _check_original_path(trusted_root, target_parent)

    # 第二阶段：resolve 边界校验
    _check_resolved_boundary(trusted_root, target_parent)

    # resolve 后确认 target 自身也在 trusted root 内
    root_resolved = trusted_root.resolve()
    target_resolved = target_path.resolve()
    try:
        target_resolved.relative_to(root_resolved)
    except ValueError:
        raise SystemExit(
            f"target {target_resolved} resolves outside trusted root {root_resolved}"
        )

    # 序列化 JSON
    if isinstance(data, (dict, list)):
        content = json.dumps(data, ensure_ascii=False, indent=indent) + "\n"
    elif isinstance(data, str):
        content = data
    else:
        content = str(data)

    # mkstemp 同目录 + fsync + chmod + os.replace
    parent_resolved = target_parent.resolve()
    fd, tmp = tempfile.mkstemp(
        dir=str(parent_resolved), prefix=".atomic-", suffix=".tmp"
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, str(target_resolved))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

    # 尽量 fsync parent 目录
    try:
        parent_fd = os.open(str(parent_resolved), os.O_RDONLY)
        try:
            os.fsync(parent_fd)
        finally:
            os.close(parent_fd)
    except OSError:
        pass  # 某些文件系统不支持目录 fsync

    return target_resolved


def safe_atomic_write_bytes(trusted_root, target_path, data: bytes, mode=0o600):
    """安全原子写入二进制文件。与 safe_atomic_write_json 相同的安全检查。"""
    trusted_root = Path(trusted_root)
    target_path = Path(target_path)

    _validate_trusted_root(trusted_root)

    if _lstat_is_symlink(target_path):
        raise SystemExit(f"refusing to write through a symlink: {target_path}")

    target_parent = target_path.parent
    if not target_parent.exists():
        safe_mkdir(trusted_root, target_parent)

    _check_original_path(trusted_root, target_parent)
    _check_resolved_boundary(trusted_root, target_parent)

    root_resolved = trusted_root.resolve()
    target_resolved = target_path.resolve()
    try:
        target_resolved.relative_to(root_resolved)
    except ValueError:
        raise SystemExit(
            f"target {target_resolved} resolves outside trusted root {root_resolved}"
        )

    parent_resolved = target_parent.resolve()
    fd, tmp = tempfile.mkstemp(
        dir=str(parent_resolved), prefix=".atomic-", suffix=".tmp"
    )
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, str(target_resolved))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

    try:
        parent_fd = os.open(str(parent_resolved), os.O_RDONLY)
        try:
            os.fsync(parent_fd)
        finally:
            os.close(parent_fd)
    except OSError:
        pass

    return target_resolved


def safe_write_text(trusted_root, target_path, text, mode=0o600):
    """安全原子写入文本文件（便捷封装）。"""
    return safe_atomic_write_bytes(trusted_root, target_path, text.encode("utf-8"), mode)


def _lstat_check_no_symlink(path) -> None:
    """lstat 检查路径不是 symlink（不跟随）。路径不存在时静默通过。"""
    if _lstat_is_symlink(path):
        raise SystemExit(f"refusing to write through a symlink: {path}")


def safe_write_external(target_path, content, mode=0o600, trusted_external_root=None) -> Path:
    """安全原子写入外部路径（host config 等不在 .dev-flow 下的文件）。

    安全模型：
      1. 显式 trusted_external_root（默认 HOME）
      2. trusted_external_root 自身 lstat 非 symlink
      3. 沿原始未 resolve 路径从 trusted_external_root 到 target parent 逐级 lstat，
         拒绝任何 symlink（包括指向 trusted_external_root 内部的 symlink）
      4. resolve 后边界校验：target 必须在 trusted_external_root 内
      5. 目标拒绝 symlink
      6. mkstemp + os.replace 原子写入
      7. macOS 系统祖先约束：trusted_external_root 默认 HOME，不遍历 HOME 之上的系统 symlink

    与 safe_atomic_write_bytes 的区别：
    - trusted_external_root 默认 HOME（不强制 .dev-flow 边界）
    - host config 允许 HOME 内路径，目标必须在 HOME 内
    - 越界 / symlink → fail closed

    Args:
        target_path: 目标文件路径（Path 或 str）
        content: 要写入的内容（str 或 bytes）
        mode: 文件权限（默认 0600）
        trusted_external_root: 显式外部根（默认 HOME）

    Returns:
        Path: 写入的目标文件路径

    Raises:
        SystemExit: 任何安全检查失败
    """
    target_path = Path(os.path.normpath(str(target_path)))

    # 确定 trusted_external_root（默认 HOME）
    if trusted_external_root is None:
        trusted_external_root = Path(os.path.expanduser("~"))
    else:
        trusted_external_root = Path(os.path.normpath(str(trusted_external_root)))

    # trusted_external_root 自身 lstat 非 symlink
    if not trusted_external_root.exists():
        raise SystemExit(f"trusted external root does not exist: {trusted_external_root}")
    if not trusted_external_root.is_dir():
        raise SystemExit(f"trusted external root is not a directory: {trusted_external_root}")
    if _lstat_is_symlink(trusted_external_root):
        raise SystemExit(
            f"refusing to write through symlinked trusted external root: {trusted_external_root}"
        )

    # target 自身拒绝 symlink
    if _lstat_is_symlink(target_path):
        raise SystemExit(f"refusing to write through a symlink: {target_path}")

    # target 必须在 trusted_external_root 下（原始路径）
    target_parent = target_path.parent
    try:
        rel = target_parent.relative_to(trusted_external_root)
    except ValueError:
        raise SystemExit(
            f"target {target_path} is not under trusted external root "
            f"{trusted_external_root} (original path)"
        )

    # 沿原始路径从 trusted_external_root 到 target_parent 逐级 lstat
    # 拒绝任何 symlink；不存在的目录逐级安全创建
    current = trusted_external_root
    for part in rel.parts:
        current = current / part
        if current.exists():
            if not current.is_dir():
                raise SystemExit(f"path component is not a directory: {current}")
            if _lstat_is_symlink(current):
                raise SystemExit(
                    f"refusing to write through symlinked path component: {current}"
                )
        else:
            os.mkdir(str(current), mode=0o755)

    # resolve 边界校验（defense in depth）
    root_resolved = trusted_external_root.resolve()
    target_resolved = target_path.resolve()
    try:
        target_resolved.relative_to(root_resolved)
    except ValueError:
        raise SystemExit(
            f"target {target_resolved} resolves outside trusted external root {root_resolved}"
        )

    # 序列化
    if isinstance(content, str):
        content = content.encode("utf-8")
    elif not isinstance(content, bytes):
        content = str(content).encode("utf-8")

    # mkstemp 同目录 + fsync + chmod + os.replace
    parent_resolved = target_parent.resolve()
    fd, tmp = tempfile.mkstemp(
        dir=str(parent_resolved), prefix=".atomic-", suffix=".tmp"
    )
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, str(target_resolved))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

    # 尽量 fsync parent 目录
    try:
        parent_fd = os.open(str(parent_resolved), os.O_RDONLY)
        try:
            os.fsync(parent_fd)
        finally:
            os.close(parent_fd)
    except OSError:
        pass

    return target_resolved


def safe_read_bytes(trusted_root, target_path) -> bytes:
    """安全读取文件原始字节：沿原始路径逐级 lstat，拒绝任何 symlink。

    安全模型（与写入一致）：
      1. 显式 trusted root（不接受隐式推断）
      2. trusted root 自身必须 lstat 非 symlink
      3. 沿原始未 resolve 路径从 trusted_root 到 target 逐级 lstat，
         拒绝任何 symlink（包括指向 trusted_root 内部的 symlink）
      4. resolve 后做边界校验（defense in depth）
      5. 目标拒绝 symlink
      6. 不可先 resolve 丢失原始组件
      7. 不可 ValueError pass — 原始路径不在 trusted root 下直接 fail closed

    Returns:
        bytes: 文件原始内容

    Raises:
        SystemExit: 任何安全检查失败
    """
    trusted_root = Path(os.path.normpath(str(trusted_root)))
    target_path = Path(os.path.normpath(str(target_path)))

    # 目标自身拒绝 symlink
    if _lstat_is_symlink(target_path):
        raise SystemExit(f"refusing to read through a symlink: {target_path}")

    # 沿原始路径逐级 lstat（不可 ValueError pass）
    try:
        rel = target_path.relative_to(trusted_root)
    except ValueError:
        # 原始路径不在 trusted root 下 → fail closed（不可 pass）
        raise SystemExit(
            f"target {target_path} is not under trusted root {trusted_root} (original path)"
        )

    # 逐级 lstat 检查原始路径（包括 trusted_root 自身）
    current = trusted_root
    if _lstat_is_symlink(current):
        raise SystemExit(f"refusing to read through symlinked trusted root: {current}")
    for part in rel.parts:
        current = current / part
        if current.exists() and _lstat_is_symlink(current):
            raise SystemExit(
                f"refusing to read through symlinked path component: {current}"
            )

    # resolve 边界校验（defense in depth）
    root_resolved = trusted_root.resolve()
    target_resolved = target_path.resolve()
    try:
        target_resolved.relative_to(root_resolved)
    except ValueError:
        raise SystemExit(
            f"target {target_resolved} resolves outside trusted root {root_resolved}"
        )

    if not target_path.is_file():
        raise SystemExit(f"target file does not exist: {target_path}")

    return target_path.read_bytes()


def safe_read_json(trusted_root, target_path):
    """安全读取 JSON 文件：路径校验 + 读取 + 解析。

    与 safe_read_bytes 相同的安全检查，返回解析后的 JSON 对象。
    """
    data = safe_read_bytes(trusted_root, target_path)
    return json.loads(data)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(
            "Usage: atomic_json_write.py <trusted_root> <target_path> [mode]",
            file=sys.stderr,
        )
        sys.exit(2)
    trusted_root = sys.argv[1]
    target_path = sys.argv[2]
    mode = int(sys.argv[3], 8) if len(sys.argv) > 3 else 0o600

    # 从 stdin 读 JSON
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        print(f"ERROR: invalid JSON on stdin: {e}", file=sys.stderr)
        sys.exit(2)

    result = safe_atomic_write_json(trusted_root, target_path, data, mode=mode)
    print(str(result))
