import Foundation
import Security

/// جهاز Raspberry Pi محفوظ في التطبيق. كلمة السر لا تُحفظ هنا بل في Keychain.
struct Device: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String = "Raspberry Pi"
    /// العنوان الأساسي — مثلاً pi.local
    var host: String = "pi.local"
    /// عنوان احتياطي رقمي — يُجرَّب إن لم يستجب الأول (مثلاً 192.168.178.40)
    var fallbackHost: String = ""
    var port: Int = 22
    var user: String = "nizar_salha"
    /// خدمة systemd لبرنامج المواعيد (اختياري)
    var termService: String = ""

    var hosts: [String] {
        [host, fallbackHost]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// قائمة الأجهزة + الجهاز المختار، محفوظة في UserDefaults.
final class DeviceStore: ObservableObject {
    @Published var devices: [Device] { didSet { save() } }
    @Published var selectedID: UUID? { didSet { save() } }

    private let key = "devices.v1"
    private let selKey = "devices.selected"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([Device].self, from: data) {
            devices = list
        } else {
            devices = []
        }
        if let s = UserDefaults.standard.string(forKey: selKey) {
            selectedID = UUID(uuidString: s)
        }
        if selectedID == nil { selectedID = devices.first?.id }
    }

    var selected: Device? {
        devices.first { $0.id == selectedID } ?? devices.first
    }

    func upsert(_ d: Device, password: String?) {
        if let i = devices.firstIndex(where: { $0.id == d.id }) {
            devices[i] = d
        } else {
            devices.append(d)
        }
        if let password, !password.isEmpty { Keychain.set(password, for: d.id.uuidString) }
        if selectedID == nil { selectedID = d.id }
    }

    func remove(_ d: Device) {
        devices.removeAll { $0.id == d.id }
        Keychain.delete(d.id.uuidString)
        if selectedID == d.id { selectedID = devices.first?.id }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: key)
        }
        UserDefaults.standard.set(selectedID?.uuidString, forKey: selKey)
    }
}

/// غلاف بسيط حول Keychain لحفظ كلمات السر.
enum Keychain {
    private static let service = "com.salha.pi"

    static func set(_ value: String, for account: String) {
        delete(account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

extension String {
    /// يضع النص بين علامتي ' آمنتين لاستخدامه في أوامر الـ shell.
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
