# Parley — working notes for Claude

Parley is a voice layer for Claude Code: on a Stop hook the app speaks the `<speak>`
summary, records the reply, transcribes it, and injects it back. Two apps share one
plugin + contract:

- **macOS** — `app/` (Swift 6 / SwiftUI menu-bar app). Build/bundle: `bash scripts/make-app.sh`. Release: `bash scripts/release.sh vX.Y.Z`.
- **Windows** — `windows/` (C# / .NET 8 tray app). No local dotnet — the GitHub Actions `windows-build` workflow is the compiler; tag `win-vX.Y.Z` to cut a release.
- **Shared** — `plugin/` (Stop hook, `/parley:voice`, greet/stop scripts), `README.md`, the `credentials.json` contract, and the `.parley.json` per-project name.

## Cross-platform rule (required)

**Every feature ships for BOTH macOS and Windows in the same change.** Implement it in
`app/` and `windows/` together (and in `plugin/` if the hook/contract changes). Keep the
two ports behaviourally 1:1.

- **Testing:** use the user's Mac to build + run + verify the macOS side now. Windows is
  verified later on a real machine — a missing Windows test is **not a blocker** for
  landing the feature; still write the Windows code and confirm it compiles via CI
  (`gh run watch` on the `windows-build` workflow).
- After the macOS side is verified and the Windows side compiles, commit both, release the
  macOS version (`release.sh`), and tag the Windows release (`win-v*`).

## Constraints worth remembering

- Media play-state on macOS is gated → use the vendored `mediaremote-adapter` (see the
  `parley-macos-media-playstate` memory). Windows uses the public GSMTC WinRT API.
- Shell scripts must stay LF (`.gitattributes`) — CRLF breaks bash shebangs on Windows.
- Stats (`stats.json` in the OS app-data dir) must survive updates — never delete app data
  on install/update.
