import SwiftUI

/// What the call screen shows for the call's state (design C colours and words).
struct CallLook: Equatable {
    enum Mood: Equatable { case ringing, connecting, speaking, listening, idle }

    let mood: Mood

    init(phase: CallPhase, host: HostAudio) {
        switch phase {
        case .ringing: mood = .ringing
        case .none, .dialing, .connecting: mood = .connecting
        case .active:
            switch host {
            case .speaking: mood = .speaking
            case .listening: mood = .listening
            case .idle: mood = .idle
            }
        }
    }

    /// The tile state whose ring and colours this mood borrows.
    var state: SessionState {
        switch mood {
        case .ringing, .speaking: .speaking
        case .listening: .listening
        case .idle: .idle
        case .connecting: .queued
        }
    }

    var status: String {
        switch mood {
        case .ringing: "Eingehender Anruf"
        case .connecting: "Verbinde…"
        case .speaking: "spricht"
        case .listening: "hört zu"
        case .idle: "bereit"
        }
    }

    var color: Color { state.color }
    var ink: Color { state.ink }
}

/// The call screen: who Parley is voicing, what it is doing, a live waveform, and the controls.
struct CallView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let call = model.call
        let look = CallLook(phase: call.phase, host: call.hostAudio)
        let voiced = model.relay.snapshot?.sessions.first { $0.voice }
        ZStack {
            Theme.background.ignoresSafeArea()
            RadialGradient(colors: [look.color.opacity(0.22), look.color.opacity(0)],
                           center: .top, startRadius: 0, endRadius: 560)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: look)

            VStack(spacing: 0) {
                topBar(call)
                Spacer(minLength: 12)
                identity(call, look: look, name: call.label ?? voiced?.name ?? "Parley")
                Spacer(minLength: 20)
                Waveform(mood: look.mood, color: look.color, paused: reduceMotion) { call.level(at: $0) }
                    .frame(height: 96)
                    .padding(.horizontal, 8)
                    .accessibilityHidden(true)
                caption(call, look: look, line: voiced?.stats?.lastLine)
                    .frame(minHeight: 72, alignment: .top)
                    .padding(.top, 18)
                Spacer(minLength: 20)
                controls(call)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: call.muted)
        .sensoryFeedback(.impact(weight: .light), trigger: call.speaker)
        .sensoryFeedback(.success, trigger: call.wakeSent) { _, new in new }
    }

    private func topBar(_ call: CallController) -> some View {
        HStack {
            Button { call.showsScreen = false } label: {
                Image(systemName: "chevron.down")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.card))
                    .overlay(Circle().strokeBorder(Theme.stroke))
            }
            .tint(.primary)
            .accessibilityLabel("Zur Übersicht")
            Spacer()
            Label("Parley", systemImage: "waveform")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.top, 8)
    }

    private func identity(_ call: CallController, look: CallLook, name: String) -> some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(look.color.opacity(0.10)).frame(width: 168, height: 168)
                RingView(session: Session(id: "call", state: look.state), skew: 0, size: 128)
            }
            .animation(.easeInOut(duration: 0.4), value: look)
            .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(name)
                    .font(.largeTitle.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                statusLine(call, look: look)
                    .font(.headline)
                    .monospacedDigit()
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
        }
    }

    /// "spricht · 2:47" while connected; the timer counts from the moment the call connected.
    private func statusLine(_ call: CallController, look: CallLook) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.status(look, phase: call.phase, at: context.date))
        }
    }

    private static func status(_ look: CallLook, phase: CallPhase, at date: Date) -> AttributedString {
        var text = AttributedString.run(look.status, look.ink)
        if case .active(let since) = phase {
            text += .run(" · " + Fmt.clock(date.timeIntervalSince(since) * 1000), .secondary)
        }
        return text
    }

    private func caption(_ call: CallController, look: CallLook, line: String?) -> some View {
        let text: Text = switch look.mood {
        case _ where call.muted && call.phase.isActive:
            Text("Stummgeschaltet – Parley hört dich nicht.")
        case .ringing:
            Text("Ein Update möchte mit dir sprechen.")
        case .connecting:
            Text("Verbinde mit Parley auf dem Mac…")
        case .idle where call.wakeSent:
            Text("„Hey Parley“ erkannt – Parley meldet sich.")
        case .idle:
            call.wakeWordAvailable
                ? Text("Sag „Hey Parley“, wenn du etwas brauchst.")
                : Text("Parley meldet sich, sobald es Neues gibt.")
        case .listening:
            Text("Parley hört zu – sprich einfach.")
        case .speaking:
            line.map { Text("„\($0)“").italic() } ?? Text("Parley spricht.")
        }
        return text
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .frame(maxWidth: 360)
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: look)
    }

    @ViewBuilder
    private func controls(_ call: CallController) -> some View {
        if call.phase == .ringing {
            HStack(spacing: 72) {
                CallControl(title: "Ablehnen", symbol: "phone.down.fill", style: .end) { call.hangUp() }
                CallControl(title: "Annehmen", symbol: "phone.fill", style: .accept) { call.answer() }
            }
        } else {
            HStack(spacing: 36) {
                CallControl(title: "Stumm", symbol: call.muted ? "mic.slash.fill" : "mic.fill",
                            style: .toggle(call.muted)) { call.setMuted(!call.muted) }
                    .disabled(!call.phase.isActive)
                CallControl(title: "Lautsprecher", symbol: "speaker.wave.2.fill",
                            style: .toggle(call.speaker)) { call.setSpeaker(!call.speaker) }
                CallControl(title: "Auflegen", symbol: "phone.down.fill", style: .end) { call.hangUp() }
            }
        }
    }
}

/// A round call button with its label below (the system call screen's grammar).
private struct CallControl: View {
    enum Style: Equatable { case toggle(Bool), end, accept }

    let title: String
    let symbol: String
    let style: Style
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 72

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(foreground)
                    .frame(width: size, height: size)
                    .background(Circle().fill(fill))
                    .overlay(Circle().strokeBorder(style == .toggle(false) ? Theme.stroke : .clear))
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var isOn: Bool { style == .toggle(true) }

    private var fill: Color {
        switch style {
        case .toggle(true): .primary
        case .toggle(false): Theme.card
        case .end: Color(hex: 0xE5484D)
        case .accept: SessionState.idle.color
        }
    }

    private var foreground: Color {
        switch style {
        case .toggle(true): Theme.background
        case .toggle(false): .primary
        case .end, .accept: .white
        }
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// Rounded bars around the centre: the host's voice while it speaks, your mic otherwise, a
/// travelling pulse while connecting and a double beat while ringing.
struct Waveform: View {
    let mood: CallLook.Mood
    let color: Color
    var paused = false
    let level: (Date) -> Float
    private let bars = 41

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { context in
            let t = paused ? 0 : context.date.timeIntervalSinceReferenceDate
            let lvl = Double(level(context.date))
            Canvas { ctx, size in
                let gap: CGFloat = 4
                let w = max(2, (size.width - gap * CGFloat(bars - 1)) / CGFloat(bars))
                for i in 0..<bars {
                    let amp = Self.amplitude(mood, bar: i, of: bars, t: t, level: lvl)
                    let h = w + (size.height - w) * amp
                    let rect = CGRect(x: CGFloat(i) * (w + gap), y: (size.height - h) / 2, width: w, height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: w / 2),
                             with: .color(color.opacity(0.35 + 0.65 * min(1, amp * 1.8))))
                }
            }
        }
    }

    /// 0…1 height of bar `i` at time `t`.
    nonisolated static func amplitude(_ mood: CallLook.Mood, bar i: Int, of n: Int, t: Double, level: Double) -> Double {
        let p = (Double(i) + 0.5) / Double(n)
        let envelope = pow(sin(.pi * p), 1.3)
        switch mood {
        case .speaking, .listening:
            let wobble = 0.55 + 0.45 * sin(t * 5.1 + Double(i) * 0.62) * cos(t * 3.3 - Double(i) * 0.37)
            return min(1, max(0.04, level * envelope * wobble * 1.15))
        case .idle:
            let ripple = 0.05 + 0.035 * sin(t * 1.7 + Double(i) * 0.45)
            return min(1, max(ripple * envelope + 0.02, level * envelope * 0.7))
        case .connecting:
            let centre = (t * 0.55).truncatingRemainder(dividingBy: 1) * 1.4 - 0.2
            return 0.04 + 0.42 * exp(-pow((p - centre) / 0.09, 2))
        case .ringing:
            let beat = t.truncatingRemainder(dividingBy: 1.6)
            let pulse = exp(-pow((beat - 0.15) / 0.07, 2)) + 0.8 * exp(-pow((beat - 0.42) / 0.07, 2))
            return 0.06 + 0.5 * envelope * pulse
        }
    }
}

#Preview("Spricht") {
    let model = AppModel(arguments: ["-demo", "-demoCall", "speaking"])
    return CallView().environment(model)
}

#Preview("Bereit") {
    let model = AppModel(arguments: ["-demo", "-demoCall", "idle"])
    return CallView().environment(model)
}
