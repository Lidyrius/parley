import SwiftUI

/// What the call screen shows for the call's state (design C colours and words).
struct CallLook: Equatable {
    enum Mood: Equatable { case ringing, connecting, speaking, listening, idle }

    let mood: Mood

    /// `awaitingHost`: just connected, the host hasn't spoken yet — still "connecting" (no flash of
    /// the idle green before Parley's first word).
    init(phase: CallPhase, host: HostAudio, awaitingHost: Bool = false) {
        switch phase {
        case .ringing: mood = .ringing
        case .none, .dialing, .connecting: mood = .connecting
        case .active where host == .idle && awaitingHost: mood = .connecting
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
        case .ringing, .speaking, .connecting: .speaking   // answering keeps the ring's colour (no yellow flash)
        case .listening: .listening
        case .idle: .idle
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

    @MainActor var color: Color { state.color }
    @MainActor var ink: Color { state.ink }
}

/// The call screen: who Parley is voicing, what it is doing, a live waveform, and the controls.
struct CallView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var zoomed: ZoomedImage?
    /// A slide swiped to by hand (the pager follows the voice again 10 s later).
    @State private var picked: String?
    @State private var pickedAt = Date.distantPast
    @State private var drag: CGFloat = 0
    @Namespace private var controlSpace

    var body: some View {
        let call = model.call
        let look = CallLook(phase: call.phase, host: call.hostAudio, awaitingHost: call.awaitingHost)
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
                // A slide (docs/CALL-SLIDES.md) takes the ring's place while Parley talks about it;
                // the session's name stays on top, small.
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    let due = call.slide(at: context.date)
                    let name = call.label ?? voiced?.name ?? "Parley"
                    VStack(spacing: 14) {
                        if let due {
                            compactIdentity(call, look: look, name: name)
                                .transition(.opacity)
                            slideDeck(call, due: due, at: context.date)
                                .transition(.opacity)
                        } else {
                            identity(call, look: look, name: name)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.4), value: due == nil)
                }
                Spacer(minLength: 20)
                // While it rings the motion is around the ring; answered, the bars grow out of the line.
                Waveform(mood: look.mood, color: look.color, paused: reduceMotion) { call.level(at: $0) }
                    .frame(height: 96)
                    .padding(.horizontal, 8)
                    .scaleEffect(x: 1, y: call.isRinging ? 0.05 : 1)
                    .opacity(call.isRinging ? 0 : 1)
                    .animation(.spring(response: 0.7, dampingFraction: 0.85).delay(0.15), value: call.isRinging)
                    .accessibilityHidden(true)
                Group {
                    // The line stays readable while Parley listens (an app opened late still shows it).
                    if look.mood == .speaking || look.mood == .listening, let c = call.caption {
                        LiveCaption(call: call, caption: c)
                    } else {
                        caption(call, look: look, line: voiced?.stats?.lastLine)
                    }
                }
                .frame(minHeight: 72, alignment: .top)
                .padding(.top, 18)
                Spacer(minLength: 20)
                if call.isRinging {
                    // Can't talk now: put it off a little, or call back later yourself.
                    HStack(spacing: 8) {
                        laterButton("In 1 Min.", after: 60, call)
                        laterButton("In 5 Min.", after: 300, call)
                        laterButton("Ich rufe zurück", after: nil, call)
                    }
                    .padding(.bottom, 22)
                    .transition(.opacity)
                }
                controls(call)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: call.muted)
        .sensoryFeedback(.impact(weight: .light), trigger: call.speaker)
        .sensoryFeedback(.success, trigger: call.wakeSent) { _, new in new }
        .fullScreenCover(item: $zoomed) { z in ImageViewer(image: z.image) }
    }

    private func topBar(_ call: CallController) -> some View {
        HStack {
            Button { if call.isTest { call.hangUp() } else { call.showsScreen = false } } label: {
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
            // Ringing: the picked motion around the ring; answered, it draws back in (the morph).
            RingingStage(style: Appearance.shared.ringStyle, color: look.color, active: call.isRinging,
                         ring: 140, paused: reduceMotion) {
                ParticleOrb(style: Appearance.shared.orbStyle, color: look.color, size: 210, paused: reduceMotion) {
                    Double(call.level(at: $0))
                }
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

    /// The line's slides as a deck: the current card in the middle, its neighbours just off to the
    /// sides (faded, a little smaller). A swipe moves the deck with the finger; when the voice moves
    /// on, the next card slides in from the right. Nothing clips the cards, so their shadows stay.
    /// Follows the voice unless a card was swiped to in the last 10 s.
    private func slideDeck(_ call: CallController, due: Slide, at date: Date) -> some View {
        let order = call.slides.sorted { $0.at < $1.at }
        let shown = Self.shownSlide(order, due: due, picked: picked, pickedAt: pickedAt, now: date)
        let current = order.firstIndex { $0.id == shown } ?? 0
        return GeometryReader { geo in
            let page = geo.size.width + 32
            ZStack(alignment: .top) {
                ForEach(Array(order.enumerated()), id: \.element.id) { k, s in
                    let d = CGFloat(k - current) + drag / page   // distance from the middle, in cards
                    if abs(d) < 1.5 {
                        SlideCard(slide: s, image: model.images[s.id], index: k, count: order.count, active: k == current) {
                            zoomed = ZoomedImage(id: s.id, image: $0)
                        }
                        .scaleEffect(1 - min(abs(d), 1) * 0.06)
                        .opacity(1 - min(abs(d), 1))
                        .offset(x: d * page)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 10)
                .onChanged { v in
                    let t = v.translation.width
                    let pastEnd = (current == 0 && t > 0) || (current == order.count - 1 && t < 0)
                    drag = pastEnd ? t * 0.3 : t
                }
                .onEnded { v in
                    let fling = v.predictedEndTranslation.width
                    let next = min(max(current + (fling < -page / 3 ? 1 : fling > page / 3 ? -1 : 0), 0), order.count - 1)
                    withAnimation(Self.deck) {
                        drag = 0
                        let id = order[next].id
                        if id == due.id { picked = nil; pickedAt = .distantPast } else { picked = id; pickedAt = .now }
                    }
                })
        }
        .frame(height: 330)
        .animation(Self.deck, value: shown)
    }

    private static let deck = Animation.spring(response: 0.6, dampingFraction: 0.88)

    /// Which slide the pager shows: one swiped to in the last 10 s, else the one due now.
    nonisolated static func shownSlide(_ order: [Slide], due: Slide, picked: String?, pickedAt: Date, now: Date) -> String {
        guard let picked, now.timeIntervalSince(pickedAt) < 10, order.contains(where: { $0.id == picked }) else { return due.id }
        return picked
    }

    /// The session's name and state, small — above a slide.
    private func compactIdentity(_ call: CallController, look: CallLook, name: String) -> some View {
        HStack(spacing: 12) {
            ParticleOrb(style: Appearance.shared.orbStyle, color: look.color, size: 40, paused: reduceMotion) {
                Double(call.level(at: $0))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.title3.bold()).lineLimit(1)
                statusLine(call, look: look).font(.subheadline).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
    }

    /// "spricht · 2:47" while connected; the timer counts from the moment the call connected.
    private func statusLine(_ call: CallController, look: CallLook) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.status(look, phase: call.phase, muted: call.muted, at: context.date))
        }
    }

    /// Muted: "· stumm" in red — up here, so the subtitles below stay readable.
    private static func status(_ look: CallLook, phase: CallPhase, muted: Bool, at date: Date) -> AttributedString {
        var text = AttributedString.run(look.status, look.ink)
        if case .active(let since) = phase {
            text += .run(" · " + Fmt.clock(date.timeIntervalSince(since) * 1000), .secondary)
            if muted { text += .run(" · stumm", Theme.danger) }
        }
        return text
    }

    private func caption(_ call: CallController, look: CallLook, line: String?) -> some View {
        let text: Text = switch look.mood {
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
            Text("")
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
    private func laterButton(_ title: String, after: Int?, _ call: CallController) -> some View {
        Button { call.later(after) } label: {
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Capsule().fill(Theme.card))
                .overlay(Capsule().strokeBorder(Theme.stroke))
        }
        .tint(.primary)
    }

    /// Answering morphs the buttons, as on the system call screen: "Annehmen" becomes "Auflegen",
    /// "Ablehnen" becomes "Stumm", and "Lautsprecher" grows in between.
    private func controls(_ call: CallController) -> some View {
        Group {
            if call.isRinging {
                HStack(spacing: 72) {
                    CallControl(title: "Ablehnen", symbol: "phone.down.fill", style: .end) { call.hangUp() }
                        .matchedGeometryEffect(id: "left", in: controlSpace)
                    CallControl(title: "Annehmen", symbol: "phone.fill", style: .accept) { call.answer() }
                        .matchedGeometryEffect(id: "right", in: controlSpace)
                }
            } else {
                HStack(spacing: 36) {
                    CallControl(title: "Stumm", symbol: call.muted ? "mic.slash.fill" : "mic.fill",
                                style: .toggle(call.muted)) { call.setMuted(!call.muted) }
                        .disabled(!call.phase.isActive)
                        .matchedGeometryEffect(id: "left", in: controlSpace)
                    CallControl(title: "Lautsprecher", symbol: "speaker.wave.2.fill",
                                style: .toggle(call.speaker)) { call.setSpeaker(!call.speaker) }
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                    CallControl(title: "Auflegen", symbol: "phone.down.fill", style: .end) { call.hangUp() }
                        .matchedGeometryEffect(id: "right", in: controlSpace)
                }
            }
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.82), value: call.isRinging)
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
        case .end: Theme.danger
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
    @State private var smoother = LevelSmoother()

    var body: some View {
        // Every display frame (60/120 Hz), the level eased between the 20 ms meter steps.
        TimelineView(.animation(paused: paused)) { context in
            let t = paused ? 0 : context.date.timeIntervalSinceReferenceDate
            let lvl = smoother.next(Double(level(context.date)), at: context.date.timeIntervalSinceReferenceDate)
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
    // (LevelSmoother: below.)
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

/// The meter moves in 20 ms steps; this eases it per display frame — quick to rise, gentle
/// to fall — so the bars glide instead of jumping.
final class LevelSmoother {
    private(set) var value: Double = 0
    private var last: Double?

    func next(_ target: Double, at t: Double, rise: Double = 0.04, fall: Double = 0.11) -> Double {
        let dt = last.map { min(0.1, max(0, t - $0)) } ?? 0
        last = t
        let tau = max(0.001, target > value ? rise : fall)
        value += (target - value) * (1 - exp(-dt / tau))
        return value
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

/// Live captions: the whole line in a two-line window that scrolls up smoothly as the voice
/// moves on — the current line on top, what comes next always visible below. Words light up as
/// they are spoken, timed against the frames the phone actually played (CallController.captionTime).
private struct LiveCaption: View {
    let call: CallController
    let caption: Caption
    @State private var frames: [Int: CGRect] = [:]
    @State private var spoken = -1
    @State private var scroll: CGFloat = 0
    @ScaledMetric(relativeTo: .title3) private var lineSpacing: CGFloat = 6

    var body: some View {
        let lineHeight = frames[0]?.height ?? 26
        // The wrapper: a fixed two-line window. Inside it the whole text block moves as one,
        // only when the voice reaches a new line — one smooth animation, no per-frame layout.
        ZStack(alignment: .top) {
            FlowLayout(spacing: 5.5, lineSpacing: lineSpacing) {
                ForEach(caption.words.indices, id: \.self) { i in
                    Text(caption.words[i])
                        .foregroundStyle(i <= spoken ? Color.primary : Color.secondary.opacity(0.55))
                        .background(GeometryReader { g in
                            Color.clear.preference(key: WordFrames.self, value: [i: g.frame(in: .named("caption"))])
                        })
                }
            }
            .font(.title3.weight(.medium))
            .coordinateSpace(.named("caption"))
            .geometryGroup()   // the block moves as one; words never animate their own positions
            .offset(y: -scroll)
            .padding(.top, 4)    // room for accents and descenders: two whole lines, the third still out of sight
        }
        .frame(maxWidth: 360)
        .frame(height: lineHeight * 2 + lineSpacing + 10, alignment: .top)
        .clipped()
        .onPreferenceChange(WordFrames.self) { frames = $0 }
        .task(id: caption) {
            // The voice's clock at ~30 Hz drives which word is spoken; the scroll follows lines.
            while !Task.isCancelled {
                let now = caption.index(at: call.captionTime(at: .now))
                if now != spoken {
                    // Only the words' colours fade; layout stays out of this animation.
                    withAnimation(.easeOut(duration: 0.2)) { spoken = now }
                    follow(lineHeight: lineHeight)
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
        .id(caption)
        .transition(.opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption.words.joined(separator: " "))
    }

    /// The current line on top — but never past the point where the last line is the second.
    private func follow(lineHeight: CGFloat) {
        let lastTop = frames.values.map(\.minY).max() ?? 0
        let target = min(frames[max(spoken, 0)]?.minY ?? 0, max(0, lastTop - lineHeight - lineSpacing))
        guard abs(target - scroll) > 0.5 else { return }
        withAnimation(.smooth(duration: 0.55)) { scroll = target }
    }
}

private struct WordFrames: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Words in centred lines, wrapping at the proposed width (subtitle layout).
struct FlowLayout: Layout {
    var spacing: CGFloat = 7
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if extra > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.items.isEmpty }
    }
}

