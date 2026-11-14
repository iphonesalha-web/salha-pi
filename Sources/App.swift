import SwiftUI

@main
struct SalhaPiApp: App {
    @StateObject private var store = DeviceStore()
    @StateObject private var pi = Pi()
    @StateObject private var metrics = MetricsModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(pi)
                .environmentObject(metrics)
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "ar"))
                .tint(Theme.accent)
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.86, green: 0.16, blue: 0.36)
    static let good = Color.green
    static let warn = Color.orange
    static let bad = Color.red
    /// أزرق الأيقونات والقيم الطبيعية
    static let icon = Color(red: 0.36, green: 0.66, blue: 0.96)

    /// لون القيمة: أزرق طبيعي، برتقالي تحذير، أحمر خطر.
    static func value(_ v: Double, warn w: Double = 70, bad b: Double = 90) -> Color {
        v >= b ? bad : (v >= w ? warn : icon)
    }

    static func level(_ percent: Double, warn w: Double = 70, bad b: Double = 90) -> Color {
        percent >= b ? bad : (percent >= w ? warn : good)
    }
}

struct RootView: View {
    @EnvironmentObject var store: DeviceStore
    @EnvironmentObject var pi: Pi
    @EnvironmentObject var metrics: MetricsModel
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if store.devices.isEmpty {
                NavigationStack { DeviceEditView(device: Device(), isNew: true) }
            } else {
                MainTabs()
            }
        }
        .task(id: store.selectedID) {
            metrics.reset()
            if let d = store.selected { await pi.connect(d) }
        }
        .task(id: pi.state) {
            // القراءة الدورية للمقاييس طوال عمل التطبيق (للرئيسية والرسوم البيانية)
            if pi.state == .connected { await metrics.run(pi) }
        }
        .onChange(of: phase) { _, p in
            // عند الرجوع للتطبيق: إن انقطع الاتصال في الخلفية نعيده.
            if p == .active, let d = store.selected, !pi.isConnected, pi.state != .connecting {
                Task { await pi.connect(d) }
            }
        }
    }
}

struct MainTabs: View {
    var body: some View {
        NavigationStack { HomeView() }
    }
}

/// شريط حالة الاتصال — يظهر أعلى الشاشات حين لا يكون الاتصال سليماً.
struct ConnectionBanner: View {
    @EnvironmentObject var pi: Pi
    @EnvironmentObject var store: DeviceStore

    var body: some View {
        switch pi.state {
        case .connected:
            EmptyView()
        case .connecting, .idle:
            HStack(spacing: 10) {
                ProgressView()
                Text("جارٍ الاتصال بـ \(store.selected?.name ?? "الـ Pi")…")
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        case .failed(let msg):
            VStack(spacing: 8) {
                Label(msg, systemImage: "wifi.exclamationmark")
                    .font(.subheadline)
                    .foregroundColor(Theme.bad)
                    .multilineTextAlignment(.center)
                Button("إعادة المحاولة") {
                    if let d = store.selected { Task { await pi.connect(d) } }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
    }
}

/// تنبيه خطأ موحّد.
struct ErrorAlert: ViewModifier {
    @Binding var message: String?
    func body(content: Content) -> some View {
        content.alert("خطأ", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("حسناً", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }
}

extension View {
    func errorAlert(_ message: Binding<String?>) -> some View { modifier(ErrorAlert(message: message)) }
}
