import SwiftUI

/// خدمة systemd واحدة.
struct ServiceItem: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let active: String      // active / inactive / failed ...
    let sub: String         // running / exited / dead ...
    let description: String
    var user = false        // خدمة مستخدم (systemctl --user)

    var isRunning: Bool { active == "active" }
    var color: Color {
        switch active {
        case "active": return Theme.good
        case "failed": return Theme.bad
        case "activating", "reloading", "deactivating": return Theme.warn
        default: return .secondary
        }
    }
    var label: String {
        switch active {
        case "active": return sub == "running" ? "يعمل" : "نشِط (\(sub))"
        case "failed": return "متوقف بخطأ"
        case "inactive": return "متوقف"
        case "activating": return "يبدأ…"
        default: return active
        }
    }
}

struct ServicesView: View {
    @EnvironmentObject var pi: Pi
    @EnvironmentObject var store: DeviceStore

    @State private var services: [ServiceItem] = []
    @State private var showAll = false
    @State private var search = ""
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        List {
            Section { ConnectionBanner() }.listRowBackground(Color.clear)

            Section("نظام المواعيد") {
                TerminCard()
            }

            Section {
                Toggle("عرض كل الخدمات (وليس العاملة فقط)", isOn: $showAll)
            }

            Section(showAll ? "كل الخدمات" : "الخدمات العاملة") {
                if loading && services.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                ForEach(filtered) { s in
                    NavigationLink(value: s) {
                        HStack {
                            Circle().fill(s.color).frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name.replacingOccurrences(of: ".service", with: ""))
                                    .font(.body.monospaced())
                                    .environment(\.layoutDirection, .leftToRight)
                                if !s.description.isEmpty {
                                    Text(s.description).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            Text(s.label).font(.caption).foregroundColor(s.color)
                        }
                    }
                }
            }
        }
        .navigationTitle("الخدمات")
        .navigationDestination(for: ServiceItem.self) { ServiceDetailView(service: $0) }
        .searchable(text: $search, prompt: "ابحث عن خدمة")
        .refreshable { await load() }
        .task(id: "\(pi.state == .connected)-\(showAll)") { await load() }
        .errorAlert($error)
    }

    private var filtered: [ServiceItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return services }
        return services.filter { $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q) }
    }

    private func load() async {
        guard pi.isConnected else { return }
        loading = true
        defer { loading = false }
        let state = showAll ? "--all" : "--state=running"
        do {
            let out = try await pi.runOK(
                "systemctl list-units --type=service \(state) --no-legend --plain --no-pager"
            )
            services = Self.parse(out)
        } catch {
            self.error = Pi.describe(error)
        }
    }

    static func parse(_ out: String, user: Bool = false) -> [ServiceItem] {
        out.split(separator: "\n").compactMap { raw in
            let parts = raw.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 4, parts[0].hasSuffix(".service") else { return nil }
            return ServiceItem(name: parts[0], active: parts[2], sub: parts[3],
                               description: parts.count > 4 ? parts[4] : "", user: user)
        }
    }
}

// MARK: - بطاقة نظام المواعيد

struct TerminCard: View {
    @EnvironmentObject var pi: Pi
    @EnvironmentObject var store: DeviceStore

    @State private var status: ServiceItem?
    @State private var lastLog = ""
    @State private var detecting = false
    @State private var candidates: [String] = []
    @State private var error: String?
    @State private var busy = false

    private var serviceName: String { store.selected?.termService ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if serviceName.isEmpty {
                Text("لم تُحدَّد خدمة نظام المواعيد بعد.")
                    .foregroundColor(.secondary)
                Button {
                    Task { await detect() }
                } label: {
                    Label(detecting ? "جارٍ البحث…" : "ابحث عنها تلقائياً", systemImage: "magnifyingglass")
                }
                .disabled(detecting || !pi.isConnected)
                ForEach(candidates, id: \.self) { c in
                    Button {
                        setService(c)
                    } label: {
                        Label(c, systemImage: "checkmark.circle")
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
                if !detecting && candidates.isEmpty {
                    Text("أو اكتب اسمها في «المزيد ← الأجهزة».")
                        .font(.caption).foregroundColor(.secondary)
                }
            } else {
                HStack {
                    Image(systemName: "calendar.badge.clock")
                        .font(.title2).foregroundColor(Theme.accent)
                    VStack(alignment: .leading) {
                        Text(serviceName).font(.headline.monospaced())
                            .environment(\.layoutDirection, .leftToRight)
                        Text(status?.label ?? "…").foregroundColor(status?.color ?? .secondary)
                    }
                    Spacer()
                    if let status {
                        Circle().fill(status.color).frame(width: 12, height: 12)
                    }
                }
                if !lastLog.isEmpty {
                    Text(lastLog)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                        .environment(\.layoutDirection, .leftToRight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button { act("start") } label: { Label("تشغيل", systemImage: "play.fill") }
                    Spacer()
                    Button { act("restart") } label: { Label("إعادة", systemImage: "arrow.clockwise") }
                    Spacer()
                    Button(role: .destructive) { act("stop") } label: { Label("إيقاف", systemImage: "stop.fill") }
                }
                .buttonStyle(.bordered)
                .disabled(busy)
                if let s = status {
                    NavigationLink(value: s) { Label("السجل الكامل", systemImage: "doc.text.magnifyingglass") }
                }
            }
        }
        .padding(.vertical, 4)
        .task(id: "\(serviceName)-\(pi.state == .connected)") {
            guard !serviceName.isEmpty, pi.isConnected else { return }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
        .errorAlert($error)
    }

    /// يجرّب خدمة النظام أولاً ثم خدمة المستخدم.
    private func refresh() async {
        let n = serviceName.shellQuoted
        do {
            let sys = try await pi.run("systemctl show \(n) -p ActiveState -p SubState -p Description -p LoadState --no-pager")
            var item = Self.parseShow(sys.out, name: serviceName, user: false)
            if item?.active == nil || sys.out.contains("LoadState=not-found") {
                let usr = try await pi.run("systemctl --user show \(n) -p ActiveState -p SubState -p Description -p LoadState --no-pager")
                if !usr.out.contains("LoadState=not-found") {
                    item = Self.parseShow(usr.out, name: serviceName, user: true)
                }
            }
            status = item
            let flag = (item?.user ?? false) ? "--user" : ""
            let log = try await pi.run("journalctl \(flag) -u \(n) -n 3 --no-pager -o cat 2>/dev/null | tail -3")
            lastLog = log.out.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            // التحديث الدوري صامت
        }
    }

    static func parseShow(_ out: String, name: String, user: Bool) -> ServiceItem? {
        var d: [String: String] = [:]
        for l in out.split(separator: "\n") {
            let p = l.split(separator: "=", maxSplits: 1).map(String.init)
            if p.count == 2 { d[p[0]] = p[1] }
        }
        guard let a = d["ActiveState"] else { return nil }
        return ServiceItem(name: name, active: a, sub: d["SubState"] ?? "",
                           description: d["Description"] ?? "", user: user)
    }

    private func act(_ verb: String) {
        busy = true
        Task {
            defer { busy = false }
            do {
                if status?.user == true {
                    try await pi.runOK("systemctl --user \(verb) \(serviceName.shellQuoted)")
                } else {
                    try await pi.sudo("systemctl \(verb) \(serviceName.shellQuoted)")
                }
                try? await Task.sleep(nanoseconds: 800_000_000)
                await refresh()
            } catch {
                self.error = Pi.describe(error)
            }
        }
    }

    private func detect() async {
        detecting = true
        defer { detecting = false }
        let pattern = "termin|auslaender|auslander|appoint|aachen|monitor|playwright"
        let cmd = """
        { systemctl list-unit-files --type=service --no-legend --no-pager; \
          systemctl --user list-unit-files --type=service --no-legend --no-pager; } 2>/dev/null \
          | awk '{print $1}' | grep -iE '\(pattern)' | sort -u
        """
        do {
            let out = try await pi.run(cmd).out
            candidates = out.split(separator: "\n").map(String.init).filter { $0.hasSuffix(".service") }
            if candidates.isEmpty {
                error = "لم أجد خدمة باسم يشبه برنامج المواعيد. اكتب اسمها يدوياً في «المزيد ← الأجهزة»."
            }
        } catch {
            self.error = Pi.describe(error)
        }
    }

    private func setService(_ name: String) {
        guard var d = store.selected else { return }
        d.termService = name
        store.upsert(d, password: nil)
        candidates = []
    }
}

// MARK: - تفاصيل خدمة + السجل

struct ServiceDetailView: View {
    @EnvironmentObject var pi: Pi
    let service: ServiceItem

    @State private var status: ServiceItem?
    @State private var log = ""
    @State private var error: String?
    @State private var busy = false
    @State private var lines = 100

    var body: some View {
        List {
            Section {
                HStack {
                    Circle().fill((status ?? service).color).frame(width: 12, height: 12)
                    Text((status ?? service).label).font(.headline)
                    Spacer()
                    if busy { ProgressView() }
                }
                if !(status ?? service).description.isEmpty {
                    Text((status ?? service).description).foregroundColor(.secondary)
                }
            }
            Section {
                Button { act("start") } label: { Label("تشغيل", systemImage: "play.fill") }
                Button { act("restart") } label: { Label("إعادة تشغيل", systemImage: "arrow.clockwise") }
                Button(role: .destructive) { act("stop") } label: { Label("إيقاف", systemImage: "stop.fill") }
                Button { act("enable") } label: { Label("تشغيل تلقائي عند الإقلاع", systemImage: "bolt.badge.automatic") }
                Button { act("disable") } label: { Label("إلغاء التشغيل التلقائي", systemImage: "bolt.slash") }
            }
            .disabled(busy)
            Section {
                Picker("عدد الأسطر", selection: $lines) {
                    Text("50").tag(50); Text("100").tag(100); Text("300").tag(300)
                }
                .pickerStyle(.segmented)
                ScrollView(.horizontal) {
                    Text(log.isEmpty ? "…" : log)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .environment(\.layoutDirection, .leftToRight)
            } header: {
                Text("السجل")
            }
        }
        .navigationTitle(service.name.replacingOccurrences(of: ".service", with: ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: log) { Image(systemName: "square.and.arrow.up") }
        }
        .refreshable { await load() }
        .task(id: lines) { await load() }
        .errorAlert($error)
    }

    private var userFlag: String { service.user ? "--user " : "" }

    private func load() async {
        let n = service.name.shellQuoted
        do {
            let s = try await pi.run("systemctl \(userFlag)show \(n) -p ActiveState -p SubState -p Description --no-pager")
            status = TerminCard.parseShow(s.out, name: service.name, user: service.user)
            var out = try await pi.run("journalctl \(userFlag)-u \(n) -n \(lines) --no-pager 2>&1").out
            if out.contains("No journal files") || out.contains("insufficient permissions")
                || out.contains("Hint: You are currently not seeing") {
                out = (try? await pi.sudo("journalctl \(userFlag)-u \(n) -n \(lines) --no-pager")) ?? out
            }
            log = out
        } catch {
            self.error = Pi.describe(error)
        }
    }

    private func act(_ verb: String) {
        busy = true
        Task {
            defer { busy = false }
            do {
                if service.user {
                    try await pi.runOK("systemctl --user \(verb) \(service.name.shellQuoted)")
                } else {
                    try await pi.sudo("systemctl \(verb) \(service.name.shellQuoted)")
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
                await load()
            } catch {
                self.error = Pi.describe(error)
            }
        }
    }
}
