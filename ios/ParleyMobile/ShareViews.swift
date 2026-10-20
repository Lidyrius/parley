import AVFoundation
import CoreImage.CIFilterBuiltins
import SwiftUI

// Shared sessions (v7, docs/design/screens/ios/60-multiplayer): the owner's invite and yes/no, the
// guest's join and his section on the overview.

/// "Session teilen": a one-time link (QR + share sheet) and who is in already.
struct ShareSessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: Session

    var body: some View {
        let link = model.shareLinks[session.id]
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Wer den Link öffnet, kann dieser einen Session folgen, mitschreiben und Rückfragen zu seinem Bereich bekommen. Sie lassen ihn vorher herein.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    VStack(spacing: 12) {
                        if let link {
                            QRCode(text: link).frame(width: 190, height: 190)
                            Text(link.prefix(34) + "…").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            ProgressView().frame(width: 190, height: 190)
                        }
                        HStack(spacing: 14) {
                            Label("Ende-zu-Ende", systemImage: "lock.fill")
                            Label("einmal nutzbar", systemImage: "1.circle")
                            Label("24 h", systemImage: "timer")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(18)
                    .background(CardBackground())
                    if let link, let url = URL(string: link) {
                        ShareLink(item: url, message: Text("Komm in meine Parley-Session „\(session.name)“.")) {
                            Label("Link teilen …", systemImage: "square.and.arrow.up")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.onAccent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(Capsule().fill(Theme.claude))
                        }
                    }
                    if !session.shared.isEmpty {
                        Text("SCHON DABEI").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
                        VStack(spacing: 0) {
                            ForEach(session.shared) { g in
                                HStack(spacing: 12) {
                                    Avatar(name: g.name)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(g.name).font(.body.weight(.semibold))
                                        if !g.role.isEmpty { Text(g.role).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    Button("Entfernen", role: .destructive) { model.removeShare(g.id) }
                                        .font(.subheadline.weight(.semibold))
                                }
                                .padding(.horizontal, 14).padding(.vertical, 11)
                            }
                        }
                        .background(CardBackground())
                    }
                }
                .padding(16)
                .containerRelativeFrame(.horizontal, alignment: .leading)
            }
            .background(Theme.background)
            .navigationTitle("Session teilen")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
        .onAppear { if model.shareLinks[session.id] == nil { model.share(session.id) } }
    }
}

/// "Max möchte beitreten": first the code he sends Sir (typed or pasted), then his role, what he may
/// do, the owner's own role — then yes or no.
struct ApproveJoinView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: JoinRequest
    @State private var entered = ""
    @State private var role = ""
    @State private var listen = false
    @State private var full = false
    @State private var mine = ""
    @AppStorage("myShareRole") private var lastMine = ""
    @FocusState private var typing: Bool

    /// The code matches (or the Mac sent none to check).
    private var verified: Bool { request.code.map { entered == $0 } ?? true }
    private var wrong: Bool { entered.count == 4 && !verified }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if verified { form } else { codeEntry }
                }
                .padding(16)
                .containerRelativeFrame(.horizontal, alignment: .leading)
                .animation(.snappy, value: verified)
            }
            .background(Theme.background)
        }
        .onAppear {
            if mine.isEmpty { mine = lastMine }
            if ProcessInfo.processInfo.arguments.contains("-demoJoinOk") { entered = request.code ?? "" }
            typing = !verified
        }
        .interactiveDismissDisabled()
    }

    private var codeEntry: some View {
        VStack(spacing: 14) {
            Avatar(name: request.name, size: 56)
            Text("\(request.name) möchte beitreten").font(.title2.bold()).multilineTextAlignment(.center)
            Text("Session „\(request.label)“\(request.device.map { $0.isEmpty ? "" : " · " + $0 } ?? "")")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("Geben Sie den Code ein, den \(request.name) Ihnen schickt.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            CodeBoxes(code: entered, tint: wrong ? .red : Theme.claude)
                .background {   // the digits are typed here; the boxes only show them
                    TextField("", text: $entered)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($typing)
                        .opacity(0.02)
                        .onChange(of: entered) { _, v in
                            let digits = String(v.filter(\.isNumber).prefix(4))
                            if digits != v { entered = digits }
                        }
                }
                .onTapGesture { typing = true }
                .padding(.top, 6)
            if wrong {
                Text("Der Code stimmt nicht.").font(.subheadline.weight(.semibold)).foregroundStyle(.red)
            }
            Button {
                if let code = UIPasteboard.general.string.flatMap(PastRoles.code(in:)) { entered = code }
            } label: {
                Label("Aus der Zwischenablage einfügen", systemImage: "doc.on.clipboard")
                    .font(.headline)
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Capsule().fill(Theme.claude))
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            Text("Kein Code bekommen? Fragen Sie kurz nach.").font(.footnote).foregroundStyle(.secondary)
            Button("Ablehnen", role: .destructive) { model.removeShare(request.id); dismiss() }
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var form: some View {
        VStack(spacing: 8) {
            if request.code != nil {
                CodeBoxes(code: entered, tint: .green)
                Label("Code stimmt, es ist \(request.name)", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
            } else {
                Avatar(name: request.name, size: 56)
                Text("\(request.name) möchte beitreten").font(.title2.bold()).multilineTextAlignment(.center)
                Text("Session „\(request.label)“ · über Ihren Link").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 6)
        label("Wofür ist \(request.name) zuständig?")
        TextField("z. B. Marketing und Rückfragen zu Texten", text: $role, axis: .vertical)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(CardBackground(radius: 14))
        let past = PastRoles.roles(for: request)
        if !past.isEmpty {
            Text("Zuletzt bei \(request.name)").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(past, id: \.self) { r in
                        Button { role = r } label: {
                            Text(r).font(.subheadline.weight(.semibold)).lineLimit(1)
                                .foregroundStyle(role == r ? Theme.onAccent : Theme.claude)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Capsule().fill(role == r ? Theme.claude : Theme.claude.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        label("Darf")
        Picker("Darf", selection: $listen) {
            Text("Lesen und schreiben").tag(false)
            Text("Nur zuhören").tag(true)
        }
        .pickerStyle(.segmented)
        Toggle(isOn: Binding(get: { !full }, set: { full = !$0 })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Verlauf ab Beitritt").font(.body.weight(.semibold))
                Text("Ältere Nachrichten bleiben verborgen").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(CardBackground(radius: 14))
        label("Und Ihre Rolle hier?")
        TextField("z. B. Technik und Entscheidungen", text: $mine, axis: .vertical)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(CardBackground(radius: 14))
        HStack(spacing: 10) {
            Button { model.removeShare(request.id); dismiss() } label: {
                Text("Ablehnen").frame(maxWidth: .infinity, minHeight: 48)
                    .background(Capsule().fill(Theme.claude.opacity(0.14)))
            }
            Button {
                lastMine = mine
                model.approve(request, role: role, listen: listen, full: full, mine: mine)
                dismiss()
            } label: {
                Text("\(request.name) zulassen").lineLimit(1).foregroundStyle(Theme.onAccent).frame(maxWidth: .infinity, minHeight: 48)
                    .background(Capsule().fill(Theme.claude))
            }
        }
        .font(.headline)
        .buttonStyle(.plain)
        .padding(.top, 8)
        Text("Freigaben für Befehle und Dateien kommen immer zu Ihnen.")
            .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
    }
}

/// Four digits, each in a box of its own (an empty box for each one still missing).
struct CodeBoxes: View {
    let code: String
    var tint: Color = Theme.claude

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<4, id: \.self) { i in
                let digit = i < code.count ? String(code[code.index(code.startIndex, offsetBy: i)]) : ""
                Text(digit)
                    .font(.system(size: 38, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint == Theme.claude ? Color.primary : tint)
                    .frame(width: 60, height: 74)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(digit.isEmpty && i != code.count ? Theme.stroke : tint, lineWidth: 1.5))
            }
        }
        .accessibilityElement()
        .accessibilityLabel(code.isEmpty ? "Code" : "Code \(code.map(String.init).joined(separator: " "))")
    }
}

/// A share link opened on this phone: say who you are, then send the code back to whoever shared it
/// and wait for his yes (the screen goes once let in).
struct JoinView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let link: JoinLink
    @AppStorage("guestName") private var name = ""
    @State private var joined: String?
    @State private var copied = false

    private var host: String { link.host.isEmpty ? "den Gastgeber" : link.host }

    var body: some View {
        NavigationStack {
            Group {
                if let id = joined, let g = model.guests.first(where: { $0.id == id }) {
                    codeBack(g)
                } else {
                    ask
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(joined == nil ? "Abbrechen" : "Schließen") { dismiss() }
                }
            }
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-demoGuestCode"), joined == nil { joined = model.join(link, as: "Marco") }
        }
        .onChange(of: model.guests) { _, guests in
            // Let in (or the share went away): this screen has done its job.
            if let id = joined, guests.first(where: { $0.id == id })?.active ?? true { dismiss() }
        }
    }

    private var ask: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.wave.2.fill").font(.system(size: 44)).foregroundStyle(Theme.claude)
            Text("\(link.host.isEmpty ? "Jemand" : link.host) lädt Sie ein").font(.title2.bold())
            Text("zur Session „\(link.label)“. Sie folgen ihr, schreiben mit und bekommen Rückfragen zu Ihrem Bereich.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            TextField("Ihr Name", text: $name)
                .textContentType(.givenName)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(CardBackground(radius: 14))
            Button {
                joined = model.join(link, as: name)
            } label: {
                Text("Beitreten").font(.headline).foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 50).background(Capsule().fill(Theme.claude))
            }
            .buttonStyle(.plain)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            Text("Ende-zu-Ende verschlüsselt. \(link.host.isEmpty ? "Der Gastgeber" : link.host) lässt Sie herein und kann Sie jederzeit entfernen.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    /// "Fast drin": the four digits, to send back by WhatsApp & co.
    @ViewBuilder private func codeBack(_ g: GuestShare) -> some View {
        VStack(spacing: 14) {
            Avatar(name: link.host.isEmpty ? "?" : link.host, size: 64)
            Text("Fast drin, \(g.name)").font(.title2.bold())
            if model.guestRelays[g.id]?.failure == .unknownRoom {
                Label("Einladung abgelaufen oder schon benutzt. Bitten Sie um einen neuen Link.", systemImage: "link.badge.plus")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                Text("Schicken Sie diesen Code an \(host). Damit weiß \(link.host.isEmpty ? "er" : link.host), dass wirklich Sie es sind.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                CodeBoxes(code: g.code).padding(.top, 6)
                Text("Session „\(g.label)“ · gilt nur für diese Anfrage").font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 24)
                ShareLink(item: "Mein Parley-Code für „\(g.label)“: \(g.code)") {
                    Label("Code an \(link.host.isEmpty ? "Gastgeber" : link.host) schicken", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Capsule().fill(Theme.claude))
                }
                Button(copied ? "Kopiert" : "Code kopieren") {
                    UIPasteboard.general.string = g.code
                    copied = true
                }
                .font(.headline)
                .foregroundStyle(Theme.claude)
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Sobald \(link.host.isEmpty ? "der Gastgeber" : link.host) den Code eingibt, sind Sie drin.")
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// On the overview: the sessions others share with this phone, or the wait for their yes.
/// Shares not (yet) among the sessions: waiting to be let in, or let in and still connecting —
/// once its session is here, it sits in the grid like any other.
struct GuestSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let pending = model.guests.filter { !$0.active || (model.guestRelays[$0.id]?.snapshot?.sessions.isEmpty ?? true) }
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Geteilt mit Ihnen").font(.title2.bold())
                ForEach(pending) { g in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(g.host.isEmpty ? g.label : "\(g.host) · \(g.label)").font(.subheadline.weight(.semibold))
                                .foregroundStyle(SessionState.idle.ink)
                            Spacer()
                            Button(g.active ? "Verlassen" : "Abbrechen", role: .destructive) { model.leave(g.id) }
                                .font(.subheadline)
                        }
                        if !g.active, model.guestRelays[g.id]?.failure == .unknownRoom {
                            // B2: the invite's room is gone — expired, already used, or ended.
                            Label("Einladung abgelaufen oder schon benutzt. Bitten Sie um einen neuen Link.", systemImage: "link.badge.plus")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else if !g.active {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Warte, bis \(g.host.isEmpty ? "der Gastgeber" : g.host) Sie hereinlässt …")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Label("Prüfcode \(g.code)", systemImage: "checkmark.shield")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(SessionState.idle.ink)
                        } else {
                            Text("Verbinde …").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .background(CardBackground())
                }
            }
        }
    }
}

/// A round initial in a colour of its own.
struct Avatar: View {
    let name: String
    var size: CGFloat = 30

    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(SessionState.idle.onColor)
            .frame(width: size, height: size)
            .background(Circle().fill(SessionState.idle.color))
    }
}

/// A QR code, crisp at any size.
struct QRCode: View {
    let text: String

    var body: some View {
        if let image = Self.image(text) {
            Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                .padding(10).background(RoundedRectangle(cornerRadius: 14).fill(.white))
        }
    }

    static func image(_ text: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage, let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// R3: a question for this phone as a guest — read aloud, answered by a predicted answer, typing
/// or the keyboard's dictation; or given to the owner. Unanswered, it goes to him by itself.
struct GuestAskView: View {
    @Environment(AppModel.self) private var model
    let ask: GuestAsk
    @State private var text = ""
    @State private var voice = AVSpeechSynthesizer()
    @State private var opened = Date()
    @FocusState private var typing: Bool

    var body: some View {
        let share = model.guestShare(of: ask.session)
        let host = share?.host.isEmpty == false ? share!.host : "den Gastgeber"
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("RÜCKFRAGE · \(ask.label.uppercased())").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        if let role = share?.role, !role.isEmpty {
                            Text("für Sie · \(role)").font(.subheadline).foregroundStyle(SessionState.idle.ink)
                        }
                    }
                    Text(ask.text).font(.title3.weight(.semibold)).textSelection(.enabled)
                    if let seconds = ask.seconds {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let left = max(0, seconds - Int(ctx.date.timeIntervalSince(opened)))
                            Text(left > 0 ? "Geht in \(left) s an \(host), wenn Sie nicht antworten." : "Geht jetzt an \(host).")
                                .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    if let replies = ask.replies, !replies.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(replies, id: \.self) { r in
                                Button { model.answer(ask, text: r) } label: {
                                    Text(r).font(.body.weight(.semibold)).foregroundStyle(Theme.claude)
                                        .padding(.horizontal, 14).padding(.vertical, 10)
                                        .background(Capsule().fill(Theme.claude.opacity(0.12)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    TextField("Antwort – tippen oder per Diktat (Mikrofon auf der Tastatur)", text: $text, axis: .vertical)
                        .lineLimit(2...8)
                        .focused($typing)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(CardBackground(radius: 14))
                    Button { model.answer(ask, text: text) } label: {
                        Text("Antworten").font(.headline).foregroundStyle(Theme.onAccent)
                            .frame(maxWidth: .infinity, minHeight: 50).background(Capsule().fill(Theme.claude))
                    }
                    .buttonStyle(.plain)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("An \(host) abgeben") { model.answer(ask, text: "", pass: true) }
                        .frame(maxWidth: .infinity)
                }
                .padding(20)
            }
            .background(Theme.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { read() } label: { Image(systemName: "speaker.wave.2") }.accessibilityLabel("Vorlesen")
                }
            }
        }
        .interactiveDismissDisabled()
        .onAppear { read() }
        .onDisappear { voice.stopSpeaking(at: .immediate) }
    }

    private func read() {
        voice.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: ask.text)
        u.voice = AVSpeechSynthesisVoice(language: "de-DE")
        voice.speak(u)
    }
}
