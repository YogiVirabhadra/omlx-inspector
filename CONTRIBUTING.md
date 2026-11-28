# Contributing

oMLX Inspector is a personal utility, shared as-is in case it is useful to others.

- **Bug reports and ideas are welcome** as GitHub issues. If a log record triggers a problem, describe it or reproduce it with a small synthetic log. **Never attach real logs**: they contain your prompts, tool arguments, and results.
- **Pull requests are not being accepted.** That isn't a judgment of your change; I just don't plan to review or maintain contributions. You are welcome to fork the project and change it however you like under the [MIT license](LICENSE).

## Working on your own copy

Everything below assumes macOS 27 with Xcode installed. See the [README](README.md) for requirements.

### Build and validate

```sh
./Tools/build.sh                 # builds and ad-hoc signs build/oMLX Inspector.app
./Tools/validate.sh              # tests, formatting, project check, and app build
./Tools/validate.sh --large      # also runs the 2 GiB synthetic-log test
```

`validate.sh` is the gate to run before you commit.

### Formatting

All Swift code follows the repository's `.swift-format` configuration. To reformat:

```sh
xcrun swift-format format --in-place --recursive Package.swift Sources Tests Tools
```

### The Xcode project is generated

`oMLX Inspector.xcodeproj` is produced by `Tools/make_project.py`. After adding, removing, or renaming files under `Sources`, run `python3 Tools/make_project.py` and commit the result. `validate.sh` fails if the committed project is out of date.

## How the code is organized

| Location | What it contains |
| --- | --- |
| `Sources/InspectorCore` | Everything that reads and interprets logs. No UI; it builds and is tested with SwiftPM. |
| `Sources/InspectorApp` | The SwiftUI/AppKit application. `Workspace` holds all UI state; the views read it and call its methods. |
| `Tests/InspectorCoreTests` | Parsing, inference, indexing, and presentation tests using synthetic logs. |
| `Tests/InspectorAppTests` | Workspace behavior and native rendering tests. |
| `Tools` | Build, validation, project generation, and fixture scripts. |

Key types in `InspectorCore`:

- `LogIndex` reads a log incrementally and frames it into records; `LogSession` runs it off the main actor.
- `EvidenceBuilder` turns records into conversations, turns, and timeline events. Its rules are documented in [EVIDENCE.md](EVIDENCE.md); update that document and the matching tests together when changing a rule.
- `LogGrammar` defines every supported log line pattern.
- `LogReader` is the public entry point for loading a log and for the verified detail behind an event or record.
- `LogSnapshot` is an immutable view of an indexed log. Record bodies are read from disk on demand and checked against their digests.
