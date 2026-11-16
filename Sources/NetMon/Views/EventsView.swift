import SwiftUI

struct EventsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Events").font(.largeTitle).bold()
            if model.events.isEmpty {
                ContentUnavailableView("Nothing yet", systemImage: "checkmark.seal",
                                       description: Text("Alerts, recoveries and speed tests show up here."))
            } else {
                List(model.events.reversed()) { EventRow(event: $0) }
            }
        }
        .padding(24)
    }
}

struct EventRow: View {
    let event: NetEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(event.title).bold()
                    Spacer()
                    Text(event.date.formatted(date: .abbreviated, time: .standard))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(event.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch event.level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"
        case .recovered: "checkmark.circle.fill"
        }
    }
    private var color: Color {
        switch event.level {
        case .info: .blue
        case .warning: .orange
        case .critical: .red
        case .recovered: .green
        }
    }
}
