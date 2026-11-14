import SwiftUI

/// الشاشة الرئيسية: بطاقة الجهاز، المقاييس، ثم كل الأدوات كمربعات.
struct HomeView: View {
    @EnvironmentObject var pi: Pi
    @EnvironmentObject var store: DeviceStore
    @EnvironmentObject var metrics: MetricsModel

    @State private var confirmPower: PowerAction?
    @State private var error: String?
    @State private var busy = false

    enum PowerAction: String, Identifiable {
        case reboot, shutdown
        var id: String { rawValue }
        var title: String { self == .reboot ? "إعادة تشغيل الـ Pi" : "إطفاء الـ Pi" }
        var command: String { self == .reboot ? "systemctl reboot" : "systemctl poweroff" }
    }

    private let two = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
    private let three = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12),
                         GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ConnectionBanner()
                hero
                if let w = metrics.m?.powerWarning {
                    Label(w, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.bold())
                        .foregroundColor(Theme.warn)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.warn.opacity(0.12)))
                }
                block("المقاييس") { metricsGrid }
                block("إجراءات سريعة") {
                    LazyVGrid(columns: two, spacing: 14) {
                        ToolTile(title: "الطرفية", icon: "apple.terminal.fill", big: true) { TerminalScreen() }
                        ToolTile(title: "الملفات", icon: "folder.fill", big: true) { FilesView(path: nil) }
                        ToolTile(title: "الخدمات", icon: "gearshape.2.fill", big: true) { ServicesView() }
                        ToolTile(title: "الرسوم", icon: "chart.xyaxis.line", big: true) { ChartsView() }
                    }
                }
                block("أدوات أخرى") {
                    LazyVGrid(columns: three, spacing: 12) {
                        ToolTile(title: "العمليات", icon: "list.bullet.rectangle.fill") { ProcessesView() }
                        ToolTile(title: "السجلات", icon: "doc.text.fill") { LogsView() }
                        ToolTile(title: "الشبكة", icon: "network") { NetworkView() }
                        ToolTile(title: "الأوامر", icon: "text.badge.plus") { SnippetsView() }
                        ToolTile(title: "التنبيهات", icon: "bell.badge.fill") { AlertsView() }
                        ToolTile(title: "التحميلات", icon: "arrow.down.circle.fill") {
                            FilesView(path: "/mnt/hdd/downloads/metube")
                        }
                    }
                }
                block("متقدّم") {
                    LazyVGrid(columns: three, spacing: 12) {
                        ToolTile(title: "Docker", icon: "shippingbox.fill") { DockerView() }
                        ToolTile(title: "التحديثات", icon: "arrow.triangle.2.circlepath") { PackagesView() }
                        ToolTile(title: "الإعدادات", icon: "gearshape.fill") { MoreView() }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(store.selected?.name ?? "صالحة Pi")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink { MoreView() } label: {
                    Image(systemName: "gearshape.fill")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { confirmPower = .reboot } label: {
                        Label("إعادة تشغيل", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) { confirmPower = .shutdown } label: {
                        Label("إطفاء", systemImage: "power")
                    }
                } label: {
                    Image(systemName: "power.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Theme.bad)
                }
                .disabled(busy || pi.state != .connected)
            }
        }
        .refreshable { await metrics.load(pi) }
        .confirmationDialog(confirmPower?.title ?? "", isPresented: Binding(
            get: { confirmPower != nil }, set: { if !$0 { confirmPower = nil } }
        ), titleVisibility: .visible) {
            if let a = confirmPower {
                Button(a.title, role: .destructive) { power(a) }
            }
        } message: {
            Text("سيتوقف كل ما يعمل على الـ Pi، والإنترنت في البيت سيتوقف حتى يرجع (AdGuard).")
        }
        .errorAlert($error)
    }

    // MARK: - بطاقة الجهاز

    private var statusText: String {
        switch pi.state {
        case .connected: return "متصل"
        case .connecting, .idle: return "جارٍ الاتصال"
        case .failed: return "غير متصل"
        }
    }

    private var statusColor: Color {
        switch pi.state {
        case .connected: return Theme.good
        case .connecting, .idle: return Theme.warn
        case .failed: return Theme.bad
        }
    }

    private var hero: some View {
        let m = metrics.m
        let d = store.selected
        let host = pi.connectedHost.isEmpty ? (d?.host ?? "") : pi.connectedHost
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(d?.name ?? "صالحة Pi")
                        .font(.system(size: 32, weight: .heavy, design: .rounded))
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                    Text((m?.model.isEmpty ?? true) ? "Raspberry Pi" : m!.model)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 8) {
                    chip {
                        Circle().fill(statusColor).frame(width: 9, height: 9)
                        Text(statusText).font(.subheadline.bold())
                    }
                    chip {
                        Image(systemName: "wifi")
                        Text("LAN").font(.subheadline.bold())
                    }
                    .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "globe").foregroundStyle(Theme.icon)
                Text("\(d?.user ?? "")@\(host):\(d?.port ?? 22)")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .environment(\.layoutDirection, .leftToRight)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right").foregroundStyle(Theme.icon)
                    Text("↓ \(Fmt.rate(metrics.rxRate))  ·  ↑ \(Fmt.rate(metrics.txRate))")
                        .font(.callout.monospaced().bold())
                    Spacer(minLength: 0)
                }
                .environment(\.layoutDirection, .leftToRight)
                HStack(spacing: 8) {
                    Image(systemName: "clock.fill").foregroundStyle(Theme.icon)
                    Text(m.map { Fmt.uptime($0.uptime) } ?? "—").font(.callout.bold())
                    if let k = m?.kernel, !k.isEmpty {
                        Text("· \(k)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if let u = metrics.updated {
                    Text("آخر تحديث \(u.formatted(date: .omitted, time: .standard))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color(.tertiarySystemFill)))
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 28)
                .fill(LinearGradient(colors: [Theme.icon.opacity(0.30), Color(.secondarySystemGroupedBackground)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.primary.opacity(0.08)))
    }

    private func chip<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6) { content() }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color(.tertiarySystemFill)))
    }

    // MARK: - المقاييس

    private var metricsGrid: some View {
        let m = metrics.m
        let temp = m?.tempC
        return LazyVGrid(columns: two, spacing: 14) {
            MetricCard(title: "المعالج", icon: "cpu",
                       detail: m.map { "\($0.cores) أنوية · الحمل \(String(format: "%.2f", $0.load.first ?? 0))" } ?? "—",
                       value: m.map { String(format: "%.0f%%", $0.cpuPercent) } ?? "—",
                       percent: m?.cpuPercent,
                       color: Theme.value(m?.cpuPercent ?? 0))
            MetricCard(title: "الذاكرة", icon: "memorychip",
                       detail: m.map { "\(Fmt.bytes($0.memTotal - $0.memAvailable)) / \(Fmt.bytes($0.memTotal))" } ?? "—",
                       value: m.map { String(format: "%.0f%%", $0.memUsedPercent) } ?? "—",
                       percent: m?.memUsedPercent,
                       color: Theme.value(m?.memUsedPercent ?? 0, warn: 80, bad: 92))
            MetricCard(title: "الحرارة", icon: "thermometer.medium",
                       detail: temp.map { $0 < 60 ? "طبيعية" : ($0 < 70 ? "دافئة" : "ساخنة") } ?? "—",
                       value: temp.map { String(format: "%.1f°C", $0) } ?? "—",
                       percent: temp.map { $0 / 85 * 100 },
                       color: Theme.value(temp ?? 0, warn: 65, bad: 75))
            MetricCard(title: "قرص النظام", icon: "internaldrive",
                       detail: m.map { "\(String(format: "%.0f", 100 - $0.diskPercent))% فارغ · \(Fmt.bytes($0.diskTotal))" } ?? "—",
                       value: m.map { String(format: "%.0f%%", $0.diskPercent) } ?? "—",
                       percent: m?.diskPercent,
                       color: Theme.value(m?.diskPercent ?? 0, warn: 80, bad: 92))
            if let m, m.hddTotal > 0 {
                MetricCard(title: "الهارد", icon: "externaldrive.fill",
                           detail: "\(Fmt.bytes(m.hddUsed)) / \(Fmt.bytes(m.hddTotal))",
                           value: m.hddPercent < 1 ? String(format: "%.1f%%", m.hddPercent)
                                                   : String(format: "%.0f%%", m.hddPercent),
                           percent: m.hddPercent,
                           color: Theme.value(m.hddPercent, warn: 80, bad: 92))
            }
            MetricCard(title: "الكهرباء", icon: "bolt.fill",
                       detail: m == nil ? "—" : (m?.powerWarning == nil ? "لا يوجد ضعف" : "انظر التحذير"),
                       value: m == nil ? "—" : (m?.powerWarning == nil ? "سليمة" : "تحذير"),
                       percent: nil,
                       color: m?.powerWarning == nil ? Theme.icon : Theme.warn)
        }
    }

    private func block<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.heavy))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func power(_ a: PowerAction) {
        busy = true
        Task {
            defer { busy = false }
            do {
                // الاتصال ينقطع فور الإطفاء — لذلك نطلقه في الخلفية.
                try await pi.sudo("nohup sh -c 'sleep 1; \(a.command)' >/dev/null 2>&1 &")
            } catch {
                self.error = Pi.describe(error)
            }
        }
    }
}

// MARK: - مكوّنات

struct MetricCard: View {
    let title: String
    let icon: String
    let detail: String
    let value: String
    let percent: Double?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .frame(minHeight: 36, alignment: .topLeading)
            Text(value)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let percent {
                ProgressBar(value: percent / 100, color: color)
            } else {
                Color.clear.frame(height: 8)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color(.secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(color.opacity(0.25), lineWidth: 1))
    }
}

struct ProgressBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.6), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(8, g.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 8)
        .animation(.easeInOut(duration: 0.4), value: value)
    }
}

struct ToolTile<Destination: View>: View {
    let title: String
    let icon: String
    var big = false
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            VStack(spacing: big ? 14 : 10) {
                Image(systemName: icon)
                    .font(.system(size: big ? 38 : 28, weight: .semibold))
                    .foregroundStyle(Theme.icon)
                    .frame(height: big ? 44 : 34)
                Text(title)
                    .font(big ? .title3.bold() : .subheadline.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, big ? 28 : 18)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: big ? 26 : 22).fill(Color(.secondarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: big ? 26 : 22).stroke(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}
