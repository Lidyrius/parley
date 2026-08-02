# TODO

## Codex coverage audit — 2026-08-02

The declared Codex feature matrix is currently 100% covered by automated behavioral
tests. This is feature coverage, not an instrumented shell line/branch percentage.

- [x] `tests/codex_hook_test.sh`: no tag, `<speak>`, `<speak-end>`, unclosed tags,
      Unicode/quotes, transcript continuation, wait, park/wake, missing input, and
      app failure.
- [x] `tests/codex_plugin_test.sh`: manifest/skill/hook package, client detection,
      marketplace creation, enabled/disabled sync, and preservation of foreign links.
- [x] Real Codex CLI 0.146.0 accepts the generated marketplace and installs
      `parley@parley-local` from the local source.
- [x] `.github/workflows/codex-tests.yml` runs the shared hook and Codex suites on
      every relevant push or pull request.

## Codex integration release gate

- [ ] Keep the automated Codex feature matrix at 100% when the adapter changes.
- [ ] Run the Codex suite on macOS and Windows with the supported Codex CLI versions;
      the local shell suite is the automated gate, while real hook trust is manual.
- [ ] Verify the installed Codex plugin through `/hooks`, then test `$parley-voice`
      in a fresh thread after every plugin or hook update.
- [ ] Record line/branch coverage from the Codex suite in CI once a shell coverage
      tool is available on the runners; keep that measurement at 100% as well.
