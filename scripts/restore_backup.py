#!/usr/bin/env python3
"""Inspect or restore a Localization Workbench backup manifest.

Dry-run is default; --apply creates a safety copy of the CURRENT files first.
No network access, no third-party Python packages.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import uuid


def inside(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("root", type=Path, help="Original project root directory")
    p.add_argument("backup", nargs="?", help="Backup folder name under .localization-workbench-backups, or 'list'")
    p.add_argument("--apply", action="store_true", help="Restore original files (writes to project)")
    a = p.parse_args()
    root = a.root.expanduser().resolve()
    backup_root = (root / ".localization-workbench-backups").resolve()
    if not inside(backup_root, root):
        raise ValueError("Backup directory resolves outside project root")
    if not backup_root.exists():
        raise FileNotFoundError("No backup directory exists")
    if not a.backup or a.backup == "list":
        for folder in sorted(backup_root.iterdir()):
            if folder.is_dir() and (folder / "manifest.json").exists():
                print(folder.name)
        return 0
    backup_dir = (backup_root / a.backup).resolve()
    if not inside(backup_dir, backup_root) or backup_dir == backup_root:
        raise ValueError("Backup path is not in the project backup directory")
    manifest = json.loads((backup_dir / "manifest.json").read_text(encoding="utf-8"))
    if Path(manifest["workspaceRoot"]).resolve() != root:
        raise ValueError("Manifest's original workspace does not match the requested root")
    actions = []
    for rec in manifest["files"]:
        relative = rec["relativePath"]
        if not relative or Path(relative).is_absolute() or ".." in Path(relative).parts:
            raise ValueError("Unsafe relative path in manifest")
        target = (root / relative).resolve()
        if not inside(target, root) or inside(target, backup_root):
            raise ValueError("Restore target outside allowed project files: " + relative)
        name = rec.get("backupFile")
        original = None
        if name is not None:
            if Path(name).name != name or "/" in name or "\\" in name:
                raise ValueError("Unsafe backup filename")
            source = (backup_dir / name).resolve()
            if not inside(source, backup_dir) or not source.is_file():
                raise ValueError("Missing backup file: " + name)
            original = source.read_bytes()
        actions.append((target, original))
    print(f"Restoration source: {backup_dir}")
    print(f"File operations: {len(actions)}")
    for target, original in actions:
        print(("RESTORE " if original is not None else "DELETE  ") + str(target.relative_to(root)))
    if not a.apply:
        print("Dry-run only. Specify --apply to restore.")
        return 0
    recovery = backup_root / ("pre-restore-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex)
    recovery.mkdir(parents=False)
    current = {}
    for index, (target, original) in enumerate(actions):
        if target.exists() and not target.is_file():
            raise ValueError("Restore target is not a regular file: " + str(target))
        current[target] = target.read_bytes() if target.exists() else None
        if current[target] is not None:
            (recovery / f"{index:04d}.bak").write_bytes(current[target])
    try:
        for target, original in actions:
            if original is None:
                target.unlink(missing_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                fd, temp = tempfile.mkstemp(prefix=".lw-restore-", dir=target.parent)
                try:
                    with os.fdopen(fd, "wb") as f:
                        f.write(original)
                        f.flush()
                        os.fsync(f.fileno())
                    os.replace(temp, target)
                finally:
                    if os.path.exists(temp):
                        os.unlink(temp)
    except Exception:
        for target, previous in current.items():
            if previous is None:
                target.unlink(missing_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(previous)
        raise
    print("Restored. Pre-restore copies are under:", recovery)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
