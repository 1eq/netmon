import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @AppStorage(Prefs.Key.targets) private var targets = "1.1.1.1, 8.8.8.8"
    @AppStorage(Prefs.Key.pingInterval) private var pingInterval = 1.0
    @AppStorage(Prefs.Key.traceInterval) private var traceInterval = 2.0
    @AppStorage(Prefs.Key.maxHops) private var maxHops = 30
    @AppStorage(Prefs.Key.lossAlertPercent) private var lossAlert = 5.0
    @AppStorage(Prefs.Key.latencyAlertMs) private var latencyAlert = 150.0
    @AppStorage(Prefs.Key.jitterAlertMs) private var jitterAlert = 40.0
    @AppStorage(Prefs.Key.notificationsEnabled) private var notifications = true
    @AppStorage(Prefs.Key.notifyPathFindings) private var notifyPath = true
    @AppStorage(Prefs.Key.autoSpeedTest) private var autoSpeedTest = true
    @AppStorage(Prefs.Key.speedTestCooldownMinutes) private var cooldown = 60.0
    @AppStorage(Prefs.Key.minDownloadMbps) private var minDownload = 0.0
    @AppStorage(Prefs.Key.historyDays) private var historyDays = 7

    @State private var draftTargets = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Targets") {
                HStack {
                    TextField("Hosts or IPv4 addresses", text: $draftTargets)
                        .onSubmit(apply)
                    Button("Apply", action: apply).disabled(draftTargets == targets)
                }
                Text("Comma-separated. Defaults: 1.1.1.1 (Cloudflare) and 8.8.8.8 (Google).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Probing") {
                Stepper(value: $pingInterval, in: 0.5...10, step: 0.5) {
                    Text("Latency ping every \(pingInterval, specifier: "%.1f") s")
                }
                Stepper(value: $traceInterval, in: 1...30, step: 1) {
                    Text("Hop trace every \(traceInterval, specifier: "%.0f") s")
                }
                Stepper(value: $maxHops, in: 5...64) { Text("Max hops: \(maxHops)") }
            }

            Section("Alert thresholds (sustained over 1 minute)") {
                Stepper(value: $lossAlert, in: 1...50, step: 1) { Text("Packet loss ≥ \(lossAlert, specifier: "%.0f")%") }
                Stepper(value: $latencyAlert, in: 20...1000, step: 10) { Text("Average latency ≥ \(latencyAlert, specifier: "%.0f") ms") }
                Stepper(value: $jitterAlert, in: 5...200, step: 5) { Text("Jitter ≥ \(jitterAlert, specifier: "%.0f") ms") }
            }

            Section("Notifications") {
                Toggle("Send macOS notifications", isOn: $notifications)
                Toggle("Notify about bad hops found by path analysis", isOn: $notifyPath)
                    .disabled(!notifications)
                Button("Send test notification") { model.sendTestNotification() }
                Text("If nothing appears, allow NetMon in System Settings › Notifications.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Speed tests") {
                Toggle("Run a speed test automatically when an alert fires", isOn: $autoSpeedTest)
                Stepper(value: $cooldown, in: 15...1440, step: 15) {
                    Text("At most once every \(Int(cooldown)) min")
                }
                .disabled(!autoSpeedTest)
                Stepper(value: $minDownload, in: 0...10_000, step: 10) {
                    Text(minDownload == 0 ? "Slow-download alert: off" : "Alert if download < \(Int(minDownload)) Mbps")
                }
                Text("Speed tests never run on a timer. Each one can move hundreds of MB or more.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Stepper(value: $historyDays, in: 1...90) { Text("Keep history for \(historyDays) days") }
                Button("Show data folder in Finder") { NSWorkspace.shared.open(model.store.directory) }
            }
        }
        .formStyle(.grouped)
        .onAppear { draftTargets = targets }
    }

    private func apply() {
        targets = draftTargets
        model.applyTargets()
    }
}
