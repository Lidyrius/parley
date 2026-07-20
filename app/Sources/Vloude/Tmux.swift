import Foundation

// Inject a transcribed reply back into the originating Claude Code session via
// `tmux send-keys`. We pass argv arrays to Process (no shell), and use `-l`
// (literal) so quotes/newlines/semicolons in the transcript are never interpreted.
enum Tmux {
    /// The two argv arrays to run: literal text, then a separate Enter. Returns nil
    /// when there is no pane to target (not in tmux) — caller speaks only.
    static func sendKeysCommands(pane: String, text: String) -> [[String]]? {
        let p = pane.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return nil }
        return [
            ["send-keys", "-t", p, "-l", text],
            ["send-keys", "-t", p, "Enter"],
        ]
    }

    /// Run the inject. Returns false (and logs) when skipped or tmux is unavailable.
    @discardableResult
    static func inject(pane: String, text: String) -> Bool {
        guard let cmds = sendKeysCommands(pane: pane, text: text) else {
            NSLog("Vloude: no tmux_pane, skipping inject (speak-only)")
            return false
        }
        for argv in cmds {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["tmux"] + argv
            do { try proc.run(); proc.waitUntilExit() }
            catch { NSLog("Vloude: tmux inject failed: \(error)"); return false }
        }
        return true
    }
}
