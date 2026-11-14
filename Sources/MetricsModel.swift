import SwiftUI

/// يقرأ حالة الـ Pi كل 3 ثوانٍ ويحتفظ بتاريخ قصير للرسوم البيانية.
/// كائن واحد للتطبيق كله، فتبقى الرسوم مستمرة أثناء التنقّل بين الشاشات.
@MainActor
final class MetricsModel: ObservableObject {
    struct Sample: Identifiable {
        let id = UUID()
        let t: Date
        let cpu: Double
        let temp: Double
        let mem: Double
        let rx: Double   // بايت/ثانية
        let tx: Double
    }

    @Published private(set) var m: Metrics?
    @Published private(set) var history: [Sample] = []
    @Published private(set) var rxRate: Double = 0
    @Published private(set) var txRate: Double = 0
    @Published private(set) var updated: Date?

    private var lastNet: (rx: Double, tx: Double, t: Date)?

    func reset() {
        m = nil
        history = []
        lastNet = nil
        rxRate = 0
        txRate = 0
        updated = nil
    }

    func load(_ pi: Pi) async {
        guard pi.isConnected else { return }
        guard let out = try? await pi.runOK(Metrics.command) else { return }
        let nm = Metrics.parse(out)
        let now = Date()
        if let l = lastNet {
            let dt = now.timeIntervalSince(l.t)
            if dt > 0, nm.rxBytes >= l.rx, nm.txBytes >= l.tx {
                rxRate = (nm.rxBytes - l.rx) / dt
                txRate = (nm.txBytes - l.tx) / dt
            }
        }
        lastNet = (nm.rxBytes, nm.txBytes, now)
        m = nm
        updated = now
        history.append(Sample(t: now, cpu: nm.cpuPercent, temp: nm.tempC ?? 0,
                              mem: nm.memUsedPercent, rx: rxRate, tx: txRate))
        if history.count > 200 { history.removeFirst(history.count - 200) }
    }

    func run(_ pi: Pi) async {
        while !Task.isCancelled {
            await load(pi)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }
}
