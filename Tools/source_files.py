#!/usr/bin/env python3
"""Shared recursive Swift source discovery for the app and Xcode project builds."""
from pathlib import Path
import sys


def swift_sources(root: Path) -> list[Path]:
    return sorted(path for path in (root / 'Sources').rglob('*.swift') if path.is_file())


if __name__ == '__main__':
    root = Path(__file__).resolve().parents[1]
    for path in swift_sources(root):
        sys.stdout.buffer.write(bytes(path) + b'\0')
