import AppKit
import SwiftUI

struct NetMonApp: App {
    @State private var model = AppModel.shared

    init() {
        AppModel.shared.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("NetMon", id: "main") {
            MainWindow()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
                // Show in the Dock and Cmd-Tab only while the window is open.
                .onAppear { NSApp.setActivationPolicy(.regular) }
                .onDisappear { NSApp.setActivationPolicy(.accessory) }
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 1100, height: 760)
    }
}

struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: StatusDot.image(for: model.overallHealth, testing: model.speedTestRunning))
            Text(model.headlineLatency.map { String(format: "%.0f ms", $0) } ?? "— ms")
                .monospacedDigit()
        }
        // The label exists for the app's whole life, so it's where the API gets a window opener.
        .onAppear { model.openMainWindow = { openWindow(id: "main") } }
    }
}

extension Health {
    var color: Color {
        switch self {
        case .unknown: .gray
        case .ok: .green
        case .degraded: .orange
        case .down: .red
        }
    }
    var label: String {
        switch self {
        case .unknown: "Starting…"
        case .ok: "Healthy"
        case .degraded: "Degraded"
        case .down: "Down"
        }
    }
}

/// Coloured, non-template dot for the menu bar (template images are drawn monochrome).
enum StatusDot {
    static func image(for health: Health, testing: Bool) -> NSImage {
        let color: NSColor = if testing { .systemBlue } else {
            switch health {
            case .unknown: .systemGray
            case .ok: .systemGreen
            case .degraded: .systemOrange
            case .down: .systemRed
            }
        }
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
