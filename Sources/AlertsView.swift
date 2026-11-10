import SwiftUI

/// تنبيهات تيليجرام تعمل على الـ Pi نفسه (cron كل 5 دقائق)،
/// فتصلك حتى لو كان الآيفون مطفأً أو التطبيق مغلقاً.
struct AlertsView: View {
    @EnvironmentObject var pi: Pi
    @EnvironmentObject var store: DeviceStore

    @AppStorage("alerts.bot") private var bot = ""
    @AppStorage("alerts.chat") private var chat = ""
    @AppStorage("alerts.temp") private var temp = 70
    @AppStorage("alerts.disk") private var disk = 90
    @AppStorage("alerts.services") private var services = ""
    @AppStorage("alerts.boot") private var bootMsg = true

    @State private var installed: Bool?
    @State private var busy = false
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: installed == true ? "bell.badge.fill" : "bell.slash")
                        .foregroundColor(installed == true ? Theme.good : .secondary)
                    Text(installed == nil ? "…" : (installed! ? "التنبيهات مفعّلة على الـ Pi" : "التنبيهات غير مفعّلة"))
                }
            } footer: {
                Text("يفحص الـ Pi نفسه كل 5 دقائق ويرسل لك رسالة عند المشكلة، ورسالة أخرى عند زوالها. يعمل حتى والآيفون مطفأ.")
            }

            Section {
                field("توكن البوت", text: $bot, placeholder: "123456:ABC-…")
                field("Chat ID", text: $chat, placeholder: "7859811941")
            } header: { Text("بوت تيليجرام") } footer: {
                Text("يمكنك استعمال نفس البوت الذي يرسل لك تنبيهات المواعيد.")
            }

            Section("متى أُنبَّه؟") {
                Stepper("الحرارة أعلى من \(temp)°", value: $temp, in: 55...85, step: 5)
                Stepper("القرص ممتلئ أكثر من \(disk)%", value: $disk, in: 70...98, step: 2)
                Toggle("رسالة عند كل إعادة تشغيل للـ Pi", isOn: $bootMsg)
                VStack(alignment: .leading, spacing: 4) {
                    Text("خدمات يجب أن تبقى تعمل (مفصولة بمسافة)")
                        .font(.caption).foregroundColor(.secondary)
                    TextField("termin.service", text: $services)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                }
                if let t = store.selected?.termService, !t.isEmpty, !services.contains(t) {
                    Button("إضافة خدمة المواعيد (\(t))") {
                        services = (services + " " + t).trimmingCharacters(in: .whitespaces)
                    }
                }
            }

            Section {
                Button {
                    Task { await install() }
                } label: {
                    Label(installed == true ? "حفظ التغييرات على الـ Pi" : "تفعيل التنبيهات", systemImage: "checkmark.seal")
                }
                .disabled(busy || bot.isEmpty || chat.isEmpty || !pi.isConnected)

                Button {
                    Task { await test() }
                } label: {
                    Label("إرسال رسالة تجريبية", systemImage: "paperplane")
                }
                .disabled(busy || installed != true)

                if installed == true {
                    Button(role: .destructive) {
                        Task { await uninstall() }
                    } label: {
                        Label("إيقاف التنبيهات", systemImage: "bell.slash")
                    }
                    .disabled(busy)
                }
                if busy { ProgressView() }
                if let message { Text(message).font(.footnote) }
            }
        }
        .navigationTitle("التنبيهات")
        .task(id: pi.state == .connected) { await check() }
        .errorAlert($error)
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            TextField(placeholder, text: text)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .environment(\.layoutDirection, .leftToRight)
        }
    }

    private func check() async {
        guard pi.isConnected else { return }
        let r = try? await pi.run("test -x ~/.salha-pi/alert.sh && crontab -l 2>/dev/null | grep -q salha-pi && echo yes")
        installed = r?.out.contains("yes") ?? false
    }

    private func install() async {
        busy = true
        defer { busy = false }
        message = nil
        let conf = """
        BOT=\(bot.trimmingCharacters(in: .whitespaces).shellQuoted)
        CHAT=\(chat.trimmingCharacters(in: .whitespaces).shellQuoted)
        TEMP=\(temp)
        DISK=\(disk)
        SERVICES=\(services.trimmingCharacters(in: .whitespaces).shellQuoted)
        """
        let script = Self.script
        let b64Script = Data(script.utf8).base64EncodedString()
        let b64Conf = Data(conf.utf8).base64EncodedString()
        let cron = bootMsg
            ? "@reboot sleep 60; $HOME/.salha-pi/alert.sh boot # salha-pi"
            : ""
        let cmd = """
        set -e
        mkdir -p ~/.salha-pi
        echo \(b64Script) | base64 -d > ~/.salha-pi/alert.sh
        echo \(b64Conf) | base64 -d > ~/.salha-pi/alert.conf
        chmod 700 ~/.salha-pi/alert.sh
        chmod 600 ~/.salha-pi/alert.conf
        command -v curl >/dev/null
        ( crontab -l 2>/dev/null | grep -v 'salha-pi' ; \
          echo "*/5 * * * * $HOME/.salha-pi/alert.sh # salha-pi" ; \
          [ -n \(cron.shellQuoted) ] && echo \(cron.shellQuoted) ) | crontab -
        echo ok
        """
        do {
            try await pi.runOK(cmd)
            installed = true
            message = "✅ تم التفعيل. ستصلك رسالة عند أي مشكلة."
        } catch {
            self.error = "تعذّر التفعيل: " + Pi.describe(error)
        }
    }

    private func test() async {
        busy = true
        defer { busy = false }
        do {
            try await pi.runOK("~/.salha-pi/alert.sh test")
            message = "📨 أُرسلت رسالة تجريبية — تفقّد تيليجرام."
        } catch {
            self.error = "فشل الإرسال — تأكد من التوكن والـ Chat ID.\n" + Pi.describe(error)
        }
    }

    private func uninstall() async {
        busy = true
        defer { busy = false }
        do {
            try await pi.runOK("crontab -l 2>/dev/null | grep -v 'salha-pi' | crontab - ; rm -rf ~/.salha-pi")
            installed = false
            message = "تم إيقاف التنبيهات."
        } catch {
            self.error = Pi.describe(error)
        }
    }

    /// السكربت الذي يعمل على الـ Pi. يتذكّر المشاكل المُبلَّغ عنها كي لا يكرر الرسالة كل 5 دقائق.
    static let script = #"""
    #!/bin/bash
    DIR="$HOME/.salha-pi"
    . "$DIR/alert.conf"
    STATE="$DIR/alert.state"
    touch "$STATE"
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    HOST="$(hostname)"

    send() {
      curl -s -m 20 "https://api.telegram.org/bot${BOT}/sendMessage" \
        --data-urlencode chat_id="$CHAT" \
        --data-urlencode text="🍓 ${HOST}
    $1" > /dev/null
    }

    # flag KEY BAD(0/1) "رسالة المشكلة" "رسالة الزوال"
    flag() {
      if [ "$2" = 1 ]; then
        grep -qx "$1" "$STATE" || { send "$3"; echo "$1" >> "$STATE"; }
      else
        if grep -qx "$1" "$STATE"; then
          sed -i "/^$1\$/d" "$STATE"
          send "✅ $4"
        fi
      fi
    }

    case "$1" in
      test) send "📨 رسالة تجريبية من صالحة Pi — التنبيهات تعمل."; exit $? ;;
      boot) send "🔄 أُعيد تشغيل الـ Pi وهو يعمل الآن." ;;
    esac

    T=$(( $(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0) / 1000 ))
    [ "$T" -ge "$TEMP" ] && B=1 || B=0
    flag temp $B "🌡️ الحرارة مرتفعة: ${T}°" "عادت الحرارة طبيعية: ${T}°"

    D=$(df / | awk 'NR==2{gsub("%","",$5); print $5}')
    [ "$D" -ge "$DISK" ] && B=1 || B=0
    flag disk $B "💾 القرص ممتلئ: ${D}%" "عادت مساحة القرص طبيعية: ${D}%"

    TH=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
    if [ -n "$TH" ]; then
      [ $(( TH & 0x1 )) -ne 0 ] && B=1 || B=0
      flag power $B "⚡️ الكهرباء ضعيفة — الشاحن لا يكفي" "عادت الكهرباء طبيعية"
    fi

    for S in $SERVICES; do
      A=$(systemctl is-active "$S" 2>/dev/null)
      if [ "$A" != "active" ]; then
        U=$(systemctl --user is-active "$S" 2>/dev/null)
        [ "$U" = "active" ] && A=active
      fi
      [ "$A" = "active" ] && B=0 || B=1
      flag "svc_$S" $B "⛔ الخدمة $S متوقفة" "الخدمة $S تعمل من جديد"
    done
    exit 0
    """#
}
