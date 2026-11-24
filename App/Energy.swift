import AppKit
import Darwin

// MARK: - Per-component power (CPU / GPU / memory) from IOReport's "Energy Model" group.
// Private but stable API, readable without root; the same source powermetrics-style tools use.

@_silgen_name("IOReportCopyChannelsInGroup") private func IOReportCopyChannelsInGroup(_ g: CFString?, _ s: CFString?, _ a: UInt64, _ b: UInt64, _ c: UInt64) -> Unmanaged<CFMutableDictionary>?
@_silgen_name("IOReportCreateSubscription") private func IOReportCreateSubscription(_ a: UnsafeRawPointer?, _ ch: CFMutableDictionary, _ out: UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, _ id: UInt64, _ b: CFTypeRef?) -> OpaquePointer?
@_silgen_name("IOReportCreateSamples") private func IOReportCreateSamples(_ s: OpaquePointer?, _ ch: CFMutableDictionary?, _ a: CFTypeRef?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportCreateSamplesDelta") private func IOReportCreateSamplesDelta(_ a: CFDictionary, _ b: CFDictionary, _ c: CFTypeRef?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportChannelGetChannelName") private func IOReportChannelGetChannelName(_ c: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportChannelGetUnitLabel") private func IOReportChannelGetUnitLabel(_ c: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportSimpleGetIntegerValue") private func IOReportSimpleGetIntegerValue(_ c: CFDictionary, _ a: Int32) -> Int64

struct ComponentPower { var cpu = 0.0, gpu = 0.0, memory = 0.0 }

final class EnergySampler {
    private var channels: CFMutableDictionary?
    private var subscription: OpaquePointer?
    private var last: CFDictionary?
    private var lastTime = Date()

    init() {
        guard let ch = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return }
        var sub: Unmanaged<CFMutableDictionary>?
        subscription = IOReportCreateSubscription(nil, ch, &sub, 0, nil)
        channels = ch
        last = take()
    }

    private func take() -> CFDictionary? {
        guard let subscription, let channels else { return nil }
        return IOReportCreateSamples(subscription, channels, nil)?.takeRetainedValue()
    }

    /// Average watts per component since the previous call.
    func sample() -> ComponentPower? {
        guard let prev = last, let now = take() else { return nil }
        let t = Date(), dt = t.timeIntervalSince(lastTime)
        last = now; lastTime = t
        guard dt > 0.2, let delta = IOReportCreateSamplesDelta(prev, now, nil)?.takeRetainedValue() as NSDictionary?,
              let list = delta["IOReportChannels"] as? [NSDictionary] else { return nil }
        var p = ComponentPower()
        for c in list {
            let cd = c as CFDictionary
            guard let name = IOReportChannelGetChannelName(cd)?.takeUnretainedValue() as String? else { continue }
            let unit = (IOReportChannelGetUnitLabel(cd)?.takeUnretainedValue() as String?)?.trimmingCharacters(in: .whitespaces) ?? ""
            let scale: Double
            switch unit { case "mJ": scale = 1e-3; case "uJ", "µJ": scale = 1e-6; case "nJ": scale = 1e-9; default: continue }
            let watts = Double(IOReportSimpleGetIntegerValue(cd, 0)) * scale / dt
            switch name {
            case "CPU Energy": p.cpu += watts
            case "GPU Energy": p.gpu += watts
            case "DRAM": p.memory += watts
            default: break
            }
        }
        return p
    }
}

// MARK: - Apps using significant energy (same "energy impact" figure Activity Monitor shows)

struct AppUse: Identifiable {
    let id: String
    let name: String
    let icon: NSImage
    let impact: Double
}

enum AppEnergy {
    /// Blocks for about a second. Call off the main thread.
    static func sample(limit: Int = 4) -> [AppUse] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        p.arguments = ["-l", "2", "-s", "1", "-o", "power", "-stats", "pid,power", "-n", "40"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return [] }

        // Only the second sample is a real one-second measurement.
        let lines = out.components(separatedBy: "\n")
        guard let header = lines.lastIndex(where: { $0.hasPrefix("PID") }) else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier

        var totals: [String: (name: String, path: String, impact: Double)] = [:]
        for line in lines[(header + 1)...] {
            let f = line.split(separator: " ")
            guard f.count >= 2, let pid = Int32(f[0]), let power = Double(f[1]), power > 0, pid != me, pid != p.processIdentifier else { continue }
            var buf = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
            let path = String(cString: buf)
            // Roll helpers up into the app that owns them.
            var key = path, name = (path as NSString).lastPathComponent
            if let r = path.range(of: ".app/") {
                key = String(path[..<r.lowerBound]) + ".app"
                name = ((key as NSString).lastPathComponent as NSString).deletingPathExtension
            }
            if name == "top" || name == "Juice" { continue }
            totals[key, default: (name, key, 0)].impact += power
        }
        return totals.values.filter { $0.impact >= 1 }.sorted { $0.impact > $1.impact }.prefix(limit).map {
            AppUse(id: $0.path, name: $0.name, icon: NSWorkspace.shared.icon(forFile: $0.path), impact: $0.impact)
        }
    }
}
