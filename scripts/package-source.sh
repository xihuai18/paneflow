#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
(( $# <= 1 )) || { print -u2 'Usage: scripts/package-source.sh [output-directory]'; exit 2; }
output_dir="${1:-$project_root/dist}"
mkdir -p "$output_dir"
/usr/bin/python3 - "$project_root" "$output_dir" <<'PY'
from pathlib import Path
import plistlib
import sys
import tarfile

root, output = (Path(arg).resolve() for arg in sys.argv[1:])
version = plistlib.loads((root / 'Resources/Info.plist').read_bytes())['CFBundleShortVersionString']
prefix = f'PaneFlow-{version}'
files = [root / name for name in (
    '.gitignore', 'Package.swift', 'README.md', 'LICENSE', 'LICENSE-STATUS.md',
    'NOTICE-PaneGrid', 'CONTRIBUTING.md', 'CHANGELOG.md',
)]
for directory, pattern in (
    ('Sources', '*.swift'), ('Resources', '*.plist'),
    ('scripts', '*.sh'), ('docs', '*.md'), ('docs/assets', '*.svg'), ('.github/workflows', '*.yml'),
):
    files.extend(sorted((root / directory).rglob(pattern)))
for path in files:
    if not path.is_file() or path.is_symlink() or not path.resolve().is_relative_to(root):
        raise SystemExit(f'Expected a source file inside the project: {path.relative_to(root)}')

destination = output / f'{prefix}-source-preview.tar.gz'
with tarfile.open(destination, 'w:gz') as archive:
    for path in sorted(files):
        info = archive.gettarinfo(str(path), arcname=str(Path(prefix) / path.relative_to(root)))
        info.uid = info.gid = 0
        info.uname = info.gname = ''
        with path.open('rb') as source:
            archive.addfile(info, source)
print(f'Packaged {len(files)} source files: {destination}')
PY
