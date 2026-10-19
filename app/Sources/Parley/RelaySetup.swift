import Foundation

// "Eigenes Relais · 1 Klick" (setup step 7): Parley puts the relay (relay/, bundled by make-app.sh
// into Contents/Resources/relay) into Sir's own Cloudflare account — `wrangler login` opens the
// browser (he only confirms), `wrangler deploy` prints the worker's address, which is then checked
// ("parley relay ok") and saved as relayUrl. Needs Node.js (npx); without it the setup offers the
// address field instead.
enum RelaySetup {
    static let wrangler = "wrangler@4.149.0"   // as relay/package.json pins it

    /// A login shell, so Homebrew's / nvm's npx is on the PATH a GUI app doesn't have.
    static func shell(_ command: String, in dir: URL? = nil) async -> (status: Int32, output: String) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", command]
            if let dir { p.currentDirectoryURL = dir }
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            p.terminationHandler = { proc in
                let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                cont.resume(returning: (proc.terminationStatus, text))
            }
            do { try p.run() } catch { cont.resume(returning: (-1, error.localizedDescription)) }
        }
    }

    static func hasNode() async -> Bool { await shell("command -v npx").status == 0 }

    /// The relay's source, copied out of the app (a folder wrangler may write into).
    static func workDir() -> URL? {
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("relay"),
              FileManager.default.fileExists(atPath: src.appendingPathComponent("wrangler.jsonc").path) else { return nil }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parley/relay", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: src, to: dir)
        return dir
    }

    /// Signed in to Cloudflare (asks in the browser when not yet).
    static func login(in dir: URL) async -> Bool {
        if await shell("npx --yes \(wrangler) whoami", in: dir).output.contains("You are logged in") { return true }
        _ = await shell("npx --yes \(wrangler) login", in: dir)
        return await shell("npx --yes \(wrangler) whoami", in: dir).output.contains("You are logged in")
    }

    /// Deployed: the worker's https address, nil if it didn't work.
    static func deploy(in dir: URL) async -> String? {
        let out = await shell("npx --yes \(wrangler) deploy", in: dir).output
        return address(in: out)
    }

    static func address(in output: String) -> String? {
        guard let r = output.range(of: #"https://[a-z0-9-]+\.[a-z0-9-]+\.workers\.dev"#, options: .regularExpression) else { return nil }
        return String(output[r])
    }

    /// The relay answers like a Parley relay.
    static func check(_ url: String) async -> Bool {
        guard let u = URL(string: RelayLink.normalize(url)), u.scheme == "https" else { return false }
        var req = URLRequest(url: u)
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return String(decoding: data, as: UTF8.self).contains("parley relay ok")
    }
}
