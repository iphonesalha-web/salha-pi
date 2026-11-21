import SwiftUI
import UniformTypeIdentifiers
import QuickLook
import AVKit
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
    @State private var previewURL: URL?
    @State private var videoURL: URL?
    @State private var job: Task<Void, Never>?

    var body: some View {
        List {
            if path == nil { Section { ConnectionBanner() }.listRowBackground(Color.clear) }
            if let progress {
                Section {
                    HStack {
                        ProgressView()
                        Text(progress).font(.subheadline)
                        Spacer()
                        if job != nil {
                            Button("إلغاء") { job?.cancel(); job = nil; self.progress = nil }
                                .font(.subheadline.bold())
                        }
                    }
                }
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
        .quickLookPreview($previewURL)
        .fullScreenCover(item: Binding(get: { videoURL.map { ShareItem(url: $0) } }, set: { videoURL = $0?.url })) { item in
            VideoPlayerScreen(url: item.url)
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
            Button { open(f) } label: { content }
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
        return ((path ?? resolved) as NSString).lastPathComponent
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
                Button { open(f) } label: { content }
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
                if FileKind.of(f.name) != .other {
                    Button { open(f) } label: { Label("عرض", systemImage: "eye") }
                }
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
                    // رابط رمزي (مثل HDD ← /mnt/hdd): نفتح المسار الحقيقي
                    let real = (try? await pi.run("readlink -f -- \(path.shellQuoted)"))?.out
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    resolved = real.hasPrefix("/") ? real : path
                } else {
                    resolved = try await pi.runOK("printf %s \"$HOME\"").trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            let list: [RemoteFile]
            do { list = try await listViaSFTP() }
            catch { list = try await listViaSSH() }
            files = list.sorted {
                if $0.isDir != $1.isDir { return $0.isDir }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        } catch {
            self.error = Pi.describe(error)
        }
    }

    private func listViaSFTP() async throws -> [RemoteFile] {
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
            return list
    }

    /// احتياط: قراءة المجلد عبر SSH (find) إن فشل SFTP لأي سبب.
    private func listViaSSH() async throws -> [RemoteFile] {
        let cmd = "find \(resolved.shellQuoted) -mindepth 1 -maxdepth 1 -printf '%T@\\t%s\\t%y\\t%Y\\t%f\\n'"
        let out = try await pi.runOK(cmd)
        var list: [RemoteFile] = []
        for line in out.split(separator: "\n") {
            let p = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard p.count == 5 else { continue }
            let kind = String(p[2])
            let target = String(p[3])
            let name = String(p[4])
            list.append(RemoteFile(
                name: name, path: join(name),
                isDir: kind == "d" || (kind == "l" && target == "d"),
                isLink: kind == "l",
                size: UInt64(p[1]) ?? 0,
                modified: Double(p[0]).map { Date(timeIntervalSince1970: $0) }
            ))
        }
        return list
    }

    private func join(_ name: String) -> String {
        resolved == "/" ? "/" + name : resolved + "/" + name
    }

    /// ضغطة على ملف: صور/PDF/نصوص → عارض الآيفون، فيديو/صوت → مشغّل، والباقي → مشاركة.
    private func open(_ f: RemoteFile) {
        let kind = FileKind.of(f.name)
        // صيغ لا يشغّلها الآيفون (mkv/webm…) → مشاركة، ومنها يمكن فتحها في VLC
        if kind == .other || kind == .unsupportedVideo {
            return download(f)
        }
        if kind != .media && f.size > 300 * 1024 * 1024 {
            return download(f)
        }
        job?.cancel()
        job = Task {
            do {
                let url = try await fetch(f)
                if Task.isCancelled { return }
                if kind == .media { videoURL = url } else { previewURL = url }
            } catch {
                if !Task.isCancelled { self.error = Pi.describe(error) }
            }
            job = nil
        }
    }

    private func download(_ f: RemoteFile) {
        job?.cancel()
        job = Task {
            do {
                let url = try await fetch(f)
                if !Task.isCancelled { shareURL = url }
            } catch {
                if !Task.isCancelled { self.error = Pi.describe(error) }
            }
            job = nil
        }
    }

    /// ينزّل الملف إلى ذاكرة مؤقتة على الآيفون (يُكتب للقرص مباشرة، لا للذاكرة)،
    /// ويعيد استعمال النسخة المنزّلة إن كانت نفس الحجم والتاريخ.
    private func fetch(_ f: RemoteFile) async throws -> URL {
        let dir = PreviewCache.dir(for: f)
        let url = dir.appendingPathComponent(f.name)
        if let a = try? FileManager.default.attributesOfItem(atPath: url.path),
           (a[.size] as? NSNumber)?.uint64Value == f.size, f.size > 0 {
            return url
        }
        PreviewCache.trim(keeping: f.size)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let part = url.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: part)
        FileManager.default.createFile(atPath: part.path, contents: nil)
        let out = try FileHandle(forWritingTo: part)
        defer { progress = nil }
        progress = "فتح \(f.name)…"
        do {
            let sftp = try await pi.openSFTP()
            defer { Task { try? await sftp.close() } }
            let file = try await sftp.openFile(filePath: f.path, flags: .read)
            var offset: UInt64 = 0
            let chunk: UInt32 = 1024 * 1024
            let started = Date()
            while true {
                try Task.checkCancellation()
                let buf = try await file.read(from: offset, length: chunk)
                if buf.readableBytes == 0 { break }
                try out.write(contentsOf: Data(buf.readableBytesView))
                offset += UInt64(buf.readableBytes)
                if f.size > 0 {
                    let pct = Int(Double(offset) / Double(f.size) * 100)
                    let speed = Double(offset) / max(Date().timeIntervalSince(started), 0.1)
                    progress = "\(f.name) — \(pct)% · \(Fmt.bytes(speed))/ث"
                }
                if f.size > 0 && offset >= f.size { break }
            }
            try? await file.close()
            try out.close()
        } catch {
            try? out.close()
            try? FileManager.default.removeItem(at: part)
            throw error
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: part, to: url)
        return url
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

enum FileKind {
    case media, unsupportedVideo, quickLook, other

    static func of(_ name: String) -> FileKind {
        switch (name as NSString).pathExtension.lowercased() {
        case "mp4", "mov", "m4v", "mp3", "m4a", "aac", "wav", "caf": return .media
        case "mkv", "webm", "avi", "flv", "wmv", "ts", "opus", "ogg", "flac": return .unsupportedVideo
        case "pdf", "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "tif", "tiff",
             "txt", "log", "md", "json", "csv", "conf", "yml", "yaml", "sh", "py", "html", "xml",
             "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "rtf", "usdz":
            return .quickLook
        default: return .other
        }
    }
}

/// ذاكرة مؤقتة للملفات المفتوحة — لا تتجاوز 2GB تقريباً.
enum PreviewCache {
    static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("preview")
    }

    /// مجلد خاص لكل ملف (حسب مساره) حتى لا يتصادم ملفان بنفس الاسم.
    static func dir(for f: RemoteFile) -> URL {
        var h: UInt64 = 1469598103934665603
        for b in f.path.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return root.appendingPathComponent(String(h, radix: 36))
    }

    static func trim(keeping incoming: UInt64, limit: UInt64 = 2 * 1024 * 1024 * 1024) {
        let fm = FileManager.default
        guard let items = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey]) else { return }
        var files: [(URL, UInt64, Date)] = []
        for case let u as URL in items {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey, .isRegularFileKey])
            guard v?.isRegularFile == true else { continue }
            files.append((u, UInt64(v?.fileSize ?? 0), v?.contentAccessDate ?? .distantPast))
        }
        var total = files.reduce(0) { $0 + $1.1 } + incoming
        for (u, size, _) in files.sorted(by: { $0.2 < $1.2 }) where total > limit {
            try? fm.removeItem(at: u.deletingLastPathComponent())
            total -= size
        }
    }
}

/// مشغّل فيديو/صوت بملء الشاشة (تقديم/تأخير، سرعة، صورة داخل صورة، AirPlay).
struct VideoPlayerScreen: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            PlayerController(url: url).ignoresSafeArea()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.largeTitle)
                    .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.5))
            }
            .padding(.top, 50).padding(.leading, 16)
        }
    }
}

struct PlayerController: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        let vc = AVPlayerViewController()
        vc.player = AVPlayer(url: url)
        vc.allowsPictureInPicturePlayback = true
        vc.player?.play()
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}
    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: ()) {
        vc.player?.pause()
    }
}
