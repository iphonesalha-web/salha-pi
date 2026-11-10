import Foundation
import Citadel
import NIOCore

/// الاتصال بالـ Pi عبر SSH. كل الشاشات تستعمل هذا الكائن الواحد.
@MainActor
final class Pi: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    struct CommandError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var device: Device?
    /// العنوان الذي نجح الاتصال به فعلاً (الأساسي أو الاحتياطي)
    @Published private(set) var connectedHost: String = ""

    private var client: SSHClient?
    private var password: String = ""

    var isConnected: Bool { state == .connected && (client?.isConnected ?? false) }

    // MARK: - الاتصال

    func connect(_ d: Device) async {
        await disconnect()
        device = d
        password = Keychain.get(d.id.uuidString) ?? ""
        guard !password.isEmpty else {
            state = .failed("لا توجد كلمة سر لهذا الجهاز. افتح «الأجهزة» وأدخلها.")
            return
        }
        state = .connecting
        var lastError = "تعذّر الوصول"
        for host in d.hosts {
            // pi.local → عنوان IP عبر Bonjour قبل الاتصال
            var target = host
            if host.lowercased().hasSuffix(".local") {
                if let ip = await LocalResolver.resolve(host, port: d.port) {
                    target = ip
                } else {
                    lastError = "لم يُعثر على \(host) في الشبكة. تأكد من: الإعدادات ← الخصوصية ← الشبكة المحلية ← صالحة Pi مفعّل. أو أضف العنوان الرقمي كعنوان احتياطي."
                    continue
                }
            }
            do {
                let c = try await SSHClient.connect(
                    host: target,
                    port: d.port,
                    authenticationMethod: .passwordBased(username: d.user, password: password),
                    hostKeyValidator: .acceptAnything(),
                    reconnect: .never,
                    connectTimeout: .seconds(8)
                )
                client = c
                connectedHost = host
                state = .connected
                return
            } catch {
                lastError = Self.describe(error) + "\n(\(target))"
            }
        }
        state = .failed(lastError)
    }

    func disconnect() async {
        if let c = client {
            try? await c.close()
        }
        client = nil
        if state == .connected { state = .idle }
    }

    /// يعيد الاتصال تلقائياً إن انقطع (مثلاً بعد رجوع التطبيق من الخلفية).
    private func ensureClient() async throws -> SSHClient {
        if let c = client, c.isConnected { return c }
        guard let d = device else { throw CommandError(message: "لم يُختر أي جهاز") }
        await connect(d)
        if let c = client, c.isConnected { return c }
        if case .failed(let m) = state { throw CommandError(message: m) }
        throw CommandError(message: "غير متصل")
    }

    // MARK: - الأوامر

    /// ينفّذ أمراً ويعيد ناتجه ورمز الخروج. stderr مدموج مع stdout.
    @discardableResult
    func run(_ command: String) async throws -> (out: String, code: Int) {
        let c = try await ensureClient()
        let wrapped = "{ \(command)\n} 2>&1; printf '\\n__RC=%s' \"$?\""
        let buffer = try await c.executeCommand(wrapped)
        let text = String(buffer: buffer)
        guard let r = text.range(of: "\n__RC=", options: .backwards) else {
            return (text, 0)
        }
        let out = String(text[..<r.lowerBound])
        let code = Int(text[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return (out, code)
    }

    /// مثل run لكن يرمي خطأً بنص الناتج إن فشل الأمر.
    @discardableResult
    func runOK(_ command: String) async throws -> String {
        let r = try await run(command)
        if r.code != 0 {
            let msg = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CommandError(message: msg.isEmpty ? "فشل الأمر (رمز \(r.code))" : msg)
        }
        return r.out
    }

    /// ينفّذ أمراً بصلاحيات root. يجرّب sudo بلا كلمة سر أولاً، ثم بكلمة سر المستخدم.
    @discardableResult
    func sudo(_ command: String) async throws -> String {
        let inner = "sh -c " + command.shellQuoted
        let direct = try await run("sudo -n " + inner)
        if direct.code == 0 { return direct.out }
        let withPass = "printf '%s\\n' \(password.shellQuoted) | sudo -S -p '' " + inner
        return try await runOK(withPass)
    }

    func openSFTP() async throws -> SFTPClient {
        let c = try await ensureClient()
        return try await c.openSFTP()
    }

    func sshClient() async throws -> SSHClient {
        try await ensureClient()
    }

    // MARK: - رسائل الأخطاء بالعربي

    static func describe(_ error: Error) -> String {
        let s = String(describing: error)
        if s.localizedCaseInsensitiveContains("auth") || s.contains("allAuthenticationOptionsFailed") {
            return "اسم المستخدم أو كلمة السر غير صحيحة."
        }
        if s.localizedCaseInsensitiveContains("timeout") || s.localizedCaseInsensitiveContains("timed out") {
            return "انتهت المهلة — هل الـ Pi يعمل وفي نفس الشبكة؟"
        }
        if s.localizedCaseInsensitiveContains("refused") {
            return "الـ Pi رفض الاتصال — هل SSH مفعّل؟"
        }
        if s.localizedCaseInsensitiveContains("resolve") || s.localizedCaseInsensitiveContains("unknown host")
            || s.localizedCaseInsensitiveContains("nodename") {
            return "لم يُعثر على العنوان. جرّب العنوان الرقمي (192.168.178.x) في إعدادات الجهاز."
        }
        if s.contains("PERMISSION_DENIED") || s.localizedCaseInsensitiveContains("permission denied") {
            return "لا تملك صلاحية لهذا المجلد أو الملف — هو خاص بالنظام (root)."
        }
        if s.contains("NO_SUCH_FILE") {
            return "الملف أو المجلد غير موجود."
        }
        if let e = error as? CommandError { return e.message }
        return "تعذّر الاتصال: " + s
    }
}
