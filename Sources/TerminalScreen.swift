import SwiftUI
import UIKit
import SwiftTerm
import Citadel
import NIOCore
import NIOSSH

/// يربط عرض الطرفية (SwiftTerm) بجلسة PTY عبر SSH.
final class SSHTerminalSession: NSObject, TerminalViewDelegate {
    let view: TerminalView
    private var writer: TTYStdinWriter?
    private var task: Task<Void, Never>?
    var onClosed: (() -> Void)?

    override init() {
        let tv = TerminalView(frame: .zero, font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        view = tv
        super.init()
        tv.terminalDelegate = self
        tv.nativeBackgroundColor = .black
        tv.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
    }

    var isRunning: Bool { task != nil }

    @MainActor
    func start(pi: Pi) {
        guard task == nil else { return }
        view.feed(text: "جارٍ فتح الطرفية…\r\n")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let client = try await pi.sshClient()
                let t = await MainActor.run { self.view.getTerminal() }
                let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: max(t.cols, 40),
                    terminalRowHeight: max(t.rows, 12),
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: .init([:])
                )
                try await client.withPTY(request) { inbound, outbound in
                    self.writer = outbound
                    await MainActor.run { self.view.feed(text: "\u{1b}[2J\u{1b}[H") }
                    for try await chunk in inbound {
                        let buf: ByteBuffer
                        switch chunk {
                        case .stdout(let b): buf = b
                        case .stderr(let b): buf = b
                        }
                        let bytes = Array(buf.readableBytesView)
                        await MainActor.run { self.view.feed(byteArray: bytes[...]) }
                    }
                }
                await MainActor.run { self.view.feed(text: "\r\n[انتهت الجلسة]\r\n") }
            } catch is CancellationError {
            } catch {
                let msg = Pi.describe(error)
                await MainActor.run { self.view.feed(text: "\r\n[خطأ] \(msg)\r\n") }
            }
            self.writer = nil
            await MainActor.run {
                self.task = nil
                self.onClosed?()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        writer = nil
    }

    func send(text: String) {
        send(bytes: Array(text.utf8))
    }

    func send(bytes: [UInt8]) {
        guard let writer else { return }
        Task { try? await writer.write(ByteBuffer(bytes: bytes)) }
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        send(bytes: Array(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let writer, newCols > 0, newRows > 0 else { return }
        Task { try? await writer.changeSize(cols: newCols, rows: newRows, pixelWidth: 0, pixelHeight: 0) }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { UIApplication.shared.open(url) }
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) { UIPasteboard.general.string = s }
    }
}

struct TerminalHost: UIViewRepresentable {
    let session: SSHTerminalSession
    func makeUIView(context: Context) -> TerminalView { session.view }
    func updateUIView(_ uiView: TerminalView, context: Context) {}
}

/// أوامر سريعة تحت الطرفية.
struct QuickCommand: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var command: String

    static let defaults: [QuickCommand] = [
        .init(title: "htop", command: "htop"),
        .init(title: "المساحة", command: "df -h"),
        .init(title: "الحرارة", command: "vcgencmd measure_temp"),
        .init(title: "الملفات", command: "ls -la"),
        .init(title: "تحديث النظام", command: "sudo apt update && sudo apt upgrade -y"),
        .init(title: "سجل النظام", command: "journalctl -n 50 --no-pager"),
    ]
}

struct TerminalScreen: View {
    @EnvironmentObject var pi: Pi
    @StateObject private var holder = SessionHolder()
    @AppStorage("quick.commands") private var quickData: Data = Data()
    @State private var editing = false

    final class SessionHolder: ObservableObject {
        let session = SSHTerminalSession()
        @Published var running = false
    }

    private var quick: [QuickCommand] {
        (try? JSONDecoder().decode([QuickCommand].self, from: quickData)) ?? QuickCommand.defaults
    }

    var body: some View {
        VStack(spacing: 0) {
            if pi.state != .connected {
                ConnectionBanner().padding()
            }
            TerminalHost(session: holder.session)
                .background(Color.black)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    key("Ctrl+C", [3])
                    key("Tab", [9])
                    key("Esc", [27])
                    key("↑", [27, 91, 65])
                    key("↓", [27, 91, 66])
                    ForEach(quick) { q in
                        Button(q.title) { holder.session.send(text: q.command + "\n") }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
        .environment(\.layoutDirection, .leftToRight)
        .navigationTitle("الطرفية")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { restart() } label: { Label("جلسة جديدة", systemImage: "arrow.clockwise") }
                    Button { editing = true } label: { Label("تعديل الأوامر السريعة", systemImage: "slider.horizontal.3") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $editing) {
            QuickCommandsEditor(data: $quickData, initial: quick)
                .environment(\.layoutDirection, .rightToLeft)
        }
        .task(id: pi.state == .connected) {
            if pi.state == .connected && !holder.session.isRunning {
                holder.session.start(pi: pi)
            }
        }
    }

    private func key(_ title: String, _ bytes: [UInt8]) -> some View {
        Button(title) { holder.session.send(bytes: bytes) }
            .buttonStyle(.borderedProminent)
            .font(.caption.monospaced())
    }

    private func restart() {
        holder.session.stop()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            holder.session.start(pi: pi)
        }
    }
}

struct QuickCommandsEditor: View {
    @Binding var data: Data
    @State var items: [QuickCommand]
    @Environment(\.dismiss) private var dismiss

    init(data: Binding<Data>, initial: [QuickCommand]) {
        _data = data
        _items = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach($items) { $q in
                    VStack(alignment: .leading) {
                        TextField("الاسم", text: $q.title)
                        TextField("الأمر", text: $q.command)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
                .onDelete { items.remove(atOffsets: $0) }
                .onMove { items.move(fromOffsets: $0, toOffset: $1) }
                Button { items.append(.init(title: "أمر جديد", command: "")) } label: {
                    Label("إضافة أمر", systemImage: "plus")
                }
                Button("استعادة الأوامر الافتراضية") { items = QuickCommand.defaults }
            }
            .navigationTitle("الأوامر السريعة")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ") {
                        data = (try? JSONEncoder().encode(items)) ?? Data()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) { EditButton() }
            }
        }
    }
}
