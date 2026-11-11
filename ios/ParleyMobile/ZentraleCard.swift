import SwiftUI

// Überwachungsmodus: the Zentrale is the one session that talks to Sir, so its card is the
// overview's centre — twice a row's height: who it is and what it does, its last line, how long
// it has been running and how many sessions report to it, and a row of three buttons across the
// card's width.

/// What the Zentrale's card offers. Always three; the one that matters now carries the accent.
enum ZentraleButton: Equatable, Identifiable {
    case history                    // its chat: read on, and write to it
    case action(SessionAction)      // what its state asks for: "Rückrufen", "Fortsetzen"
    case call(inCall: Bool)         // talk to Parley (it is the Zentrale now); in a call: back to it
    case message                    // a typed message for it

    var id: String { title }

    var title: String {
        switch self {
        case .history: "Verlauf"
        case .action(let a): a.title
        case .call(let inCall): inCall ? "Zum Anruf" : "Anrufen"
        case .message: "Nachricht"
        }
    }

    var symbol: String {
        switch self {
        case .history: "text.bubble"
        case .action(.resume): "play.fill"
        case .action: "phone.arrow.up.right.fill"
        case .call: "phone.fill"
        case .message: "square.and.pencil"
        }
    }

    /// The history first; then what the session's state asks for, and the call. "Rückrufen" is the
    /// call already, and with nothing asked for there is room for a message — three in every case.
    static func row(action: SessionAction?, inCall: Bool) -> (buttons: [ZentraleButton], primary: ZentraleButton) {
        switch action {
        case .callBack?: ([.history, .action(action!), .message], .action(action!))
        case let a?: ([.history, .action(a), .call(inCall: inCall)], .action(a))
        case nil: ([.history, .message, .call(inCall: inCall)], .call(inCall: inCall))
        }
    }
}

struct ZentraleCard: View {
    let session: Session
    let skew: Double
    /// The other sessions (they report to it), and how many of them are at work.
    let others: Int
    let working: Int
    /// Its updates Sir has not heard: he didn't take its call, they wait for his call back.
    let missed: Int
    let actions: SessionActions
    let inCall: Bool
    let canCall: Bool
    let openHistory: () -> Void
    let message: () -> Void
    let call: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title2) private var ring: CGFloat = 46
    @State private var taps = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let at = context.date.ms + skew
            VStack(alignment: .leading, spacing: 14) {
                // Everything above the buttons opens the details, like any card.
                VStack(alignment: .leading, spacing: 12) {
                    header(at: at)
                    line
                    facts(at: at)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { actions.open(session) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Details öffnen")
                if missed > 0 { waiting }
                buttons
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CardBackground(live: session.voice, radius: 24))
        }
    }

    private func header(at: Double) -> some View {
        HStack(alignment: .center, spacing: 12) {
            RingView(session: session, skew: skew, size: ring)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.title2.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(Fmt.cardState(session, at: at))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(stateInk(session))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Fmt.cornerTime(session, at: at))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// What it said last — or, while it talks, the wave.
    @ViewBuilder
    private var line: some View {
        if session.isLive {
            MiniWave(color: session.state.color).frame(height: 26)
        } else if let text = session.stats?.lastLine, !text.isEmpty {
            Text("„\(text)“")
                .font(.subheadline)
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// How long it has been running, and who reports to it.
    private func facts(at: Double) -> some View {
        let running = session.stats?.startedAt.map { "läuft seit \(Fmt.span(at - $0))" }
        let reports = others == 0 ? "keine weitere Session"
            : "\(others) weitere" + (working > 0 ? " · \(working) \(working == 1 ? "arbeitet" : "arbeiten")" : "")
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                                                  : AnyLayout(HStackLayout(spacing: 14))
        return layout {
            if let running { Label(running, systemImage: "clock") }
            Label(reports, systemImage: "square.stack.3d.up")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var waiting: some View {
        Label(missed == 1 ? "1 Update wartet auf deinen Rückruf" : "\(missed) Updates warten auf deinen Rückruf",
              systemImage: "phone.arrow.down.left")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.claude)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.claude.opacity(0.12)))
    }

    /// Three across the card; stacked when the text is very large.
    private var buttons: some View {
        let row = ZentraleButton.row(action: actions.action(session), inCall: inCall)
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            ForEach(row.buttons) { b in
                let primary = b == row.primary, on = enabled(b)
                Button {
                    taps += 1
                    perform(b)
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: b.symbol).font(.body.weight(.semibold)).frame(height: 20)
                        Text(b.title).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(primary ? Theme.onAccent : Color.primary)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(primary ? Theme.claude : Color.primary.opacity(0.07)))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!on)
                .opacity(on ? 1 : 0.45)
                .accessibilityLabel(b == .call(inCall: false) ? "Parley anrufen" : b.title)
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: taps)
    }

    private func enabled(_ b: ZentraleButton) -> Bool {
        switch b {
        case .history, .message: true
        case .action(let a): a == .resume ? actions.enabled(session) : canCall
        case .call(let inCall): inCall || canCall
        }
    }

    private func perform(_ b: ZentraleButton) {
        switch b {
        case .history: openHistory()
        case .message: message()
        case .action(let a): actions.perform(a, session)
        case .call: call()
        }
    }
}
