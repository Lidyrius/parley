import ActivityKit
import Foundation

/// The app's side of the Parley Live Activity. The host starts, updates and ends it by push, so
/// the app hands it the tokens — the push-to-start token, and each running activity's update
/// token — and ends it at once when Unterwegs goes off. iOS wakes the app in the background when
/// a push starts one, so its token still reaches the host.
@MainActor
final class ActivityLink {
    private(set) var startToken: String?
    /// The running activity's update token; nil = none runs.
    private(set) var updateToken: String?
    /// A token changed: send them.
    var onChange: (() -> Void)?
    private var watched: [String] = []   // in the order they appeared
    private var demoStarted = false
    private var subtitle: String?

    func start() {
        if #available(iOS 17.2, *) {
            Task {
                for await data in Activity<ParleyAttributes>.pushToStartTokenUpdates {
                    let hex = PushPayload.hex(data)
                    guard hex != startToken else { continue }
                    startToken = hex
                    onChange?()
                }
            }
        }
        Task {
            for await activity in Activity<ParleyAttributes>.activityUpdates { watch(activity) }
        }
        for activity in Activity<ParleyAttributes>.activities { watch(activity) }
    }

    /// One activity at a time: a newer one (a second push-to-start) replaces the older ones —
    /// only older ones, so two arriving together can't end each other.
    private func watch(_ activity: Activity<ParleyAttributes>) {
        guard !watched.contains(activity.id) else { return }
        let older = Set(watched)
        watched.append(activity.id)
        Task {
            for other in Activity<ParleyAttributes>.activities where older.contains(other.id) && other.activityState == .active {
                await other.end(nil, dismissalPolicy: .immediate)
            }
        }
        Task {
            for await data in activity.pushTokenUpdates {
                updateToken = PushPayload.hex(data)
                onChange?()
            }
        }
        Task {
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                guard !Activity<ParleyAttributes>.activities.contains(where: { $0.activityState == .active }) else { continue }
                updateToken = nil
                onChange?()
            }
        }
    }

    /// In a call: the line spoken now (nil = done), updated in place — the app runs anyway, and a
    /// local update costs no push. The host's next push clears it, the next line brings it back.
    func subtitle(_ text: String?, from label: String?) async {
        guard text != subtitle else { return }
        subtitle = text
        for activity in Activity<ParleyAttributes>.activities where activity.activityState == .active {
            var state = activity.content.state
            guard state.caption != text else { continue }
            state.caption = text
            state.speaker = text == nil ? nil : label
            await activity.update(.init(state: state, staleDate: activity.content.staleDate))
        }
    }

    /// A tapped answer: the question goes, the answer shows as the last line.
    func answered(_ text: String) async {
        for activity in Activity<ParleyAttributes>.activities where activity.activityState == .active {
            var state = activity.content.state
            state.ask = nil
            state.line = text
            state.from = ParleyAttributes.ContentState.you
            await activity.update(.init(state: state, staleDate: activity.content.staleDate))
        }
    }

    func endAll() async {
        for activity in Activity<ParleyAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// `-demoActivity` (simulator, screenshots): the demo content, started locally.
    func startDemo() async {
        guard !demoStarted else { return }
        demoStarted = true
        await endAll()
        do {
            let args = ProcessInfo.processInfo.arguments
            let state: ParleyAttributes.ContentState = args.contains("ask") ? .demoAsk() : args.contains("speech") ? .demoSpeech() : .demo()
            _ = try Activity.request(attributes: ParleyAttributes(), content: .init(state: state, staleDate: nil, relevanceScore: 50))
        } catch {
            NSLog("demo activity: %@", "\(error)")
        }
    }
}
