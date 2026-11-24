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

struct ComponentPower {
    var cpu = 0.0, gpu = 0.0, memory = 0.0
    // Smaller rails that live inside "Display & other".
    var displayController = 0.0, memoryController = 0.0, neuralEngine = 0.0, mediaEngines = 0.0
}

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
            case "DISP", "DISPEXT": p.displayController += watts
            case "AMCC", "DCS": p.memoryController += watts
            case "ISP", "AVE", "MSR": p.mediaEngines += watts
            default: if name.hasPrefix("ANE") { p.neuralEngine += watts }
            }
        }
        return p
    }
}

// MARK: - Per-app CPU, memory and energy impact (the same figures Activity Monitor shows)

struct AppUse: Identifiable {
    let id: String          // bundle or executable path
    let name: String
    let icon: NSImage
    var impact = 0.0        // energy impact
    var cpu = 0.0           // percent of one core
    var memory = 0.0        // bytes
    var pids: [pid_t] = []
    let isApp: Bool
    var canQuit = false
}

enum AppEnergy {
    private static func bytes(_ s: Substring) -> Double {
        var t = s
        while let l = t.last, l == "+" || l == "-" { t = t.dropLast() }
        guard let unit = t.last, let v = Double(t.dropLast()) else { return Double(t) ?? 0 }
        switch unit { case "K": return v * 1024; case "M": return v * 1_048_576; case "G": return v * 1_073_741_824; case "B": return v; default: return 0 }
    }

    /// Blocks for about a second. Call off the main thread.
    static func sample() -> [AppUse] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        p.arguments = ["-l", "2", "-s", "1", "-stats", "pid,cpu,mem,power"]
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
        let system = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/"]

        var totals: [String: AppUse] = [:]
        for line in lines[(header + 1)...] {
            let f = line.split(separator: " ")
            guard f.count >= 4, let pid = Int32(f[0]), let cpu = Double(f[1]), let power = Double(f[3]),
                  pid != me, pid != p.processIdentifier else { continue }
            var buf = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
            let path = String(cString: buf)
            // Roll helpers up into the app that owns them.
            var key = path, name = (path as NSString).lastPathComponent, isApp = false
            if let r = path.range(of: ".app/") {
                key = String(path[..<r.lowerBound]) + ".app"
                name = ((key as NSString).lastPathComponent as NSString).deletingPathExtension
                isApp = true
            }
            if name == "top" || name == "Juice" { continue }
            var e = totals[key] ?? AppUse(id: key, name: name, icon: NSImage(), isApp: isApp)
            e.impact += power; e.cpu += cpu; e.memory += bytes(f[2]); e.pids.append(pid)
            totals[key] = e
        }
        // Keep anything that matters on any of the three measures; icons only for those.
        let all = Array(totals.values)
        var keep = Set<String>()
        for sorted in [all.sorted { $0.impact > $1.impact }, all.sorted { $0.cpu > $1.cpu }, all.sorted { $0.memory > $1.memory }] {
            sorted.prefix(8).forEach { keep.insert($0.id) }
        }
        return all.filter { keep.contains($0.id) }.map { e in
            // Only offer Quit for the user's own, non-system processes.
            let mine = e.pids.allSatisfy { kill($0, 0) == 0 }
            var out = AppUse(id: e.id, name: e.name, icon: NSWorkspace.shared.icon(forFile: e.id), isApp: e.isApp)
            out.impact = e.impact; out.cpu = e.cpu; out.memory = e.memory; out.pids = e.pids
            out.canQuit = mine && !system.contains { e.id.hasPrefix($0) }
            return out
        }
    }

    /// Quit: apps get a normal quit (so they can ask about unsaved work), bare processes get SIGTERM.
    /// Force quit: killed immediately.
    static func quit(_ app: AppUse, force: Bool) {
        if app.isApp {
            let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == app.id }
            if !running.isEmpty {
                running.forEach { _ = force ? $0.forceTerminate() : $0.terminate() }
                if force { app.pids.forEach { kill($0, SIGKILL) } }
                return
            }
        }
        app.pids.forEach { kill($0, force ? SIGKILL : SIGTERM) }
    }
}
