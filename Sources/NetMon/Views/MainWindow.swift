import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "Overview", path = "Path", wifi = "Wi-Fi", throughput = "Throughput", events = "Events", settings = "Settings", guide = "Guide"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: "chart.xyaxis.line"
        case .path: "point.3.connected.trianglepath.dotted"
        case .wifi: "wifi"
        case .throughput: "speedometer"
        case .events: "list.bullet.rectangle"
        case .settings: "gearshape"
        case .guide: "book"
        }
    }
}

struct MainWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $model.selectedSection) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch model.selectedSection ?? .overview {
            case .overview: OverviewView()
            case .path: PathView()
            case .wifi: WiFiView()
            case .throughput: ThroughputView()
            case .events: EventsView()
            case .settings: SettingsView()
            case .guide: GuideView()
            }
        }
    }
}
