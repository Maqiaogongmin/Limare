#!/usr/bin/env python3
"""Export only allowlisted files from one frozen commit, without copying old Git history."""
import argparse
import json
import subprocess
from pathlib import Path


def export(root, commit, destination):
    exact = subprocess.check_output(['git', '-C', str(root), 'rev-parse', '--verify', commit + '^{commit}'], text=True).strip()
    if destination.exists():
        raise RuntimeError('Destination must not exist; refusing to overwrite another tree')
    allow = json.loads(subprocess.check_output(['git', '-C', str(root), 'show', exact + ':public-content-allowlist.json']))
    tree = subprocess.check_output(['git', '-C', str(root), 'ls-tree', '-r', '-z', exact])
    selected = []
    for entry in tree.split(b'\0'):
        if not entry:
            continue
        metadata, raw_path = entry.split(b'\t', 1)
        mode, kind, oid = metadata.decode().split()
        path = raw_path.decode()
        if any(path.startswith(directory) for directory in allow.get('excludedDirectories', [])):
            continue
        if path not in allow['files'] and not any(path.startswith(directory) for directory in allow['directories']):
            continue
        if kind != 'blob' or mode not in {'100644', '100755'} or any(part in {'..', '.git', 'xcuserdata', '__pycache__', 'node_modules', '.build'} for part in Path(path).parts):
            raise RuntimeError('Unexpected or unsafe content in allowlisted tree')
        selected.append((path, mode, oid))
    destination.mkdir(parents=True)
    for path, mode, oid in selected:
        target = destination / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(subprocess.check_output(['git', '-C', str(root), 'cat-file', 'blob', oid]))
        target.chmod(0o755 if mode == '100755' else 0o644)
    print(json.dumps({'exported_file_count': len(selected), 'source_commit': exact, 'old_history_copied': False}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('commit')
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    export(Path(__file__).resolve().parent.parent, args.commit, args.destination.resolve())
