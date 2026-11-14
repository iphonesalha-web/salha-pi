import SwiftUI
import UIKit
import Charts

// MARK: - تنفيذ أمر وعرض ناتجه

struct OutputView: View {
    @EnvironmentObject var pi: Pi
    let title: String
    let command: String
    var useSudo = false

    @State private var output = ""
    @State private var running = false

    var body: some View {
        ScrollView {
            Text(output.isEmpty ? (running ? "جارٍ التنفيذ…" : "") : output)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .environment(\.layoutDirection, .leftToRight)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { UIPasteboard.general.string = output } label: { Image(systemName: "doc.on.doc") }
                    .disabled(output.isEmpty)
                Button { Task { await run() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(running)
            }
        }
        .task { await run() }
    }

    private func run() async {
        running = true
        defer { running = false }
        do {
            if useSudo {
                output = try await pi.sudo(command)
            } else {
                output = try await pi.run(command).out
            }
        } catch {
            output = "❌ " + Pi.describe(error)
        }
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            output = "✅ تم (لا يوجد ناتج)"
        }
    }
}

// MARK: - الرسوم البيانية

struct ChartsView: View {
    @EnvironmentObject var metrics: MetricsModel

    var body: some View {
        List {
            if metrics.history.count < 2 {
                Text("يتم جمع البيانات… انتظر بضع ثوانٍ")
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    Text("آخر \(max(1, Int(metrics.history.count * 3 / 60))) دقيقة — تحديث كل 3 ثوانٍ")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                chart("المعالج %", \.cpu, .blue, 0...100)
                chart("الحرارة °C", \.temp, .orange, 20...90)
                chart("الذاكرة %", \.mem, .purple, 0...100)
                Section("الشبكة KiB/s") {
                    Chart {
                        ForEach(metrics.history) { s in
                            LineMark(x: .value("الوقت", s.t), y: .value("KiB/s", s.rx / 1024),
                                     series: .value("النوع", "↓ تنزيل"))
                                .foregroundStyle(by: .value("النوع", "↓ تنزيل"))
                            LineMark(x: .value("الوقت", s.t), y: .value("KiB/s", s.tx / 1024),
                                     series: .value("النوع", "↑ رفع"))
                                .foregroundStyle(by: .value("النوع", "↑ رفع"))
                        }
                    }
                    .frame(height: 160)
                    .environment(\.layoutDirection, .leftToRight)
                }
            }
        }
        .navigationTitle("الرسوم البيانية")
    }

    private func chart(_ title: String, _ kp: KeyPath<MetricsModel.Sample, Double>,
                       _ color: Color, _ domain: ClosedRange<Double>) -> some View {
        Section(title) {
            Chart(metrics.history) { s in
                AreaMark(x: .value("الوقت", s.t),
                         yStart: .value("min", domain.lowerBound),
                         yEnd: .value(title, min(max(s[keyPath: kp], domain.lowerBound), domain.upperBound)))
                    .foregroundStyle(color.opacity(0.18))
                LineMark(x: .value("الوقت", s.t),
                         y: .value(title, min(max(s[keyPath: kp], domain.lowerBound), domain.upperBound)))
                    .foregroundStyle(color)
            }
            .chartYScale(domain: domain)
            .frame(height: 150)
            .environment(\.layoutDirection, .leftToRight)
        }
    }
}

// MARK: - السجلات

struct LogsView: View {
    @EnvironmentObject var pi: Pi

    struct Source: Hashable {
        let title: String
        let command: String
    }

    static let sources: [Source] = [
        .init(title: "النظام", command: "journalctl -n 200 --no-pager -o short"),
        .init(title: "الأخطاء فقط", command: "journalctl -p err -n 200 --no-pager -o short"),
        .init(title: "حارس الـ Pi", command: "journalctl -u pi-health -n 200 --no-pager -o short"),
        .init(title: "شاشة الـ Pi", command: "journalctl -u pi-screen -n 200 --no-pager -o short"),
        .init(title: "مراقب المواقع", command: "journalctl -u site-monitor -n 200 --no-pager -o short"),
        .init(title: "AdGuard", command: "journalctl -u AdGuardHome -n 200 --no-pager -o short"),
        .init(title: "النسخ الاحتياطي", command: "tail -n 200 /var/log/pi-backup.log"),
        .init(title: "MeTube", command: "docker logs --tail 200 metube 2>&1"),
    ]

    @State private var source = LogsView.sources[0]
    @State private var text = ""
    @State private var loading = false
    @State private var search = ""

    private var lines: [String] {
        let all = text.components(separatedBy: "\n").filter { !$0.isEmpty }.reversed()
        let s = search.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? Array(all) : all.filter { $0.localizedCaseInsensitiveContains(s) }
    }

    var body: some View {
        List {
            Section {
                Picker("المصدر", selection: $source) {
                    ForEach(Self.sources, id: \.self) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("الأحدث في الأعلى")
            }
            Section("\(lines.count) سطر") {
                if loading && text.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    Text(l)
                        .font(.caption.monospaced())
                        .foregroundColor(color(l))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
        }
        .searchable(text: $search, prompt: "بحث في السجل")
        .navigationTitle("السجلات")
        .toolbar {
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(loading)
        }
        .refreshable { await load() }
        .task(id: source) { await load() }
    }

    private func color(_ l: String) -> Color {
        let s = l.lowercased()
        if s.contains("error") || s.contains("fail") || s.contains("❌") { return Theme.bad }
        if s.contains("warn") { return Theme.warn }
        return .primary
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            text = try await pi.sudo(source.command)
        } catch {
            text = "❌ " + Pi.describe(error)
        }
    }
}

// MARK: - الشبكة

struct NetworkView: View {
    @EnvironmentObject var pi: Pi

    static let infoCommand = """
    echo "📍 العناوين:"; ip -brief -4 addr | grep -v '^lo' | awk '{print "   " $1 "   " $3}'
    echo; echo "🚪 البوابة (الراوتر):"; ip route | awk '/^default/ {print "   " $3 "  (" $5 ")"}'
    echo; echo "🔎 DNS:"; grep '^nameserver' /etc/resolv.conf | awk '{print "   " $2}'
    echo; echo "🔌 المنافذ المفتوحة:"; echo "   $(ss -ltnH | awk '{print $4}' | sed 's/.*://' | sort -n -u | tr '\\n' ' ')"
    """

    struct Test: Hashable {
        let title: String
        let icon: String
        let command: String
    }

    static let tests: [Test] = [
        .init(title: "اختبار الإنترنت", icon: "globe",
              command: "ping -c 4 -W 2 1.1.1.1 | tail -2"),
        .init(title: "اختبار DNS", icon: "magnifyingglass",
              command: "ping -c 3 -W 2 google.com | tail -2"),
        .init(title: "العنوان الخارجي", icon: "location.fill",
              command: "curl -s --max-time 8 https://api.ipify.org; echo"),
        .init(title: "سرعة التنزيل", icon: "speedometer",
              command: "curl -s -o /dev/null --max-time 20 -w '%{speed_download}' 'https://speed.cloudflare.com/__down?bytes=25000000' | awk '{printf \"%.1f Mbit/s\\n\", $1*8/1000000}'"),
    ]

    @State private var info = ""
    @State private var results: [String: String] = [:]
    @State private var running: String?

    var body: some View {
        List {
            Section("معلومات") {
                Text(info.isEmpty ? "جارٍ القراءة…" : info)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("اختبارات") {
                ForEach(Self.tests, id: \.self) { t in
                    Button { Task { await run(t) } } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(t.title, systemImage: t.icon)
                                Spacer()
                                if running == t.title { ProgressView() }
                            }
                            if let r = results[t.title] {
                                Text(r)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .environment(\.layoutDirection, .leftToRight)
                            }
                        }
                    }
                    .disabled(running != nil)
                }
            }
        }
        .navigationTitle("الشبكة")
        .refreshable { await loadInfo() }
        .task { await loadInfo() }
    }

    private func loadInfo() async {
        do { info = try await pi.run(Self.infoCommand).out.trimmingCharacters(in: .whitespacesAndNewlines) }
        catch { info = "❌ " + Pi.describe(error) }
    }

    private func run(_ t: Test) async {
        running = t.title
        defer { running = nil }
        do {
            let out = try await pi.run(t.command).out.trimmingCharacters(in: .whitespacesAndNewlines)
            results[t.title] = out.isEmpty ? "❌ لا يوجد رد" : out
        } catch {
            results[t.title] = "❌ " + Pi.describe(error)
        }
    }
}

// MARK: - Docker

struct DockerView: View {
    @EnvironmentObject var pi: Pi

    struct Container: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let image: String
        let status: String
        let running: Bool
    }

    @State private var items: [Container] = []
    @State private var loading = false
    @State private var error: String?
    @State private var acting: String?

    var body: some View {
        List {
            if loading && items.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            if !loading && items.isEmpty && error == nil {
                Text("لا توجد حاويات").foregroundStyle(.secondary)
            }
            ForEach(items) { c in
                Section {
                    HStack(spacing: 12) {
                        Circle().fill(c.running ? Theme.good : Theme.bad).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.name).font(.headline)
                            Text(c.image).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            Text(c.status).font(.caption).foregroundStyle(.secondary)
                        }
                        .environment(\.layoutDirection, .leftToRight)
                        Spacer()
                        if acting == c.name { ProgressView() }
                    }
                    HStack(spacing: 10) {
                        if c.running {
                            action("إيقاف", "stop.fill", c, "stop", role: .destructive)
                            action("إعادة تشغيل", "arrow.clockwise", c, "restart")
                        } else {
                            action("تشغيل", "play.fill", c, "start")
                        }
                        Spacer()
                        NavigationLink {
                            OutputView(title: "سجل \(c.name)", command: "docker logs --tail 150 \(c.name) 2>&1", useSudo: true)
                        } label: {
                            Label("السجل", systemImage: "doc.text")
                        }
                        .buttonStyle(.bordered)
                        .fixedSize()
                    }
                    .disabled(acting != nil)
                }
            }
        }
        .navigationTitle("Docker")
        .toolbar {
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(loading)
        }
        .refreshable { await load() }
        .task { await load() }
        .errorAlert($error)
    }

    private func action(_ title: String, _ icon: String, _ c: Container, _ verb: String,
                        role: ButtonRole? = nil) -> some View {
        Button(role: role) {
            Task {
                acting = c.name
                defer { acting = nil }
                do {
                    try await pi.sudo("docker \(verb) \(c.name)")
                    await load()
                } catch {
                    self.error = Pi.describe(error)
                }
            }
        } label: {
            Label(title, systemImage: icon)
        }
        .buttonStyle(.bordered)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let out = try await pi.sudo("docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.State}}'")
            items = out.split(separator: "\n").compactMap { line in
                let p = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard p.count >= 4 else { return nil }
                return Container(name: p[0], image: p[1], status: p[2], running: p[3] == "running")
            }
            .sorted { ($0.running ? 0 : 1, $0.name) < ($1.running ? 0 : 1, $1.name) }
        } catch {
            self.error = Pi.describe(error)
        }
    }
}

// MARK: - تحديثات النظام

struct PackagesView: View {
    @EnvironmentObject var pi: Pi

    @State private var packages: [String] = []
    @State private var checked = false
    @State private var busy = false
    @State private var log = ""
    @State private var upgrading = false
    @State private var confirm = false
    @State private var error: String?

    private static let logFile = "/tmp/salha-upgrade.log"

    var body: some View {
        List {
            Section {
                Button { Task { await refresh() } } label: {
                    HStack {
                        Label("البحث عن تحديثات", systemImage: "magnifyingglass")
                        if busy { Spacer(); ProgressView() }
                    }
                }
                .disabled(busy || upgrading)
                Button { confirm = true } label: {
                    Label("تثبيت كل التحديثات (\(packages.count))", systemImage: "arrow.down.circle.fill")
                }
                .disabled(packages.isEmpty || busy || upgrading)
            } footer: {
                Text("التحديث يعمل على الـ Pi في الخلفية، ويمكنك إغلاق هذه الشاشة.")
            }

            if upgrading || !log.isEmpty {
                Section(upgrading ? "جارٍ التحديث…" : "سجل آخر تحديث") {
                    Text(log.isEmpty ? "…" : log)
                        .font(.caption2.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }

            Section(checked ? (packages.isEmpty ? "النظام محدّث ✅" : "\(packages.count) حزمة لها تحديث") : "الحزم") {
                ForEach(packages, id: \.self) { p in
                    Text(p).font(.footnote.monospaced())
                        .environment(\.layoutDirection, .leftToRight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationTitle("تحديثات النظام")
        .confirmationDialog("تثبيت \(packages.count) تحديث؟", isPresented: $confirm, titleVisibility: .visible) {
            Button("تثبيت الآن") { Task { await upgrade() } }
        } message: {
            Text("قد تُعاد بعض الخدمات تلقائياً أثناء التحديث.")
        }
        .task { await list(); await watchIfRunning() }
        .errorAlert($error)
    }

    private func list() async {
        do {
            let out = try await pi.run("apt list --upgradable 2>/dev/null | tail -n +2").out
            packages = out.split(separator: "\n").map { String($0.split(separator: "/").first ?? Substring($0)) }
            checked = true
        } catch {
            self.error = Pi.describe(error)
        }
    }

    private func refresh() async {
        busy = true
        defer { busy = false }
        do {
            try await pi.sudo("apt-get update -qq")
            await list()
        } catch {
            self.error = Pi.describe(error)
        }
    }

    private func upgrade() async {
        do {
            try await pi.sudo("rm -f \(Self.logFile); nohup sh -c 'DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold upgrade > \(Self.logFile) 2>&1; echo __DONE__ >> \(Self.logFile)' >/dev/null 2>&1 &")
            upgrading = true
            await watchIfRunning()
        } catch {
            self.error = Pi.describe(error)
        }
    }

    /// يتابع ملف السجل حتى ينتهي التحديث.
    private func watchIfRunning() async {
        while !Task.isCancelled {
            guard let out = try? await pi.run("tail -n 25 \(Self.logFile) 2>/dev/null").out, !out.isEmpty else {
                upgrading = false
                return
            }
            let done = out.contains("__DONE__")
            log = out.replacingOccurrences(of: "__DONE__", with: "✅ انتهى التحديث")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            upgrading = !done
            if done {
                await list()
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}

// MARK: - الأوامر المحفوظة

struct SnippetsView: View {
    @AppStorage("quick.commands") private var data: Data = Data()
    @State private var editing = false

    private var items: [QuickCommand] {
        (try? JSONDecoder().decode([QuickCommand].self, from: data)) ?? QuickCommand.defaults
    }

    var body: some View {
        List {
            Section {
                ForEach(items) { q in
                    NavigationLink {
                        OutputView(title: q.title, command: Self.strip(q.command), useSudo: Self.isSudo(q.command))
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(q.title).font(.headline)
                            Text(q.command)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .environment(\.layoutDirection, .leftToRight)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            } footer: {
                Text("اضغط على أمر لتشغيله ورؤية النتيجة. الأوامر التفاعلية مثل htop تعمل في «الطرفية» فقط. نفس القائمة تظهر كأزرار تحت الطرفية.")
            }
        }
        .navigationTitle("الأوامر المحفوظة")
        .toolbar {
            Button { editing = true } label: { Image(systemName: "square.and.pencil") }
        }
        .sheet(isPresented: $editing) {
            QuickCommandsEditor(data: $data, initial: items)
                .environment(\.layoutDirection, .rightToLeft)
        }
    }

    static func isSudo(_ c: String) -> Bool {
        c.trimmingCharacters(in: .whitespaces).hasPrefix("sudo ")
    }

    /// «sudo apt update && sudo apt upgrade -y» ← يُنفَّذ كله بصلاحيات root بدون كلمة sudo.
    static func strip(_ c: String) -> String {
        guard isSudo(c) else { return c }
        return c.replacingOccurrences(of: "sudo ", with: "")
    }
}
