import SwiftUI
import UniformTypeIdentifiers
import Citadel
import NIOCore

struct RemoteFile: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let isDir: Bool
    let isLink: Bool
    let size: UInt64
    let modified: Date?
}

/// مستعرض ملفات عبر SFTP. path = nil يعني مجلد المستخدم (home).
struct FilesView: View {
    @EnvironmentObject var pi: Pi
    let path: String?

    @State private var resolved: String = ""
    @State private var files: [RemoteFile] = []
    @State private var loading = false
    @State private var error: String?
    @State private var showHidden = false
    @State private var importing = false
    @State private var newFolder = false
    @State private var folderName = ""
    @State private var renaming: RemoteFile?
    @State private var newName = ""
    @State private var deleting: RemoteFile?
    @State private var progress: String?
    @State private var shareURL: URL?
    @State private var query = ""
    @State private var found: [RemoteFile] = []
    @State private var searching = false

    var body: some View {
        List {
            if path == nil { Section { ConnectionBanner() }.listRowBackground(Color.clear) }
            if let progress {
                Section { HStack { ProgressView(); Text(progress).font(.subheadline) } }
            }
            if isSearching {
                Section {
                    if searching && found.isEmpty {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if found.isEmpty {
                        Text("لا توجد نتائج").foregroundColor(.secondary)
                    }
                    ForEach(found) { f in
                        resultRow(f)
                    }
                } header: {
                    Text(found.count >= 200 ? "أول 200 نتيجة (الأحدث أولاً)" : "نتائج البحث: \(found.count) (الأحدث أولاً)")
                        .textCase(nil)
                }
            } else {
            Section {
                if loading && files.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if files.isEmpty && !loading {
                    Text("المجلد فارغ").foregroundColor(.secondary)
                }
                ForEach(visible) { f in
                    row(f)
                }
            } header: {
                Text(resolved)
                    .font(.caption.monospaced())
                    .environment(\.layoutDirection, .leftToRight)
                    .textCase(nil)
            }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "ابحث عن ملف (الاسم أو رقم الفاتورة)")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .task(id: query) { await search() }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(path == nil ? .large : .inline)
        .navigationDestination(for: RemoteFile.self) { FilesView(path: $0.path) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { importing = true } label: { Label("رفع ملف من الآيفون", systemImage: "square.and.arrow.up") }
                    Button { folderName = ""; newFolder = true } label: { Label("مجلد جديد", systemImage: "folder.badge.plus") }
                    Toggle(isOn: $showHidden) { Label("إظهار الملفات المخفية", systemImage: "eye") }
                    Button { Task { await load() } } label: { Label("تحديث", systemImage: "arrow.clockwise") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .refreshable { await load() }
        .task(id: pi.state == .connected) { await load() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { upload(urls) }
        }
        .alert("مجلد جديد", isPresented: $newFolder) {
            TextField("الاسم", text: $folderName)
            Button("إنشاء") { mkdir() }
            Button("إلغاء", role: .cancel) {}
        }
        .alert("إعادة تسمية", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("الاسم الجديد", text: $newName)
            Button("حفظ") { rename() }
            Button("إلغاء", role: .cancel) {}
        }
        .confirmationDialog("حذف \(deleting?.name ?? "")؟", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible) {
            Button("حذف نهائياً", role: .destructive) { delete() }
        } message: {
            Text(deleting?.isDir == true ? "سيُحذف المجلد وكل ما فيه." : "لا يمكن التراجع عن الحذف.")
        }
        .sheet(item: Binding(get: { shareURL.map { ShareItem(url: $0) } }, set: { shareURL = $0?.url })) { item in
            ShareSheet(url: item.url)
        }
        .errorAlert($error)
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// صف نتيجة بحث: الاسم كاملاً + المجلد الذي هو فيه
    @ViewBuilder
    private func resultRow(_ f: RemoteFile) -> some View {
        let parent = ((f.path as NSString).deletingLastPathComponent)
        let shown = parent.hasPrefix(resolved) ? String(parent.dropFirst(resolved.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : parent
        let content = HStack(spacing: 12) {
            Image(systemName: icon(f))
                .font(.title3)
                .foregroundColor(f.isDir ? Theme.accent : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.name).lineLimit(3).truncationMode(.middle)
                    .environment(\.layoutDirection, .leftToRight)
                Text(shown.isEmpty ? "." : shown)
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.head)
                    .environment(\.layoutDirection, .leftToRight)
                HStack(spacing: 8) {
                    if !f.isDir { Text(Fmt.bytes(Double(f.size))) }
                    if let d = f.modified { Text(d, style: .date) }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        if f.isDir {
            NavigationLink(value: f) { content }
        } else {
            Button { download(f) } label: { content }
                .foregroundColor(.primary)
        }
    }

    /// بحث بالاسم داخل هذا المجلد وكل ما تحته (عبر find على الـ Pi). عدة كلمات = كلها لازم تظهر في الاسم.
    private func search() async {
        let terms = query.split(whereSeparator: { $0 == " " }).map(String.init).filter { !$0.isEmpty }
        guard !terms.isEmpty, pi.isConnected, !resolved.isEmpty else {
            found = []; searching = false; return
        }
        searching = true
        // تأخير بسيط حتى لا نبحث مع كل حرف
        do { try await Task.sleep(nanoseconds: 450_000_000) } catch { return }
        let names = terms.map { "-iname " + ("*" + $0 + "*").shellQuoted }.joined(separator: " ")
        let cmd = "find \(resolved.shellQuoted) \\( -type f -o -type d \\) \(names) -printf '%T@\\t%s\\t%y\\t%p\\n' 2>/dev/null | sort -rn | head -200"
        do {
            let r = try await pi.run(cmd)
            if Task.isCancelled { return }
            var list: [RemoteFile] = []
            for line in r.out.split(separator: "\n") {
                let p = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
                guard p.count == 4 else { continue }
                let path = String(p[3])
                list.append(RemoteFile(
                    name: (path as NSString).lastPathComponent, path: path,
                    isDir: p[2] == "d", isLink: p[2] == "l",
                    size: UInt64(p[1]) ?? 0,
                    modified: Double(p[0]).map { Date(timeIntervalSince1970: $0) }
                ))
            }
            found = list
        } catch {
            if !Task.isCancelled { self.error = Pi.describe(error) }
        }
        searching = false
    }

    private var title: String {
        if path == nil { return "الملفات" }
        return (resolved as NSString).lastPathComponent
    }

    private var visible: [RemoteFile] {
        // lost+found مجلد نظام فارغ دائماً في أقراص ext4 — لا فائدة من إظهاره
        showHidden ? files : files.filter { !$0.name.hasPrefix(".") && $0.name != "lost+found" }
    }

    @ViewBuilder
    private func row(_ f: RemoteFile) -> some View {
        let content = HStack(spacing: 12) {
            Image(systemName: icon(f))
                .font(.title3)
                .foregroundColor(f.isDir ? Theme.accent : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.name).lineLimit(2).truncationMode(.middle)
                    .environment(\.layoutDirection, .leftToRight)
                HStack(spacing: 8) {
                    if !f.isDir { Text(Fmt.bytes(Double(f.size))) }
                    if let d = f.modified { Text(d, style: .date) }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        Group {
            if f.isDir {
                NavigationLink(value: f) { content }
            } else {
                Button { download(f) } label: { content }
                    .foregroundColor(.primary)
            }
        }
        .swipeActions {
            Button(role: .destructive) { deleting = f } label: { Label("حذف", systemImage: "trash") }
            Button { newName = f.name; renaming = f } label: { Label("تسمية", systemImage: "pencil") }
                .tint(.orange)
        }
        .contextMenu {
            if !f.isDir {
                Button { download(f) } label: { Label("تنزيل ومشاركة", systemImage: "square.and.arrow.down") }
            }
            Button { newName = f.name; renaming = f } label: { Label("إعادة تسمية", systemImage: "pencil") }
            Button { UIPasteboard.general.string = f.path } label: { Label("نسخ المسار", systemImage: "doc.on.doc") }
            Button(role: .destructive) { deleting = f } label: { Label("حذف", systemImage: "trash") }
        }
    }

    private func icon(_ f: RemoteFile) -> String {
        if f.isDir { return f.isLink ? "folder.badge.gearshape" : "folder.fill" }
        let ext = (f.name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "gif", "webp": return "photo"
        case "mp4", "mov", "mkv", "avi": return "film"
        case "mp3", "wav", "m4a", "flac": return "music.note"
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tar", "xz", "7z": return "doc.zipper"
        case "py", "sh", "js", "json", "yml", "yaml", "conf", "service", "txt", "log", "md", "html", "css": return "doc.text"
        default: return f.isLink ? "link" : "doc"
        }
    }

    // MARK: - العمليات

    private func load() async {
        guard pi.isConnected else { return }
        loading = true
        defer { loading = false }
        do {
            if resolved.isEmpty {
                if let path {
                    resolved = path
                } else {
                    resolved = try await pi.runOK("printf %s \"$HOME\"").trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            let sftp = try await pi.openSFTP()
            defer { Task { try? await sftp.close() } }
            let names = try await sftp.listDirectory(atPath: resolved)
            var list: [RemoteFile] = []
            for n in names {
                for c in n.components where c.filename != "." && c.filename != ".." {
                    let perm = c.attributes.permissions ?? 0
                    let type = perm & 0o170000
                    var isDir = type == 0o040000
                    let isLink = type == 0o120000 || c.longname.hasPrefix("l")
                    if isLink {
                        // رابط رمزي: نسأل عن الهدف لنعرف إن كان مجلداً
                        if let a = try? await sftp.getAttributes(at: join(c.filename)),
                           let p = a.permissions, p & 0o170000 == 0o040000 { isDir = true }
                    }
                    list.append(RemoteFile(
                        name: c.filename, path: join(c.filename), isDir: isDir, isLink: isLink,
                        size: c.attributes.size ?? 0,
                        modified: c.attributes.accessModificationTime?.modificationTime
                    ))
                }
            }
            files = list.sorted {
                if $0.isDir != $1.isDir { return $0.isDir }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        } catch {
            self.error = Pi.describe(error)
        }
    }

    private func join(_ name: String) -> String {
        resolved == "/" ? "/" + name : resolved + "/" + name
    }

    private func download(_ f: RemoteFile) {
        Task {
            progress = "تنزيل \(f.name)…"
            defer { progress = nil }
            do {
                let sftp = try await pi.openSFTP()
                defer { Task { try? await sftp.close() } }
                let file = try await sftp.openFile(filePath: f.path, flags: .read)
                var data = Data()
                var offset: UInt64 = 0
                let chunk: UInt32 = 256 * 1024
                while true {
                    let buf = try await file.read(from: offset, length: chunk)
                    if buf.readableBytes == 0 { break }
                    data.append(contentsOf: buf.readableBytesView)
                    offset += UInt64(buf.readableBytes)
                    if f.size > 0 {
                        progress = "تنزيل \(f.name)… \(Int(Double(offset) / Double(f.size) * 100))%"
                    }
                    if f.size > 0 && offset >= f.size { break }
                }
                try await file.close()
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(f.name)
                try? FileManager.default.removeItem(at: url)
                try data.write(to: url)
                shareURL = url
            } catch {
                self.error = Pi.describe(error)
            }
        }
    }

    private func upload(_ urls: [URL]) {
        Task {
            defer { progress = nil }
            do {
                let sftp = try await pi.openSFTP()
                defer { Task { try? await sftp.close() } }
                for url in urls {
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    let name = url.lastPathComponent
                    progress = "رفع \(name)…"
                    let file = try await sftp.openFile(filePath: join(name), flags: [.write, .create, .truncate])
                    var offset = 0
                    let chunk = 32 * 1024
                    while offset < data.count {
                        let end = min(offset + chunk, data.count)
                        try await file.write(ByteBuffer(bytes: data[offset..<end]), at: UInt64(offset))
                        offset = end
                        progress = "رفع \(name)… \(Int(Double(offset) / Double(max(data.count, 1)) * 100))%"
                    }
                    try await file.close()
                }
                await load()
            } catch {
                self.error = Pi.describe(error)
            }
        }
    }

    private func mkdir() {
        let name = folderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            do {
                let sftp = try await pi.openSFTP()
                defer { Task { try? await sftp.close() } }
                try await sftp.createDirectory(atPath: join(name))
                await load()
            } catch { self.error = Pi.describe(error) }
        }
    }

    private func rename() {
        guard let f = renaming else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != f.name else { return }
        Task {
            do {
                let sftp = try await pi.openSFTP()
                defer { Task { try? await sftp.close() } }
                try await sftp.rename(at: f.path, to: join(name))
                await load()
            } catch { self.error = Pi.describe(error) }
        }
    }

    private func delete() {
        guard let f = deleting else { return }
        Task {
            do {
                if f.isDir {
                    // SFTP لا يحذف مجلداً غير فارغ — نستعمل rm عبر SSH.
                    try await pi.runOK("rm -rf -- \(f.path.shellQuoted)")
                } else {
                    let sftp = try await pi.openSFTP()
                    defer { Task { try? await sftp.close() } }
                    try await sftp.remove(at: f.path)
                }
                await load()
            } catch { self.error = Pi.describe(error) }
        }
    }
}

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
