import AppKit
@preconcurrency import AVFoundation
import CryptoKit
import Foundation

// The Mac as a GUEST of someone else's shared session (docs/MULTIPLAYER.md, protocol v7 in
// docs/IPHONE.md) — as the iPhone's Guests.swift: join with the invite link, Sir lets him in, the
// session shows in the menu with "Anrufen"; a call runs on the Mac's mic and speaker.

/// One joined (or joining) share, kept in credentials.json (0600) under `guests`.
struct GuestShare: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var relay: String
    var room: String
    var secret: String           // the relay bearer
    var key: String              // the end-to-end key
    var label: String            // the session's name
    var host: String             // who shared it
    var name: String             // how the guest called himself
    var privateKey: String       // P-256 key agreement, raw, base64 — for the sealed move (S1)
    var active = false           // false: still in the invite room, waiting for Sir
    var share = ""               // the host's share id (after the move)
    var role = ""
    var listen = false           // only listening: nothing to say

    var pub: String {
        guard let raw = Data(base64Encoded: privateKey), let k = try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw) else { return "" }
        return RelayLink.base64url(k.publicKey.x963Representation)
    }
    var code: String { Shares.code(pub) }

    /// `https://<relay>/join#<parley://join?u&r&k&e&s&h>` or the bare parley:// link.
    static func parse(_ link: String, name: String) -> GuestShare? {
        var raw = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URL(string: raw), u.scheme == "https", u.path == "/join", let f = u.fragment {
            raw = f.removingPercentEncoding ?? f
        }
        guard let c = URLComponents(string: raw), c.scheme == "parley", c.host == "join" else { return nil }
        func q(_ k: String) -> String { c.queryItems?.first { $0.name == k }?.value ?? "" }
        let relay = RelayLink.normalize(q("u")), room = q("r"), secret = q("k"), key = q("e")
        guard relay.lowercased().hasPrefix("https://"), (16...64).contains(room.count), (16...128).contains(secret.count),
              key.count == 43, RelaySeal(key: key) != nil else { return nil }
        return GuestShare(relay: relay, room: room, secret: secret, key: key,
                          label: String(q("s").prefix(60)), host: String(q("h").prefix(60)),
                          name: Shares.cleanName(name),
                          privateKey: P256.KeyAgreement.PrivateKey().rawRepresentation.base64EncodedString())
    }

    /// The host's `move`: the fresh room, sealed to our key (ECDH + HKDF → AES-GCM, no AAD).
    func open(move pub: String, box: String, share: String) -> (room: String, secret: String, key: String)? {
        guard let raw = Data(base64Encoded: privateKey), let mine = try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw),
              let theirsRaw = RelaySeal.base64url(pub), let theirs = try? P256.KeyAgreement.PublicKey(x963Representation: theirsRaw),
              let shared = try? mine.sharedSecretFromKeyAgreement(with: theirs), let boxed = RelaySeal.base64url(box),
              let sealed = try? AES.GCM.SealedBox(combined: boxed),
              let plain = try? AES.GCM.open(sealed, using: Shares.moveKey(shared, share: share)) else { return nil }
        struct Room: Decodable { let r, k, e: String }
        guard let r = try? JSONDecoder().decode(Room.self, from: plain) else { return nil }
        return (r.r, r.k, r.e)
    }

    static func load() -> [GuestShare] {
        guard let s = Keychain.get(.guests), let list = try? JSONDecoder().decode([GuestShare].self, from: Data(s.utf8)) else { return [] }
        return list
    }

    static func save(_ list: [GuestShare]) {
        let s = (try? JSONEncoder().encode(list)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        Keychain.set(list.isEmpty ? "" : s, for: .guests)
    }
}

/// The share's relay room as the phone side (`role=phone`): sealed frames both ways, `hello`
/// first, a ping every 25 s, redial with backoff. No replay guard: the relay replays `sessions`.
final class GuestLink: @unchecked Sendable {
    var onFrame: (@MainActor ([String: Any]) -> Void)?
    var onAudio: (@MainActor (Data) -> Void)?
    var onOpen: (@MainActor () -> Void)?
    var onGone: (@MainActor () -> Void)?        // 404: the room is no more (invite used / expired)

    private let share: GuestShare
    private let seal: RelaySeal
    private var task: URLSessionWebSocketTask?
    private var stopped = false
    private var backoff: Double = 1
    private var pinger: Timer?
    private let lock = NSLock()

    init?(_ share: GuestShare) {
        guard let seal = RelaySeal(key: share.key) else { return nil }
        self.share = share
        self.seal = seal
    }

    func start() { dial() }

    func stop() {
        lock.withLock { stopped = true }
        task?.cancel(with: .goingAway, reason: nil)
        DispatchQueue.main.async { self.pinger?.invalidate() }
    }

    func send(_ frame: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let wire = seal.text(String(decoding: data, as: UTF8.self), at: Date()) else { return }
        task?.send(.string(wire)) { _ in }
    }

    func sendAudio(_ pcm: Data) {
        guard let sealed = seal.binary(pcm, at: Date()) else { return }
        task?.send(.data(sealed)) { _ in }
    }

    private func dial() {
        guard !lock.withLock({ stopped }), let base = RelayLink.socketBase(share.relay),
              let url = URL(string: "\(base)/v1/room/\(RelayLink.encode(share.room))?role=phone") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(share.secret)", forHTTPHeaderField: "Authorization")
        let t = URLSession.shared.webSocketTask(with: req)
        task = t
        t.resume()
        let hello = ["t": "hello", "device": Host.current().localizedName ?? "Mac"]
        if let data = try? JSONSerialization.data(withJSONObject: hello), let wire = seal.text(String(decoding: data, as: UTF8.self), at: Date()) {
            t.send(.string(wire)) { [weak self] error in
                guard let self, error == nil else { return }
                backoff = 1
                Task { @MainActor in self.onOpen?() }
            }
        }
        DispatchQueue.main.async {
            self.pinger?.invalidate()
            self.pinger = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak t] _ in t?.send(.string("ping")) { _ in } }
        }
        receive(t)
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let s)):
                if s != "pong", let opened = seal.open(text: s),
                   let f = (try? JSONSerialization.jsonObject(with: Data(opened.json.utf8))) as? [String: Any] {
                    Task { @MainActor in self.onFrame?(f) }
                }
                receive(t)
            case .success(.data(let d)):
                if let opened = seal.open(binary: d) { Task { @MainActor in self.onAudio?(opened.data) } }
                receive(t)
            case .failure:
                if (t.response as? HTTPURLResponse)?.statusCode == 404 { Task { @MainActor in self.onGone?() } }
                redial()
            default:
                receive(t)
            }
        }
    }

    private func redial() {
        guard !lock.withLock({ stopped }) else { return }
        let wait = backoff
        backoff = min(30, backoff * 2)
        DispatchQueue.global().asyncAfter(deadline: .now() + wait) { [weak self] in self?.dial() }
    }
}

/// A call on the Mac: the mic (voice processing = echo cancellation) as 16 kHz PCM16 frames of
/// 20 ms up, Parley's 24 kHz voice down into a player.
@MainActor
final class GuestCallAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let down = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private let up = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private(set) var queued = 0                 // buffers scheduled, not yet played

    func start(send: @escaping @Sendable (Data) -> Void) throws {
        let input = engine.inputNode
        try? input.setVoiceProcessingEnabled(true)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: down)
        let format = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: format, to: up) else { throw CocoaError(.featureUnsupported) }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(converter, from: format, to: up, send: send))
        try engine.start()
        player.play()
    }

    /// One frame of Parley's voice: 960 bytes = 24 kHz, 640 = 16 kHz (an older host).
    func play(_ pcm: Data) {
        let rate: Double = pcm.count == 640 ? 16_000 : 24_000
        let n = pcm.count / 2
        guard n > 0, let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)), let ch = buf.floatChannelData else { return }
        buf.frameLength = AVAudioFrameCount(n)
        pcm.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<n { ch[0][i] = Float(Int16(littleEndian: s[i])) / 32768 }
        }
        let played = rate == 24_000 ? buf : resample(buf)
        queued += 1
        player.scheduleBuffer(played, completionHandler: Self.played(self))
    }

    // Built outside the main actor: the audio thread calls them.
    private nonisolated static func tap(_ converter: AVAudioConverter, from format: AVAudioFormat, to up: AVAudioFormat,
                                        send: @escaping @Sendable (Data) -> Void) -> AVAudioNodeTapBlock {
        final class Chunker: @unchecked Sendable { var pending = Data() }
        let chunker = Chunker()
        return { buffer, _ in
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * up.sampleRate / format.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: up, frameCapacity: cap) else { return }
            var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard let p = out.int16ChannelData else { return }
            chunker.pending.append(Data(bytes: p[0], count: Int(out.frameLength) * 2))
            while chunker.pending.count >= 640 {
                send(Data(chunker.pending.prefix(640)))
                chunker.pending.removeFirst(640)
            }
        }
    }

    private nonisolated static func played(_ owner: GuestCallAudio) -> AVAudioNodeCompletionHandler {
        { [weak owner] in Task { @MainActor in owner?.queued -= 1 } }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
    }

    private func resample(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let c = AVAudioConverter(from: b.format, to: down),
              let out = AVAudioPCMBuffer(pcmFormat: down, frameCapacity: b.frameLength * 3 / 2 + 16) else { return b }
        var fed = false
        c.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return b
        }
        return out
    }
}

/// The guest side for the menu: the shares, their session rows, ringing and the one call.
@MainActor
final class GuestHub: ObservableObject {
    static let shared = GuestHub()

    @Published private(set) var shares: [GuestShare] = GuestShare.load()
    @Published private(set) var rows: [String: MenuBoard.Row] = [:]      // share id → its session
    @Published private(set) var ringing: [String: Date] = [:]           // share id → since
    @Published private(set) var inCall: String?                         // share id
    @Published private(set) var notice: String?

    private var links: [String: GuestLink] = [:]
    private var audio: GuestCallAudio?
    private var hostAudio = "idle"
    private var lastCaption = false

    func start() {
        for s in shares where links[s.id] == nil { connect(s) }
    }

    // MARK: - join / leave

    /// The menu's "Beitreten…": the invite link and a name.
    func askToJoin() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Geteilte Session beitreten"
        alert.informativeText = "Füge den Einladungslink ein, den du bekommen hast."
        let link = NSTextField(frame: NSRect(x: 0, y: 30, width: 320, height: 24))
        link.placeholderString = "https://…/join#…"
        if let clip = NSPasteboard.general.string(forType: .string), clip.contains("join") { link.stringValue = clip }
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        name.placeholderString = "Dein Name"
        name.stringValue = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 54))
        box.addSubview(link)
        box.addSubview(name)
        alert.accessoryView = box
        alert.addButton(withTitle: "Beitreten")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let s = GuestShare.parse(link.stringValue, name: name.stringValue) else {
            notice = "Das ist kein gültiger Einladungslink."
            return
        }
        notice = nil
        shares.append(s)
        GuestShare.save(shares)
        Log.write("guest: joining \(s.label)")
        connect(s)
    }

    func leave(_ id: String) {
        links.removeValue(forKey: id)?.stop()
        if inCall == id { endCall() }
        shares.removeAll { $0.id == id }
        rows[id] = nil
        ringing[id] = nil
        GuestShare.save(shares)
    }

    // MARK: - the room

    private func connect(_ s: GuestShare) {
        guard let link = GuestLink(s) else { return }
        let id = s.id
        link.onOpen = { [weak self] in self?.opened(id) }
        link.onFrame = { [weak self] f in self?.frame(id, f) }
        link.onAudio = { [weak self] pcm in if self?.inCall == id { self?.audio?.play(pcm) } }
        link.onGone = { [weak self] in
            guard let self, let s = shares.first(where: { $0.id == id }), !s.active else { return }
            notice = "Einladung für „\(s.label)“ abgelaufen oder schon benutzt."
            leave(id)
        }
        links[id] = link
        link.start()
    }

    private func opened(_ id: String) {
        guard let s = shares.first(where: { $0.id == id }) else { return }
        if !s.active {
            links[id]?.send(["t": "join", "name": s.name, "device": Host.current().localizedName ?? "Mac", "pub": s.pub, "who": Self.who])
        } else if inCall == id {
            links[id]?.send(["t": "call", "state": "start", "down": 24_000])   // a redial mid-call keeps the call
        }
    }

    private func frame(_ id: String, _ f: [String: Any]) {
        guard let t = f["t"] as? String else { return }
        switch t {
        case "move":
            guard let i = shares.firstIndex(where: { $0.id == id }), !shares[i].active,
                  let pub = f["pub"] as? String, let box = f["box"] as? String, let share = f["share"] as? String,
                  let room = shares[i].open(move: pub, box: box, share: share) else { return }
            shares[i].room = room.room
            shares[i].secret = room.secret
            shares[i].key = room.key
            shares[i].share = share
            shares[i].role = f["role"] as? String ?? ""
            shares[i].listen = f["listen"] as? Bool ?? false
            shares[i].active = true
            GuestShare.save(shares)
            Log.write("guest: \(shares[i].label) — let in")
            links.removeValue(forKey: id)?.stop()
            connect(shares[i])
        case "share-end":
            let s = shares.first { $0.id == id }
            notice = s.map { "\($0.host.isEmpty ? "Der Gastgeber" : $0.host) hat die Freigabe für „\($0.label)“ beendet." }
            leave(id)
        case "sessions":
            guard let list = f["sessions"], let data = try? JSONSerialization.data(withJSONObject: list),
                  let parsed = try? JSONDecoder().decode([MenuBoard.Row].self, from: data) else { return }
            rows[id] = parsed.first
        case "ring":
            guard inCall == nil else { return }
            ringing[id] = Date()
            Notifier.notify(title: "Parley · \(f["label"] as? String ?? "Anruf")", body: "Im Parley-Menü annehmen")
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(40))
                if let at = self?.ringing[id], Date().timeIntervalSince(at) >= 39 { self?.ringing[id] = nil }
            }
        case "audio":
            let state = f["state"] as? String ?? "idle"
            let was = hostAudio
            hostAudio = state
            if inCall == id, state == "idle", was != "idle" { hangUpWhenPlayed() }
        case "caption":
            lastCaption = f["last"] as? Bool ?? false
        case "notice":
            notice = f["text"] as? String
        default:
            break
        }
    }

    // MARK: - the call

    /// "Anrufen" (or "Annehmen" while it rings).
    func call(_ id: String) {
        guard inCall == nil, let link = links[id], shares.first(where: { $0.id == id })?.active == true else { return }
        let audio = GuestCallAudio()
        do {
            try audio.start { [weak link] pcm in link?.sendAudio(pcm) }
        } catch {
            notice = "Mikrofon nicht verfügbar: \(error.localizedDescription)"
            return
        }
        self.audio = audio
        inCall = id
        ringing[id] = nil
        hostAudio = "idle"
        link.send(["t": "call", "state": "start", "down": 24_000])
        Log.write("guest: call started")
    }

    func decline(_ id: String) {
        ringing[id] = nil
        links[id]?.send(["t": "call", "state": "end"])
    }

    func endCall() {
        guard let id = inCall else { return }
        links[id]?.send(["t": "call", "state": "end"])
        audio?.stop()
        audio = nil
        inCall = nil
        Log.write("guest: call ended")
    }

    // Parley is done (audio idle after speaking): hang up once the last frame has played.
    private func hangUpWhenPlayed() {
        Task { [weak self] in
            for _ in 0..<100 {
                guard let self, inCall != nil, hostAudio == "idle" else { return }
                if (audio?.queued ?? 0) == 0 { endCall(); return }
                try? await Task.sleep(for: .milliseconds(50))
            }
            self?.endCall()
        }
    }

    // The same "who" on every join (S3: Sir's phone offers his roles of before).
    private static var who: String {
        if let w = UserDefaults.standard.string(forKey: "guestWho") { return w }
        let w = UUID().uuidString
        UserDefaults.standard.set(w, forKey: "guestWho")
        return w
    }
}
