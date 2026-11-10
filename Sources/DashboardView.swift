import SwiftUI
import Charts

struct DashboardView: View {
    @EnvironmentObject var pi: Pi
    @EnvironmentObject var store: DeviceStore

    @State private var m: Metrics?
    @State private var history: [Sample] = []
    @State private var error: String?
    @State private var confirmPower: PowerAction?
    @State private var busy = false

    struct Sample: Identifiable {
        let id = UUID()
        let t: Date
        let cpu: Double
        let temp: Double
    }

    enum PowerAction: String, Identifiable {
        case reboot, shutdown
        var id: String { rawValue }
        var title: String { self == .reboot ? "إعادة تشغيل الـ Pi" : "إطفاء الـ Pi" }
        var command: String { self == .reboot ? "systemctl reboot" : "systemctl poweroff" }
    }

    var body: some View {
        List {
            Section { ConnectionBanner() }
                .listRowBackground(Color.clear)

            if let m {
                Section {
                    header(m)
                }
                if let w = m.powerWarning {
                    Section {
                        Label(w, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(Theme.warn)
                    }
                }
                Section {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        gauge("الحرارة", value: m.tempC ?? 0, max: 85,
                              text: m.tempC.map { String(format: "%.0f°", $0) } ?? "—",
                              color: Theme.level(m.tempC ?? 0, warn: 65, bad: 75), icon: "thermometer.medium")
                        gauge("المعالج", value: m.cpuPercent, max: 100,
                              text: String(format: "%.0f%%", m.cpuPercent),
                              color: Theme.level(m.cpuPercent), icon: "cpu")
                        gauge("الذاكرة", value: m.memUsedPercent, max: 100,
                              text: String(format: "%.0f%%", m.memUsedPercent),
                              color: Theme.level(m.memUsedPercent, warn: 80, bad: 92), icon: "memorychip",
                              sub: "\(Fmt.bytes(m.memTotal - m.memAvailable)) من \(Fmt.bytes(m.memTotal))")
                        gauge("القرص", value: m.diskPercent, max: 100,
                              text: String(format: "%.0f%%", m.diskPercent),
                              color: Theme.level(m.diskPercent, warn: 80, bad: 92), icon: "internaldrive",
                              sub: "\(Fmt.bytes(m.diskUsed)) من \(Fmt.bytes(m.diskTotal))")
                    }
                    .padding(.vertical, 4)
                }
                if history.count > 2 {
                    Section("آخر دقيقتين") {
                        Chart(history) { s in
                            LineMark(x: .value("الوقت", s.t), y: .value("المعالج", s.cpu))
                                .foregroundStyle(by: .value("النوع", "المعالج %"))
                            LineMark(x: .value("الوقت", s.t), y: .value("الحرارة", s.temp))
                                .foregroundStyle(by: .value("النوع", "الحرارة °"))
                        }
                        .chartYScale(domain: 0...100)
                        .chartXAxis(.hidden)
                        .frame(height: 150)
                        .environment(\.layoutDirection, .leftToRight)
                    }
                }
                Section("معلومات") {
                    info("الجهاز", m.model)
                    info("النظام", m.os)
                    info("العنوان", m.ip.isEmpty ? pi.connectedHost : m.ip)
                    info("يعمل منذ", Fmt.uptime(m.uptime))
                    info("الحِمل", m.load.map { String(format: "%.2f", $0) }.joined(separator: "  "))
                }
                Section("الطاقة") {
                    Button { confirmPower = .reboot } label: {
                        Label("إعادة تشغيل", systemImage: "arrow.clockwise.circle")
                    }
                    Button(role: .destructive) { confirmPower = .shutdown } label: {
                        Label("إطفاء آمن", systemImage: "power.circle")
                    }
                }
                .disabled(busy)
            } else if pi.state == .connected {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            }
        }
        .navigationTitle(store.selected?.name ?? "صالحة Pi")
        .refreshable { await load() }
        .task(id: pi.state) {
            guard pi.state == .connected else { return }
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .confirmationDialog(confirmPower?.title ?? "", isPresented: Binding(
            get: { confirmPower != nil }, set: { if !$0 { confirmPower = nil } }
        ), titleVisibility: .visible) {
            if let a = confirmPower {
                Button(a.title, role: .destructive) { power(a) }
            }
        } message: {
            Text("سيتوقف كل ما يعمل على الـ Pi، ومنه نظام المواعيد.")
        }
        .errorAlert($error)
    }

    private func load() async {
        guard pi.isConnected else { return }
        do {
            let out = try await pi.runOK(Metrics.command)
            let nm = Metrics.parse(out)
            m = nm
            history.append(Sample(t: Date(), cpu: nm.cpuPercent, temp: nm.tempC ?? 0))
            if history.count > 40 { history.removeFirst(history.count - 40) }
        } catch {
            // أخطاء التحديث الدوري لا تُعرض كنافذة — الشريط العلوي يكفي.
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

    private func header(_ m: Metrics) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 34))
                .foregroundColor(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(m.hostname).font(.title3.bold())
                Text("متصل · \(pi.connectedHost)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Circle().fill(Theme.good).frame(width: 10, height: 10)
        }
        .padding(.vertical, 4)
    }

    private func gauge(_ title: String, value: Double, max: Double, text: String,
                       color: Color, icon: String, sub: String? = nil) -> some View {
        VStack(spacing: 6) {
            Gauge(value: min(value, max), in: 0...max) {
                Image(systemName: icon)
            } currentValueLabel: {
                Text(text).font(.headline.monospacedDigit())
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(color)
            .scaleEffect(1.25)
            .padding(.vertical, 8)
            Text(title).font(.subheadline.bold())
            if let sub {
                Text(sub).font(.caption2).foregroundColor(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }

    private func info(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundColor(.secondary)
            Spacer()
            Text(v.isEmpty ? "—" : v).multilineTextAlignment(.trailing)
        }
    }
}
