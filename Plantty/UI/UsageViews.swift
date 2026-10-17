import SwiftUI

/// Compact Claude / Codex usage chips for the sidebar footer and the tab bar.
/// Each shows the share left of its tightest limit; clicking opens the full panel.
struct UsageChips: View {
    @State private var usage = UsageService.shared
    @AppStorage(showUsageKey) private var showUsage = true
    @State private var panelProvider: UsageProvider?

    var body: some View {
        if showUsage, !usage.available.isEmpty {
            HStack(spacing: 2) {
                ForEach(usage.available) { provider in
                    UsageChip(provider: provider, report: usage.reports[provider], failed: usage.errors[provider] != nil) {
                        panelProvider = provider
                    }
                }
            }
            .popover(isPresented: Binding(get: { panelProvider != nil }, set: { if !$0 { panelProvider = nil } }),
                     arrowEdge: .bottom) {
                UsagePanel(selection: Binding(get: { panelProvider ?? usage.available[0] }, set: { panelProvider = $0 }))
            }
            .onChange(of: panelProvider) {
                usage.isPanelOpen = panelProvider != nil
                if panelProvider != nil { usage.refreshIfStale() }
            }
        }
    }
}

private struct UsageChip: View {
    let provider: UsageProvider
    let report: UsageReport?
    let failed: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let window = report?.tightest
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: provider.symbol).font(.system(size: 10, weight: .semibold))
                if failed && report == nil {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                } else if let window {
                    Text("\(window.left)%").font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
            }
            .foregroundStyle(window.map { severityColor(left: $0.left) } ?? .secondary)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(hovering ? Theme.hover : .clear, in: .rect(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(window.map { "\(provider.name): \($0.title) \($0.left)% left" } ?? "\(provider.name) usage")
        .accessibilityLabel(window.map { "\(provider.name) usage, \($0.title.lowercased()) \($0.left) percent left" }
            ?? "\(provider.name) usage")
    }
}

/// Neutral until a limit runs low, then orange, then red.
private func severityColor(left: Int) -> Color {
    left <= 5 ? .red : left <= 20 ? .orange : .secondary
}

/// The detailed panel: account, every limit with its pace, breakdown, extra usage and links.
struct UsagePanel: View {
    @Binding var selection: UsageProvider
    @State private var usage = UsageService.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        let report = usage.reports[selection]
        VStack(alignment: .leading, spacing: 0) {
            header(report)
            if let error = usage.errors[selection] {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }
            if let report {
                section {
                    ForEach(report.windows, id: \.title) { WindowRow(window: $0) }
                }
                if !report.shares.isEmpty {
                    section {
                        Text("This week by surface").font(.system(size: 13, weight: .semibold))
                        ForEach(report.shares, id: \.name) { share in
                            HStack(spacing: 10) {
                                Text(share.name).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                                UsageBar(fraction: share.percent / 100, tick: nil)
                                Text("\(Int(share.percent.rounded()))%").monospacedDigit().frame(width: 36, alignment: .trailing)
                            }
                            .font(.system(size: 12))
                        }
                    }
                }
                ForEach(Array(Set(report.facts.map(\.section))).sorted(), id: \.self) { title in
                    section {
                        Text(title).font(.system(size: 13, weight: .semibold))
                        ForEach(report.facts.filter { $0.section == title }, id: \.label) { fact in
                            HStack {
                                Text(fact.label).foregroundStyle(.secondary)
                                Spacer()
                                Text(fact.value)
                            }
                            .font(.system(size: 12))
                        }
                    }
                }
            }
            section(spacing: 2) {
                PanelAction(title: usage.isRefreshing ? "Refreshing…" : "Refresh", symbol: "arrow.clockwise") { usage.refresh() }
                PanelAction(title: "Usage Dashboard", symbol: "chart.xyaxis.line") { openURL(selection.dashboard) }
                PanelAction(title: "Status Page", symbol: "waveform.path.ecg") { openURL(selection.statusPage) }
            }
            if usage.available.count > 1 {
                Theme.separator.frame(height: 1)
                HStack(spacing: 4) {
                    ForEach(usage.available) { provider in
                        ProviderTab(provider: provider, selected: provider == selection) { selection = provider }
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 320)
    }

    private func header(_ report: UsageReport?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(selection.name).font(.system(size: 17, weight: .semibold))
                Spacer()
                if let email = report?.email { Text(email).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
            }
            HStack {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(report.map { "Updated \(ago($0.fetchedAt))" } ?? (usage.isRefreshing ? "Loading…" : "No data yet"))
                }
                Spacer()
                if let plan = report?.plan { Text(plan) }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private func section<Content: View>(spacing: CGFloat = 12, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Theme.separator.frame(height: 1)
            VStack(alignment: .leading, spacing: spacing) { content() }.padding(16)
        }
    }

    private func ago(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        return seconds < 60 ? "just now" : "\(countdown(seconds)) ago"
    }
}

private struct WindowRow: View {
    let window: UsageWindow

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let pace = window.pace(now: context.date)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(window.title) \(window.left)% left").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if let resetsAt = window.resetsAt {
                        Text("Resets in \(countdown(resetsAt.timeIntervalSince(context.date)))")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                // The bar shows what's left; the tick marks where an even spend would be by now.
                UsageBar(fraction: Double(window.left) / 100, tick: pace.map { 1 - $0.expected / 100 },
                         color: window.left <= 20 ? severityColor(left: window.left) : .accentColor)
                if let pace {
                    Text(pace.describe(used: window.used)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct UsageBar: View {
    let fraction: Double
    let tick: Double?
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.ink.opacity(0.1))
                Capsule().fill(color.opacity(0.85)).frame(width: geo.size.width * min(max(fraction, 0), 1))
                if let tick {
                    Rectangle().fill(Theme.ink.opacity(0.75))
                        .frame(width: 2, height: geo.size.height + 4)
                        .offset(x: geo.size.width * min(max(tick, 0), 1) - 1)
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

private struct PanelAction: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5).padding(.horizontal, 6)
                .background(hovering ? Theme.hover : .clear, in: .rect(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, -6)
    }
}

private struct ProviderTab: View {
    let provider: UsageProvider
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: provider.symbol).font(.system(size: 14, weight: .medium))
                Text(provider.name).font(.system(size: 11))
            }
            .foregroundStyle(selected ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(selected ? Color.accentColor.opacity(0.22) : .clear, in: .rect(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
