import Foundation
import UserNotifications

/// Watches the monitors and turns sustained state changes into notifications and events.
/// Everything is edge-triggered with hysteresis so a flapping link doesn't spam you.
@MainActor
final class AlertManager: NSObject, UNUserNotificationCenterDelegate {
    private unowned let model: AppModel
    private var targetState: [String: Health] = [:]
    private var connectionDownSince: Date?
    /// When each warning/critical path finding was first seen, and when we last notified.
    private var findingFirstSeen: [String: Date] = [:]
    private var findingNotified: [String: Date] = [:]

    private static let evaluateEvery: TimeInterval = 10
    private static let findingPersistFor: TimeInterval = 60
    private static let findingCooldown: TimeInterval = 30 * 60

    /// UNUserNotificationCenter crashes in a process without a bundle (e.g. `swift run`).
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        if canNotify {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.evaluateEvery))
                evaluate()
            }
        }
    }

    private func evaluate() {
        // A running speed test saturates the link; anything measured now is self-inflicted.
        guard !model.inSpeedTestQuietPeriod else { return }
        let monitors = model.monitors

        // Whole connection down: every target fully unreachable.
        let states = monitors.map { ($0, $0.stats(lastSeconds: 20)) }
        let allDown = !states.isEmpty && states.allSatisfy { $0.1.sent >= 5 && $0.1.received == 0 }
        if allDown, connectionDownSince == nil {
            connectionDownSince = Date()
            emit(.critical, "Internet connection down", "No replies from \(monitors.map(\.host).joined(separator: " or ")).", sound: true)
        } else if !allDown, let since = connectionDownSince, states.contains(where: { $0.1.received > 0 }) {
            connectionDownSince = nil
            emit(.recovered, "Internet connection restored", "Was down for \(Self.duration(Date().timeIntervalSince(since))).")
        }

        // Per-target degradation over the last minute (skipped while fully down).
        for m in monitors where connectionDownSince == nil {
            let s = m.stats(lastSeconds: 60)
            guard s.sent >= 20 else { continue }
            let lossBad = s.lossPercent >= Prefs.lossAlertPercent
            let latencyBad = (s.avg ?? 0) >= Prefs.latencyAlertMs
            let jitterBad = (s.jitter ?? 0) >= Prefs.jitterAlertMs
            // Recover only once comfortably under thresholds (hysteresis).
            let recovered = s.lossPercent < Prefs.lossAlertPercent * 0.5
                && (s.avg ?? 0) < Prefs.latencyAlertMs * 0.8
                && (s.jitter ?? 0) < Prefs.jitterAlertMs * 0.8
            let previous = targetState[m.host] ?? .ok

            if previous != .degraded, lossBad || latencyBad || jitterBad {
                targetState[m.host] = .degraded
                var problems: [String] = []
                if lossBad { problems.append(String(format: "%.0f%% packet loss", s.lossPercent)) }
                if latencyBad { problems.append(String(format: "%.0f ms avg latency", s.avg ?? 0)) }
                if jitterBad { problems.append(String(format: "%.0f ms jitter", s.jitter ?? 0)) }
                let hint = m.worstFinding.flatMap { $0.severity >= .warning ? " Likely cause: \($0.title.lowercased())." : nil } ?? ""
                emit(.warning, "Degraded connection to \(m.host)", problems.joined(separator: ", ") + " over the last minute." + hint)
                model.triggerSpeedTest(reason: "degraded connection to \(m.host)")
            } else if previous == .degraded, recovered {
                targetState[m.host] = .ok
                emit(.recovered, "\(m.host) back to normal",
                     String(format: "%.1f ms avg, %.0f%% loss.", s.avg ?? 0, s.lossPercent))
            }
        }

        // Path findings that persist for a minute.
        guard connectionDownSince == nil else { return }
        let now = Date()
        var current = Set<String>()
        for m in monitors {
            for f in m.findings where f.severity >= .warning {
                let key = "\(m.host)|\(f.key)"
                current.insert(key)
                let first = findingFirstSeen[key] ?? now
                findingFirstSeen[key] = first
                let cooled = findingNotified[key].map { now.timeIntervalSince($0) > Self.findingCooldown } ?? true
                if now.timeIntervalSince(first) >= Self.findingPersistFor, cooled {
                    findingNotified[key] = now
                    emit(f.severity == .critical ? .critical : .warning, "\(m.host): \(f.title)", f.detail,
                         notify: Prefs.notifyPathFindings)
                    model.triggerSpeedTest(reason: "\(m.host): \(f.title.lowercased())")
                }
            }
        }
        findingFirstSeen = findingFirstSeen.filter { current.contains($0.key) }
    }

    func checkThroughput(_ r: ThroughputResult) {
        let min = Prefs.minDownloadMbps
        guard min > 0, r.downloadMbps < min else { return }
        emit(.warning, "Slow download speed", String(format: "%.0f Mbps measured, below your %.0f Mbps threshold.", r.downloadMbps, min))
    }

    func ipv6Changed(available: Bool, twins: [String]) {
        if available {
            emit(.info, "IPv6 is now available",
                 "Monitoring IPv6 alongside IPv4" + (twins.isEmpty ? "." : ": \(twins.joined(separator: ", "))."))
        } else {
            emit(.info, "IPv6 is no longer available", "IPv6 targets are paused until it comes back. IPv4 monitoring continues.")
        }
    }

    func sendTest() {
        emit(.info, "NetMon test notification", "Notifications are working.", sound: true)
    }

    private func emit(_ level: NetEvent.Level, _ title: String, _ detail: String, sound: Bool = false, notify: Bool = true) {
        model.record(NetEvent(date: Date(), level: level, title: title, detail: detail))
        guard notify, Prefs.notificationsEnabled, canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = detail
        if sound || level == .critical { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    static func duration(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = t >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: t) ?? "\(Int(t))s"
    }
}
