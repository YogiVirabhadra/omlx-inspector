#!/usr/bin/env python3
"""Regression check for the source list shared by both app build methods."""
from pathlib import Path
import tempfile
import unittest
from source_files import swift_sources


class SourceDiscoveryTests(unittest.TestCase):
    def test_nested_files_and_spaces_match_both_build_inputs(self):
        with tempfile.TemporaryDirectory(prefix='inspector sources ') as directory:
            root = Path(directory)
            expected = [root / 'Sources/InspectorCore/Nested Folder/Model.swift',
                        root / 'Sources/InspectorApp/Window.swift']
            excluded = [root / 'Tests/Example.swift', root / 'Sources/Notes.txt']
            for path in expected + excluded:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            self.assertEqual(swift_sources(root), sorted(expected))
            # The build script consumes the same paths as NUL-delimited arguments.
            wire = b''.join(bytes(path) + b'\0' for path in swift_sources(root))
            self.assertEqual([Path(part.decode()) for part in wire.split(b'\0')[:-1]], sorted(expected))


if __name__ == '__main__':
    unittest.main()
