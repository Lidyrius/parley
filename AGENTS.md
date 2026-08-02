# Repository Guidelines

## Project Structure & Module Organization

Parley is a cross-platform voice layer for Claude Code and Codex. The macOS Swift 6/SwiftUI
menu-bar app is in `app/Sources/Parley/`, with XCTest cases in
`app/Tests/ParleyTests/`. The Windows .NET 8 tray app is in `windows/`; its
GitHub Actions build is defined in `.github/workflows/windows-build.yml`.
Shared Claude Code/Codex hooks and commands live in `plugin/`, reusable build and audio
scripts in `scripts/`, and the hook integration test in `tests/`. User-facing
documentation is at the repository root and in `docs/`. Keep platform behavior
in sync: implement feature changes in both `app/` and `windows/`, and update
`plugin/` when the hook or contract changes. See `CLAUDE.md` for additional
cross-platform constraints.

## Build, Test, and Development Commands

```bash
cd app && swift build                 # Debug macOS build
cd app && swift build -c release     # Release executable
cd app && swift test                  # XCTest suite
bash tests/hook_test.sh               # Claude Stop-hook checks
bash tests/codex_hook_test.sh         # Codex Stop-hook checks
bash tests/codex_plugin_test.sh       # Codex manifest/detection/sync checks
bash scripts/make-app.sh              # Build, bundle, sign, and install Parley.app
```

The Windows equivalent is `dotnet publish windows/Parley.Win.csproj -c Release
-r win-x64 -o publish`; normally verify it through the `windows-build` GitHub
Actions workflow because the repository does not require a local .NET setup.
Use `SMOKE_TEST.md` for manual audio, permissions, API, and end-to-end checks.

## Coding Style & Naming Conventions

Use four-space indentation, Swift lowerCamelCase for values/functions and
PascalCase for types, and idiomatic C# PascalCase public members with `_camelCase`
private fields. Shell scripts should use Bash strict mode (`set -euo pipefail`)
and remain LF-formatted. No formatter or linter is configured; preserve the
surrounding style and keep changes focused.

## Testing Guidelines

Name Swift tests `*Tests.swift` and methods descriptively with `test...`. Run
`swift test`, `bash tests/hook_test.sh`, `bash tests/codex_hook_test.sh`, and
`bash tests/codex_plugin_test.sh` for changes affecting shared behavior. The Codex
adapter suite covers all currently defined behavioral branches; instrumented
line/branch coverage remains a CI release-gate item in `TODO.md`.

## Commit & Pull Request Guidelines

Use the Conventional Commit style used in history, for example
`fix(stt): surface transcription errors` or `feat(onboarding): add voice preview`.
PRs should explain the behavior change, list verification commands, note macOS
and Windows parity, and include screenshots or recordings for UI changes. Link
an issue when one exists, and never commit API keys or local `.env` contents.
