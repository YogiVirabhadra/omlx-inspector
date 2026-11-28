#!/usr/bin/env python3
"""Lint every Swift file in the repository with swift-format, without rewriting.

The rules live in the repository's `.swift-format` file. To fix reported issues:

    xcrun swift-format format --in-place --recursive Package.swift Sources Tests Tools
"""
import argparse
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# Shipped code only; `Docs` holds archived, unbuilt material.
SCOPE = ['Package.swift', 'Sources', 'Tests', 'Tools']


def swift_files() -> list[str]:
    """Tracked and untracked (but not ignored) Swift files, relative to the root."""
    output = subprocess.check_output(
        ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z', '--', *SCOPE], cwd=ROOT)
    paths = {path.decode() for path in output.split(b'\0') if path.endswith(b'.swift')}
    return sorted(path for path in paths if (ROOT / path).is_file())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    # Kept so the existing CI step (`--base <sha>`) still works; every file is linted regardless.
    parser.add_argument('--base', help=argparse.SUPPRESS)
    parser.parse_args()
    paths = swift_files()
    result = subprocess.run(['xcrun', 'swift-format', 'lint', '--strict', *paths], cwd=ROOT)
    if result.returncode != 0:
        raise SystemExit(result.returncode)
    print(f'Formatting passed for {len(paths)} Swift files.')


if __name__ == '__main__':
    main()
