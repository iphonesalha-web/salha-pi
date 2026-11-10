import SwiftUI

struct ProcItem: Identifiable, Hashable {
    let id: Int        // PID
    let user: String
    let cpu: Double
    let mem: Double
    let command: String
}

struct ProcessesView: View {
    @EnvironmentObject var pi: Pi

    enum Sort: String, CaseIterable { case cpu = "المعالج", mem = "الذاكرة" }

    @State private var items: [ProcItem] = []
    @State private var sort: Sort = .cpu
    @State private var search = ""
    @State private var toKill: ProcItem?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Picker("الترتيب", selection: $sort) {
                    ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("\(filtered.count) عملية") {
                ForEach(filtered) { p in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.command)
                            .font(.subheadline.monospaced())
                            .lineLimit(2)
                            .environment(\.layoutDirection, .leftToRight)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 12) {
                            Text("PID \(p.id)")
                            Text(p.user)
                            Spacer()
                            Text(String(format: "CPU %.1f%%", p.cpu))
                                .foregroundColor(Theme.level(p.cpu, warn: 40, bad: 80))
                            Text(String(format: "RAM %.1f%%", p.mem))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .environment(\.layoutDirection, .leftToRight)
                    }
                    .swipeActions {
                        Button(role: .destructive) { toKill = p } label: { Label("إيقاف", systemImage: "xmark.octagon") }
                    }
                }
            }
        }
        .navigationTitle("العمليات")
        .searchable(text: $search, prompt: "ابحث باسم البرنامج")
        .refreshable { await load() }
        .task(id: sort) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
        .confirmationDialog("إيقاف العملية؟", isPresented: Binding(
            get: { toKill != nil }, set: { if !$0 { toKill = nil } }
        ), titleVisibility: .visible) {
            if let p = toKill {
                Button("إيقاف (SIGTERM)", role: .destructive) { kill(p, force: false) }
                Button("إيقاف بالقوة (SIGKILL)", role: .destructive) { kill(p, force: true) }
            }
        } message: {
            Text(toKill?.command ?? "")
        }
        .errorAlert($error)
    }

    private var filtered: [ProcItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? items : items.filter { $0.command.lowercased().contains(q) }
    }

    private func load() async {
        guard pi.isConnected else { return }
        let key = sort == .cpu ? "-%cpu" : "-%mem"
        do {
            let out = try await pi.runOK("ps -eo pid=,user=,%cpu=,%mem=,args= --sort=\(key) | head -60")
            items = out.split(separator: "\n").compactMap { line in
                let p = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true).map(String.init)
                guard p.count == 5, let pid = Int(p[0]) else { return nil }
                return ProcItem(id: pid, user: p[1], cpu: Double(p[2]) ?? 0, mem: Double(p[3]) ?? 0, command: p[4])
            }
        } catch {
            // صامت أثناء التحديث الدوري
        }
    }

    private func kill(_ p: ProcItem, force: Bool) {
        Task {
            let sig = force ? "-9" : "-15"
            do {
                let r = try await pi.run("kill \(sig) \(p.id)")
                if r.code != 0 { try await pi.sudo("kill \(sig) \(p.id)") }
                await load()
            } catch {
                self.error = Pi.describe(error)
            }
        }
    }
}
