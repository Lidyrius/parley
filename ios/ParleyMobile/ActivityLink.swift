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
    private var watched: Set<String> = []

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

    /// One activity at a time: a newer one (a second push-to-start) replaces the older.
    private func watch(_ activity: Activity<ParleyAttributes>) {
        guard watched.insert(activity.id).inserted else { return }
        let id = activity.id
        Task {
            for other in Activity<ParleyAttributes>.activities where other.id != id && other.activityState == .active {
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

    func endAll() async {
        for activity in Activity<ParleyAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// `-demoActivity` (simulator, screenshots): the demo content, started locally.
    func startDemo() async {
        await endAll()
        do {
            _ = try Activity.request(attributes: ParleyAttributes(), content: .init(state: .demo(), staleDate: nil, relevanceScore: 50))
        } catch {
            NSLog("demo activity: %@", "\(error)")
        }
    }
}
