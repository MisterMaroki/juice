import SwiftUI
import IOKit
import ServiceManagement

let helperPath = "/usr/local/libexec/juice-helper"
let limitFile = "/Library/Application Support/Juice/limit"

// MARK: - Model

@MainActor
final class Power: ObservableObject {
    @Published var percent = 0
    @Published var onAC = false
    @Published var charging = false
    @Published var batteryW = 0.0      // + charging, - discharging
    @Published var systemW = 0.0
    @Published var adapterW = 0.0      // power delivered by the adapter into the Mac
    @Published var lossW = 0.0         // adapter conversion loss
    @Published var mode = 0            // 0 auto, 1 low, 2 high
    @Published var limit = 100
    @Published var helperInstalled = FileManager.default.fileExists(atPath: helperPath)
    @Published var error: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var timer: Timer?
    private var ticks = 0

    init() {
        refresh(); readMode(); readLimit()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        refresh()
        ticks += 1
        if ticks % 5 == 0 { readMode(); readLimit() }
    }

    func refresh() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return }

        func num(_ k: String, _ dict: [String: Any] = d) -> Double? {
            (dict[k] as? NSNumber).map { Double($0.int64Value) }
        }
        let cur = num("CurrentCapacity") ?? 0, max = num("MaxCapacity") ?? 100
        percent = Int((cur / Swift.max(max, 1) * 100).rounded())
        onAC = (d["ExternalConnected"] as? Bool) ?? false
        charging = (d["IsCharging"] as? Bool) ?? false

        let volts = (num("Voltage") ?? 0) / 1000
        let amps = (num("Amperage") ?? 0) / 1000
        let batt = volts * amps
        batteryW = abs(batt) < 0.05 ? 0 : batt

        let tel = d["PowerTelemetryData"] as? [String: Any] ?? [:]
        if onAC {
            let charge = Swift.max(batteryW, 0), discharge = Swift.max(-batteryW, 0)
            if let inW = num("SystemPowerIn", tel).map({ $0 / 1000 }), inW > 0 {
                adapterW = inW
                systemW = num("SystemLoad", tel).map { $0 / 1000 } ?? Swift.max(inW - charge + discharge, 0)
            } else {
                systemW = num("SystemLoad", tel).map { $0 / 1000 } ?? 0
                adapterW = systemW + charge - discharge
            }
            lossW = num("AdapterEfficiencyLoss", tel).map { $0 / 1000 } ?? 0
        } else {
            adapterW = 0; lossW = 0
            systemW = Swift.max(-batteryW, 0)
        }
    }

    func readMode() {
        guard let out = run("/usr/bin/pmset", ["-g"]).out else { return }
        for line in out.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "powermode", let v = Int(parts[1]) { mode = v; return }
        }
    }

    func readLimit() {
        let s = (try? String(contentsOfFile: limitFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        limit = s.flatMap(Int.init) ?? 100
        helperInstalled = FileManager.default.fileExists(atPath: helperPath)
    }

    func setMode(_ m: Int) {
        let prev = mode
        mode = m
        let r = run("/usr/bin/sudo", ["-n", helperPath, "powermode", String(m)])
        if r.status != 0 { mode = prev; error = "Couldn't change power mode. Reinstall the helper." }
        else { error = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.readMode() }
    }

    func setLimit(_ v: Int) {
        let r = run("/usr/bin/sudo", ["-n", helperPath, "setlimit", String(v)])
        if r.status != 0 { error = "Couldn't set the charge limit. Reinstall the helper." }
        else { error = nil; limit = v }
    }

    func installHelper() {
        guard let res = Bundle.main.resourcePath else { return }
        let script = "\(res)/install-helper.sh"
        let cmd = "/bin/sh \(quoted(script)) \(quoted(res)) \(quoted(NSUserName()))"
        let apple = "do shell script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: apple)?.executeAndReturnError(&err)
        if let err, (err[NSAppleScript.errorNumber] as? Int) != -128 {
            error = "Install failed: \(err[NSAppleScript.errorMessage] ?? "unknown")"
        }
        readLimit(); readMode()
    }

    func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { self.error = "Launch at login: \(error.localizedDescription)" }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var statusText: String {
        if !onAC { return String(format: "On battery · %.1f W", systemW) }
        if charging { return String(format: "Charging · %.1f W in", Swift.max(batteryW, 0)) }
        if limit < 100 && percent >= limit - 3 { return "Held at \(limit)% limit" }
        if percent >= 99 { return "Charged" }
        return "Plugged in · not charging"
    }

    var statusImage: NSImage {
        StatusIcon.make(percent: percent, charging: charging, pluggedIn: onAC, mode: mode)
    }
}

private func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

@discardableResult
private func run(_ path: String, _ args: [String]) -> (status: Int32, out: String?) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return (-1, nil) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8))
}

// MARK: - Sankey

struct Flow { let from: Int; let to: Int; let watts: Double }
struct Node { let name: String; let color: Color }

struct Sankey: View {
    let sources: [Node]
    let sinks: [Node]
    let flows: [Flow]

    var body: some View {
        Canvas { ctx, size in
            let barW: CGFloat = 8, gap: CGFloat = 10
            let total = flows.reduce(0) { $0 + $1.watts }
            guard total > 0.05 else {
                ctx.draw(Text("Idle").font(.caption).foregroundStyle(.secondary), at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            func totals(_ count: Int, _ key: (Flow) -> Int) -> [Double] {
                (0..<count).map { i in flows.filter { key($0) == i }.reduce(0) { $0 + $1.watts } }
            }
            let srcT = totals(sources.count, { $0.from }), snkT = totals(sinks.count, { $0.to })
            func layout(_ t: [Double]) -> [CGRect] {
                let visible = t.filter { $0 > 0.05 }.count
                let scale = (size.height - gap * CGFloat(max(visible - 1, 0))) / total
                var y: CGFloat = 0
                return t.map { w in
                    guard w > 0.05 else { return .zero }
                    let h = max(CGFloat(w) * scale, 2)
                    defer { y += h + gap }
                    return CGRect(x: 0, y: y, width: barW, height: h)
                }
            }
            let srcR = layout(srcT)
            let snkR = layout(snkT).map { $0.offsetBy(dx: size.width - barW, dy: 0) }
            let scaleS = srcR.indices.map { srcT[$0] > 0 ? srcR[$0].height / CGFloat(srcT[$0]) : 0 }
            let scaleT = snkR.indices.map { snkT[$0] > 0 ? snkR[$0].height / CGFloat(snkT[$0]) : 0 }
            var srcOff = srcR.map { $0.minY }, snkOff = snkR.map { $0.minY }

            for f in flows where f.watts > 0.05 {
                let h0 = CGFloat(f.watts) * scaleS[f.from], h1 = CGFloat(f.watts) * scaleT[f.to]
                let x0 = barW, x1 = size.width - barW, mid = (x0 + x1) / 2
                let a = srcOff[f.from], b = snkOff[f.to]
                var p = Path()
                p.move(to: CGPoint(x: x0, y: a))
                p.addCurve(to: CGPoint(x: x1, y: b), control1: CGPoint(x: mid, y: a), control2: CGPoint(x: mid, y: b))
                p.addLine(to: CGPoint(x: x1, y: b + h1))
                p.addCurve(to: CGPoint(x: x0, y: a + h0), control1: CGPoint(x: mid, y: b + h1), control2: CGPoint(x: mid, y: a + h0))
                p.closeSubpath()
                ctx.fill(p, with: .linearGradient(
                    Gradient(colors: [sources[f.from].color.opacity(0.45), sinks[f.to].color.opacity(0.45)]),
                    startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x1, y: 0)))
                srcOff[f.from] += h0; snkOff[f.to] += h1
            }

            func label(_ n: Node, _ w: Double, _ r: CGRect, leading: Bool) {
                guard w > 0.05 else { return }
                ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(n.color))
                let t = Text("\(n.name)  \(String(format: "%.1f W", w))").font(.system(size: 10, weight: .semibold))
                let pt = CGPoint(x: leading ? r.maxX + 5 : r.minX - 5, y: r.midY)
                ctx.draw(t, at: pt, anchor: leading ? .leading : .trailing)
            }
            for i in sources.indices { label(sources[i], srcT[i], srcR[i], leading: true) }
            for i in sinks.indices { label(sinks[i], snkT[i], snkR[i], leading: false) }
        }
    }
}

// MARK: - UI

struct PanelView: View {
    @ObservedObject var p: Power
    @State private var sliderLimit = 80.0
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(p.percent)%").font(.system(size: 28, weight: .bold, design: .rounded))
                Text(p.statusText).font(.callout).foregroundStyle(.secondary)
                Spacer()
            }

            if !p.helperInstalled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Juice needs a small helper to change power modes and limit charging.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Install helper…") { p.installHelper() }.buttonStyle(.borderedProminent)
                }
            }

            section("Power mode") {
                Picker("", selection: Binding(get: { p.mode }, set: { p.setMode($0) })) {
                    Label("Low", systemImage: "leaf.fill").tag(1)
                    Label("Auto", systemImage: "gauge.with.dots.needle.50percent").tag(0)
                    Label("High", systemImage: "bolt.fill").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden()
                .disabled(!p.helperInstalled)
            }

            section("Charge limit") {
                HStack {
                    Toggle("", isOn: Binding(
                        get: { p.limit < 100 },
                        set: { p.setLimit($0 ? Int(sliderLimit < 100 ? sliderLimit : 80) : 100) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    Slider(value: $sliderLimit, in: 50...95, step: 5) { e in
                        editing = e
                        if !e { p.setLimit(Int(sliderLimit)) }
                    }
                    .disabled(p.limit >= 100)
                    Text(p.limit < 100 ? "\(Int(sliderLimit))%" : "Off")
                        .monospacedDigit().frame(width: 36, alignment: .trailing)
                }
                .disabled(!p.helperInstalled)
            }

            section("Energy flow") {
                let charge = max(p.batteryW, 0), discharge = max(-p.batteryW, 0)
                let fromAdapter = max(p.systemW - discharge, 0)
                Sankey(
                    sources: [Node(name: "Charger", color: .blue), Node(name: "Battery", color: .orange)],
                    sinks: [Node(name: "System", color: .purple), Node(name: "Battery", color: .green), Node(name: "Heat loss", color: .gray)],
                    flows: [
                        Flow(from: 0, to: 0, watts: p.onAC ? fromAdapter : 0),
                        Flow(from: 0, to: 1, watts: charge),
                        Flow(from: 0, to: 2, watts: p.lossW),
                        Flow(from: 1, to: 0, watts: discharge),
                    ])
                .frame(height: 120)
            }

            if let e = p.error { Text(e).font(.caption).foregroundStyle(.red) }

            Divider()
            HStack {
                Toggle("Open at login", isOn: Binding(get: { p.launchAtLogin }, set: { _ in p.toggleLaunchAtLogin() }))
                    .toggleStyle(.checkbox).font(.caption)
                Spacer()
                if p.helperInstalled { Button("Reinstall helper") { p.installHelper() }.buttonStyle(.link).font(.caption) }
                Button("Quit") { NSApp.terminate(nil) }.font(.caption)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { p.refresh(); p.readMode(); p.readLimit(); syncSlider() }
        .onChange(of: p.limit) { if !editing { syncSlider() } }
    }

    private func syncSlider() { if p.limit < 100 { sliderLimit = Double(p.limit) } }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

@main
struct JuiceApp: App {
    @StateObject private var power = Power()

    init() {
        // Debug: `Juice --snapshot out.png` renders the panel to an image and exits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--icons"), i + 1 < args.count {
            StatusIcon.renderPreview(to: args[i + 1]); exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let p = Power()
            let r = ImageRenderer(content: PanelView(p: p).background(Color(nsColor: .windowBackgroundColor)))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(p: power)
        } label: {
            Image(nsImage: power.statusImage)
        }
        .menuBarExtraStyle(.window)
    }
}
