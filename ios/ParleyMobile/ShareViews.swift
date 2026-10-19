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

/// "Max möchte beitreten": his role, what he may do, the owner's own role — then yes or no.
struct ApproveJoinView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: JoinRequest
    @State private var role = ""
    @State private var listen = false
    @State private var full = false
    @State private var mine = ""
    @AppStorage("myShareRole") private var lastMine = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 8) {
                        Avatar(name: request.name, size: 56)
                        Text("\(request.name) möchte beitreten").font(.title2.bold()).multilineTextAlignment(.center)
                        Text("Session „\(request.label)“ · über Ihren Link").font(.subheadline).foregroundStyle(.secondary)
                        if let code = request.code {
                            Label("\(request.device.map { $0.isEmpty ? "" : $0 + " · " } ?? "")Prüfcode \(code)", systemImage: "checkmark.shield")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(SessionState.idle.ink)
                            Text("Derselbe Code steht auf dem Handy des Gastes.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 6)
                    label("Wofür ist \(request.name) zuständig?")
                    TextField("z. B. Marketing und Rückfragen zu Texten", text: $role, axis: .vertical)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(CardBackground(radius: 14))
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
                            Text("Zulassen").foregroundStyle(Theme.onAccent).frame(maxWidth: .infinity, minHeight: 48)
                                .background(Capsule().fill(Theme.claude))
                        }
                    }
                    .font(.headline)
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                    Text("Freigaben für Befehle und Dateien kommen immer zu Ihnen.")
                        .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
                .padding(16)
                .containerRelativeFrame(.horizontal, alignment: .leading)
            }
            .background(Theme.background)
        }
        .onAppear { if mine.isEmpty { mine = lastMine } }
        .interactiveDismissDisabled()
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
    }
}

/// A share link opened on this phone: say who you are, then wait for the owner's yes.
struct JoinView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let link: JoinLink
    @AppStorage("guestName") private var name = ""

    var body: some View {
        NavigationStack {
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
                    model.join(link, as: name)
                    dismiss()
                } label: {
                    Text("Beitreten").font(.headline).foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 50).background(Capsule().fill(Theme.claude))
                }
                .buttonStyle(.plain)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                Text("Ende-zu-Ende verschlüsselt. \(link.host.isEmpty ? "Der Gastgeber" : link.host) lässt Sie herein und kann Sie jederzeit entfernen.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
            }
            .padding(24)
            .background(Theme.background)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
    }
}

/// On the overview: the sessions others share with this phone, or the wait for their yes.
struct GuestSection: View {
    @Environment(AppModel.self) private var model
    let open: (String) -> Void

    var body: some View {
        if !model.guests.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Geteilt mit Ihnen").font(.title2.bold())
                ForEach(model.guests) { g in
                    let sessions = model.guestRelays[g.id]?.snapshot?.sessions ?? []
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
                        } else if let s = sessions.first {
                            Button { open(s.id) } label: {
                                HStack(spacing: 12) {
                                    RingView(session: s, skew: model.guestRelays[g.id]?.skew ?? 0, size: 26)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(s.name).font(.headline)
                                        Text(g.role.isEmpty ? Fmt.stateLabel(s) : "Ihre Rolle: \(g.role)")
                                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
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
            .foregroundStyle(.white)
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
