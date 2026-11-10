import SwiftUI

struct MoreView: View {
    @EnvironmentObject var store: DeviceStore
    @EnvironmentObject var pi: Pi
    @State private var editing: Device?

    var body: some View {
        List {
            Section {
                NavigationLink { ProcessesView() } label: {
                    Label("العمليات", systemImage: "list.bullet.rectangle")
                }
                NavigationLink { AlertsView() } label: {
                    Label("تنبيهات تيليجرام", systemImage: "bell.badge")
                }
            }
            Section("الأجهزة") {
                ForEach(store.devices) { d in
                    Button {
                        store.selectedID = d.id
                    } label: {
                        HStack {
                            Image(systemName: d.id == store.selected?.id ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(d.id == store.selected?.id ? Theme.accent : .secondary)
                            VStack(alignment: .leading) {
                                Text(d.name).foregroundColor(.primary)
                                Text("\(d.user)@\(d.host)")
                                    .font(.caption.monospaced())
                                    .foregroundColor(.secondary)
                                    .environment(\.layoutDirection, .leftToRight)
                            }
                            Spacer()
                            Button { editing = d } label: {
                                Image(systemName: "info.circle").font(.title3)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .swipeActions {
                        Button { editing = d } label: { Label("تعديل", systemImage: "pencil") }
                    }
                }
                NavigationLink { DeviceEditView(device: Device(), isNew: true) } label: {
                    Label("إضافة جهاز", systemImage: "plus.circle")
                }
            }
            Section {
                HStack {
                    Text("الإصدار")
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("المزيد")
        .navigationDestination(item: $editing) { DeviceEditView(device: $0, isNew: false) }
    }
}

struct DeviceEditView: View {
    @EnvironmentObject var store: DeviceStore
    @EnvironmentObject var pi: Pi
    @Environment(\.dismiss) private var dismiss

    @State var device: Device
    let isNew: Bool
    @State private var password = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section {
                TextField("الاسم", text: $device.name)
            } header: { Text("الاسم") }

            Section {
                field("العنوان", text: $device.host, placeholder: "pi.local")
                field("عنوان احتياطي (اختياري)", text: $device.fallbackHost, placeholder: "192.168.178.40")
                HStack {
                    Text("المنفذ")
                    Spacer()
                    TextField("22", value: $device.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
            } header: { Text("الاتصال") } footer: {
                Text("العنوان الاحتياطي يُجرَّب إن لم يستجب الأول. تجده في الـ FRITZ!Box تحت Heimnetz ← Netzwerk.")
            }

            Section {
                field("اسم المستخدم", text: $device.user, placeholder: "nizar_salha")
                SecureField(isNew ? "كلمة السر" : "كلمة السر (اتركها فارغة لعدم تغييرها)", text: $password)
                    .textContentType(.password)
            } header: { Text("الدخول") } footer: {
                Text("كلمة السر تُحفظ في Keychain على هذا الآيفون فقط.")
            }

            Section {
                field("اسم الخدمة", text: $device.termService, placeholder: "termin.service")
            } header: { Text("نظام المواعيد") } footer: {
                Text("اختياري — يمكن البحث عنها تلقائياً من شاشة «الخدمات».")
            }

            Section {
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        Label("اختبار الاتصال", systemImage: "bolt.horizontal.circle")
                        if testing { Spacer(); ProgressView() }
                    }
                }
                .disabled(testing || device.host.isEmpty || device.user.isEmpty)
                if let testResult {
                    Text(testResult).font(.footnote)
                }
            }

            if !isNew {
                Section {
                    Button("حذف هذا الجهاز", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(isNew ? "جهاز جديد" : device.name)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("حفظ") { save() }
                    .disabled(device.host.isEmpty || device.user.isEmpty || (isNew && password.isEmpty))
            }
        }
        .confirmationDialog("حذف \(device.name)؟", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("حذف", role: .destructive) {
                store.remove(device)
                dismiss()
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .environment(\.layoutDirection, .leftToRight)
        }
    }

    private func save() {
        device.host = device.host.trimmingCharacters(in: .whitespaces)
        device.fallbackHost = device.fallbackHost.trimmingCharacters(in: .whitespaces)
        device.user = device.user.trimmingCharacters(in: .whitespaces)
        device.termService = device.termService.trimmingCharacters(in: .whitespaces)
        store.upsert(device, password: password.isEmpty ? nil : password)
        store.selectedID = device.id
        Task { await pi.connect(device) }
        if !isNew || store.devices.count > 1 { dismiss() }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        // نحفظ مؤقتاً لكي يجد الاتصال كلمة السر
        if !password.isEmpty { Keychain.set(password, for: device.id.uuidString) }
        let probe = Pi()
        await probe.connect(device)
        switch probe.state {
        case .connected:
            let name = (try? await probe.runOK("hostname"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            testResult = "✅ تم الاتصال بـ \(name) عبر \(probe.connectedHost)"
        case .failed(let m):
            testResult = "❌ \(m)"
        default:
            testResult = "❌ تعذّر الاتصال"
        }
        await probe.disconnect()
    }
}
