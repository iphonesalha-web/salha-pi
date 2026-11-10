import Foundation

/// لقطة من حالة الـ Pi — تُقرأ بأمر واحد كل بضع ثوانٍ.
struct Metrics: Equatable {
    var hostname = ""
    var ip = ""
    var tempC: Double?
    var cpuPercent: Double = 0
    var memTotal: Double = 0      // بايت
    var memAvailable: Double = 0  // بايت
    var diskTotal: Double = 0
    var diskUsed: Double = 0
    var uptime: TimeInterval = 0
    var load: [Double] = []
    var throttled: String = ""
    var model = ""
    var os = ""

    var memUsedPercent: Double { memTotal > 0 ? (memTotal - memAvailable) / memTotal * 100 : 0 }
    var diskPercent: Double { diskTotal > 0 ? diskUsed / diskTotal * 100 : 0 }

    /// 0x0 = لا مشاكل. غير ذلك = ضعف كهرباء أو حرارة (حسب vcgencmd).
    var powerWarning: String? {
        guard let v = throttled.split(separator: "=").last.map(String.init),
              let n = Int(v.replacingOccurrences(of: "0x", with: ""), radix: 16), n != 0 else { return nil }
        if n & 0x1 != 0 { return "⚡️ الكهرباء ضعيفة الآن — استعمل شاحناً أقوى (5V 3A)" }
        if n & 0x4 != 0 { return "🔥 المعالج مُبطّأ الآن بسبب الحرارة" }
        if n & 0x10000 != 0 { return "⚡️ حصل ضعف في الكهرباء منذ آخر تشغيل" }
        if n & 0x40000 != 0 { return "🔥 حصل تبطيء بسبب الحرارة منذ آخر تشغيل" }
        return nil
    }

    /// الأمر الذي يطبع كل القيم، سطراً لكل قيمة وبنفس الترتيب الذي يقرؤه parse.
    static let command = """
    cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo NA
    head -1 /proc/stat
    sleep 0.5
    head -1 /proc/stat
    free -b | awk 'NR==2{print $2, $7}'
    df -B1 / | awk 'NR==2{print $2, $3}'
    cut -d' ' -f1 /proc/uptime
    cut -d' ' -f1-3 /proc/loadavg
    hostname
    hostname -I 2>/dev/null | awk '{print $1}'
    vcgencmd get_throttled 2>/dev/null || echo throttled=NA
    tr -d '\\0' < /proc/device-tree/model 2>/dev/null; echo
    . /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"
    """

    static func parse(_ text: String) -> Metrics {
        let l = text.components(separatedBy: "\n")
        func line(_ i: Int) -> String { i < l.count ? l[i].trimmingCharacters(in: .whitespaces) : "" }
        var m = Metrics()
        if let t = Double(line(0)) { m.tempC = t / 1000 }
        // ملاحظة: `sleep` لا يطبع سطراً، فالقراءة الثانية لـ /proc/stat في السطر 2 مباشرة.
        m.cpuPercent = cpu(line(1), line(2))
        let mem = line(3).split(separator: " ").compactMap { Double($0) }
        if mem.count == 2 { m.memTotal = mem[0]; m.memAvailable = mem[1] }
        let disk = line(4).split(separator: " ").compactMap { Double($0) }
        if disk.count == 2 { m.diskTotal = disk[0]; m.diskUsed = disk[1] }
        m.uptime = Double(line(5)) ?? 0
        m.load = line(6).split(separator: " ").compactMap { Double($0) }
        m.hostname = line(7)
        m.ip = line(8)
        m.throttled = line(9)
        m.model = line(10)
        m.os = line(11)
        return m
    }

    /// نسبة استعمال المعالج من قراءتين لـ /proc/stat.
    private static func cpu(_ a: String, _ b: String) -> Double {
        func parts(_ s: String) -> [Double] {
            s.split(separator: " ").dropFirst().compactMap { Double($0) }
        }
        let x = parts(a), y = parts(b)
        guard x.count >= 4, y.count >= 4 else { return 0 }
        let idleX = x[3] + (x.count > 4 ? x[4] : 0)
        let idleY = y[3] + (y.count > 4 ? y[4] : 0)
        let totalX = x.reduce(0, +), totalY = y.reduce(0, +)
        let dt = totalY - totalX
        guard dt > 0 else { return 0 }
        return max(0, min(100, (1 - (idleY - idleX) / dt) * 100))
    }
}

enum Fmt {
    static func bytes(_ b: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .binary)
    }

    static func uptime(_ s: TimeInterval) -> String {
        let d = Int(s) / 86400, h = (Int(s) % 86400) / 3600, m = (Int(s) % 3600) / 60
        if d > 0 { return "\(d) يوم \(h) ساعة" }
        if h > 0 { return "\(h) ساعة \(m) دقيقة" }
        return "\(m) دقيقة"
    }
}
