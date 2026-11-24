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
    @Published var parts = ComponentPower()
    @Published var minutesLeft: Int?
    @Published var tempC: Double?
    @Published var cycles: Int?
    @Published var health: Int?
    @Published var apps: [AppUse] = []
    @Published var mode = 0            // 0 auto, 1 low, 2 high
    @Published var limit = 100
    @Published var helperInstalled = FileManager.default.fileExists(atPath: helperPath)
    @Published var error: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let energy = EnergySampler()
    private var timer: Timer?
    private var ticks = 0
    private var panelOpen = false
    private var appLoop: Task<Void, Never>?

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
        if let p = energy.sample() { parts = p }

        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return }

        func num(_ k: String, _ dict: [String: Any]? = nil) -> Double? {
            ((dict ?? d)[k] as? NSNumber).map { Double($0.int64Value) }
        }
        let cur = num("CurrentCapacity") ?? 0, cap = num("MaxCapacity") ?? 100
        percent = Int((cur / max(cap, 1) * 100).rounded())
        onAC = (d["ExternalConnected"] as? Bool) ?? false
        charging = (d["IsCharging"] as? Bool) ?? false

        let batt = (num("Voltage") ?? 0) / 1000 * (num("Amperage") ?? 0) / 1000
        batteryW = abs(batt) < 0.05 ? 0 : batt

        let t = num(charging ? "AvgTimeToFull" : "AvgTimeToEmpty") ?? 65535
        minutesLeft = (t > 0 && t < 6000 && (charging || !onAC)) ? Int(t) : nil
        tempC = num("Temperature").map { $0 / 100 }
        cycles = num("CycleCount").map { Int($0) }
        if let raw = num("AppleRawMaxCapacity"), let design = num("DesignCapacity"), design > 0 {
            health = min(100, Int((raw / design * 100).rounded()))
        }

        // Charger-in and system-total watts come straight from the SMC power sensors.
        let sensorSystem = juice_smc_float("PSTR"), sensorIn = juice_smc_float("PDTR")
        let measuredParts = parts.cpu + parts.gpu + parts.memory
        let charge = max(batteryW, 0), discharge = max(-batteryW, 0)
        lossW = 0
        if onAC {
            systemW = sensorSystem > 0 ? sensorSystem : max(measuredParts, sensorIn - charge)
            adapterW = sensorIn > 0 ? sensorIn : max(systemW + charge - discharge, 0)
        } else {
            adapterW = 0
            systemW = sensorSystem > 0 ? sensorSystem : discharge
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
        guard m != mode else { return }
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
        let cmd = "/bin/sh \(quoted("\(res)/install-helper.sh")) \(quoted(res)) \(quoted(NSUserName()))"
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
        } catch { self.error = "Open at login: \(error.localizedDescription)" }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// The app list costs a one-second `top` run, so it only refreshes while the panel is open.
    func panelOpened() {
        panelOpen = true
        refresh(); readMode(); readLimit()
        guard appLoop == nil else { return }
        appLoop = Task { [weak self] in
            while let self, self.panelOpen {
                let list = await Task.detached { AppEnergy.sample() }.value
                self.apps = list
                try? await Task.sleep(for: .seconds(6))
            }
            self?.appLoop = nil
        }
    }

    func panelClosed() { panelOpen = false }

    var heldAtLimit: Bool { onAC && !charging && limit < 100 && percent >= limit - 3 }

    var statusText: String {
        if !onAC { return "On battery" }
        if charging { return "Charging" }
        if heldAtLimit { return "Holding at \(limit)%" }
        if percent >= 99 { return "Fully charged" }
        return "Plugged in, not charging"
    }

    var statusSymbol: String {
        if charging { return "bolt.fill" }
        if onAC { return "powerplug.fill" }
        return "battery.75percent"
    }

    var timeText: (value: String, label: String)? {
        guard let m = minutesLeft else { return nil }
        let s = m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
        return (s, charging ? "until full" : "remaining")
    }

    var statusImage: NSImage {
        StatusIcon.make(percent: percent, charging: charging, pluggedIn: onAC, mode: mode)
    }

    // Sankey inputs
    var flowSources: [Node] { [Node(name: "Charger", color: .mint), Node(name: "Battery", color: .orange)] }
    var flowSinks: [Node] {
        [Node(name: "CPU", color: .blue), Node(name: "GPU", color: .purple), Node(name: "Memory", color: .teal),
         Node(name: "Display & other", color: .indigo), Node(name: "Battery", color: .green), Node(name: "Charger loss", color: .gray)]
    }
    var flows: [Flow] {
        let charge = max(batteryW, 0), discharge = max(-batteryW, 0)
        let fromAdapter = onAC ? max(systemW - discharge, 0) : 0
        let total = fromAdapter + discharge
        guard total > 0.05 else { return [Flow(from: 0, to: 4, watts: charge), Flow(from: 0, to: 5, watts: lossW)] }
        var comp = [parts.cpu, parts.gpu, parts.memory]
        let sum = comp.reduce(0, +)
        if sum > total { comp = comp.map { $0 * total / sum } }
        comp.append(max(total - comp.reduce(0, +), 0))
        var out: [Flow] = []
        for (i, w) in comp.enumerated() {
            out.append(Flow(from: 0, to: i, watts: fromAdapter * w / total))
            out.append(Flow(from: 1, to: i, watts: discharge * w / total))
        }
        out.append(Flow(from: 0, to: 4, watts: charge))
        out.append(Flow(from: 0, to: 5, watts: lossW))
        return out
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

func modeColor(_ mode: Int) -> Color { mode == 1 ? .yellow : (mode == 2 ? .orange : .blue) }

// MARK: - Sankey

struct Flow { let from: Int; let to: Int; let watts: Double }
struct Node { let name: String; let color: Color }

struct Sankey: View {
    let sources: [Node]
    let sinks: [Node]
    let flows: [Flow]

    var body: some View {
        Canvas { ctx, size in
            let barW: CGFloat = 5, gap: CGFloat = 5, minH: CGFloat = 13
            let total = flows.reduce(0) { $0 + $1.watts }
            guard total > 0.05 else {
                ctx.draw(Text("No power flowing").font(.caption).foregroundStyle(.secondary), at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            func totals(_ count: Int, _ key: (Flow) -> Int) -> [Double] {
                (0..<count).map { i in flows.filter { key($0) == i }.reduce(0) { $0 + $1.watts } }
            }
            let srcT = totals(sources.count, { $0.from }), snkT = totals(sinks.count, { $0.to })
            // Every visible node gets a minimum height (so its label fits) plus its proportional share.
            func layout(_ t: [Double], x: CGFloat) -> [CGRect] {
                let n = CGFloat(t.filter { $0 > 0.05 }.count)
                let scale = max(size.height - gap * max(n - 1, 0) - minH * n, 0) / total
                var y: CGFloat = 0
                return t.map { w in
                    guard w > 0.05 else { return .zero }
                    let h = minH + CGFloat(w) * scale
                    defer { y += h + gap }
                    return CGRect(x: x, y: y, width: barW, height: h)
                }
            }
            let srcR = layout(srcT, x: 0), snkR = layout(snkT, x: size.width - barW)
            var srcOff = srcR.map { $0.minY }, snkOff = snkR.map { $0.minY }

            for f in flows where f.watts > 0.02 && srcT[f.from] > 0.05 && snkT[f.to] > 0.05 {
                let h0 = srcR[f.from].height * CGFloat(f.watts / srcT[f.from])
                let h1 = snkR[f.to].height * CGFloat(f.watts / snkT[f.to])
                let x0 = barW + 1, x1 = size.width - barW - 1, mid = (x0 + x1) / 2
                let a = srcOff[f.from], b = snkOff[f.to]
                var p = Path()
                p.move(to: CGPoint(x: x0, y: a))
                p.addCurve(to: CGPoint(x: x1, y: b), control1: CGPoint(x: mid, y: a), control2: CGPoint(x: mid, y: b))
                p.addLine(to: CGPoint(x: x1, y: b + h1))
                p.addCurve(to: CGPoint(x: x0, y: a + h0), control1: CGPoint(x: mid, y: b + h1), control2: CGPoint(x: mid, y: a + h0))
                p.closeSubpath()
                ctx.fill(p, with: .linearGradient(
                    Gradient(colors: [sources[f.from].color.opacity(0.5), sinks[f.to].color.opacity(0.5)]),
                    startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x1, y: 0)))
                srcOff[f.from] += h0; snkOff[f.to] += h1
            }

            func label(_ n: Node, _ w: Double, _ r: CGRect, leading: Bool) {
                guard w > 0.05 else { return }
                ctx.fill(Path(roundedRect: r, cornerRadius: 2.5), with: .color(n.color))
                let watts = Text(String(format: w < 10 ? "%.1f W" : "%.0f W", w)).font(.system(size: 10, weight: .bold).monospacedDigit())
                let name = Text(n.name).font(.system(size: 10, weight: .medium))
                let t = (leading ? Text("\(name)  \(watts)") : Text("\(watts)  \(name)")).foregroundStyle(.primary)
                ctx.draw(t, at: CGPoint(x: leading ? r.maxX + 6 : r.minX - 6, y: r.midY), anchor: leading ? .leading : .trailing)
            }
            for i in sources.indices { label(sources[i], srcT[i], srcR[i], leading: true) }
            for i in sinks.indices { label(sinks[i], snkT[i], snkR[i], leading: false) }
        }
    }
}

// MARK: - UI pieces

struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

struct CardTitle: View {
    let symbol: String, title: String
    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
            .labelStyle(.titleAndIcon)
    }
}

struct LevelBar: View {
    let percent: Int, limit: Int, color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color.gradient).frame(width: max(8, g.size.width * CGFloat(percent) / 100))
                if limit < 100 {
                    RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.75))
                        .frame(width: 2, height: g.size.height + 6)
                        .offset(x: g.size.width * CGFloat(limit) / 100 - 1)
                }
            }
        }
        .frame(height: 8)
    }
}

struct ModeTile: View {
    let title: String, symbol: String, color: Color, selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .frame(maxWidth: .infinity).frame(height: 56)
            .foregroundStyle(selected ? (color == .yellow ? Color.black : Color.white) : Color.primary)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? AnyShapeStyle(color.gradient) : AnyShapeStyle(Color.primary.opacity(0.06))))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(selected ? 0 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct Stat: View {
    let value: String, label: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var p: Power
    @State private var sliderLimit = 80.0
    @State private var editing = false

    var body: some View {
        VStack(spacing: 10) {
            hero
            if !p.helperInstalled { installCard }
            modes
            limitCard
            flowCard
            if !p.apps.isEmpty { appsCard }
            statsCard
            if let e = p.error { Text(e).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }
            footer
        }
        .padding(12)
        .frame(width: 348)
        .onAppear { p.panelOpened(); syncSlider() }
        .onDisappear { p.panelClosed() }
        .onChange(of: p.limit) { if !editing { syncSlider() } }
    }

    private var levelColor: Color {
        if p.percent <= 10 && !p.onAC { return .red }
        return p.mode == 1 ? .yellow : .green
    }

    private var hero: some View {
        Card(padding: 14) {
            VStack(spacing: 12) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text("\(p.percent)").font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                            Text("%").font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                        }
                        Label(p.statusText, systemImage: p.statusSymbol)
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        if let t = p.timeText {
                            Text(t.value).font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                            Text(t.label).font(.system(size: 11)).foregroundStyle(.secondary)
                        } else {
                            Text(String(format: "%.1f W", p.systemW)).font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                            Text("system load").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                LevelBar(percent: p.percent, limit: p.limit, color: levelColor)
            }
        }
    }

    private var installCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Juice needs a small helper to change power modes and limit charging.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Install helper…") { p.installHelper() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var modes: some View {
        HStack(spacing: 8) {
            ModeTile(title: "Low Power", symbol: "leaf.fill", color: .yellow, selected: p.mode == 1) { p.setMode(1) }
            ModeTile(title: "Automatic", symbol: "circle.lefthalf.filled", color: .blue, selected: p.mode == 0) { p.setMode(0) }
            ModeTile(title: "High Power", symbol: "flame.fill", color: .orange, selected: p.mode == 2) { p.setMode(2) }
        }
        .disabled(!p.helperInstalled)
        .opacity(p.helperInstalled ? 1 : 0.5)
    }

    private var limitCard: some View {
        Card {
            VStack(spacing: 8) {
                HStack {
                    CardTitle(symbol: "battery.75percent", title: "Charge limit")
                    Spacer()
                    Text(p.limit < 100 ? "\(Int(sliderLimit))%" : "Off")
                        .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(p.limit < 100 ? Color.primary : Color.secondary)
                    Toggle("", isOn: Binding(
                        get: { p.limit < 100 },
                        set: { p.setLimit($0 ? Int(sliderLimit) : 100) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                }
                if p.limit < 100 {
                    Slider(value: $sliderLimit, in: 50...95, step: 5) { e in
                        editing = e
                        if !e { p.setLimit(Int(sliderLimit)) }
                    }
                    .tint(.green).controlSize(.small)
                }
            }
        }
        .disabled(!p.helperInstalled)
    }

    private var flowCard: some View {
        Card {
            VStack(spacing: 10) {
                HStack {
                    CardTitle(symbol: "arrow.triangle.branch", title: "Energy flow")
                    Spacer()
                    Text(String(format: "%.1f W", p.onAC ? p.adapterW : p.systemW))
                        .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                }
                Sankey(sources: p.flowSources, sinks: p.flowSinks, flows: p.flows)
                    .frame(height: 150)
            }
        }
    }

    private var appsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle(symbol: "bolt.badge.clock", title: "Using significant energy")
                let top = max(p.apps.first?.impact ?? 1, 1)
                ForEach(p.apps) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: app.icon).resizable().frame(width: 18, height: 18)
                        Text(app.name).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 8)
                        Capsule().fill(Color.orange.opacity(0.75))
                            .frame(width: max(4, 70 * app.impact / top), height: 5)
                            .frame(width: 70, alignment: .trailing)
                        Text(String(format: "%.0f", app.impact))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var statsCard: some View {
        Card(padding: 10) {
            HStack(spacing: 0) {
                Stat(value: p.health.map { "\($0)%" } ?? "–", label: "Health")
                Divider().frame(height: 24)
                Stat(value: p.cycles.map(String.init) ?? "–", label: "Cycles")
                Divider().frame(height: 24)
                Stat(value: p.tempC.map { String(format: "%.0f°C", $0) } ?? "–", label: "Battery temp")
                Divider().frame(height: 24)
                Stat(value: String(format: "%.1f W", abs(p.batteryW)), label: p.batteryW > 0 ? "Charging at" : "Battery draw")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle("Open at login", isOn: Binding(get: { p.launchAtLogin }, set: { _ in p.toggleLaunchAtLogin() }))
                .toggleStyle(.checkbox).controlSize(.small)
            Spacer()
            if p.helperInstalled { Button("Reinstall helper") { p.installHelper() }.buttonStyle(.link) }
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.link)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 4).padding(.top, 2)
    }

    private func syncSlider() { if p.limit < 100 { sliderLimit = Double(p.limit) } }
}

// MARK: - App

@main
struct JuiceApp: App {
    @StateObject private var power = Power()

    init() {
        let args = CommandLine.arguments
        // Debug: `Juice --icons out.png` renders every menu bar icon state.
        if let i = args.firstIndex(of: "--icons"), i + 1 < args.count {
            StatusIcon.renderPreview(to: args[i + 1]); exit(0)
        }
        // Debug: `Juice --snapshot out.png [--dark] [--plugged]` renders the panel and exits.
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            _ = NSApplication.shared
            let p = Power()
            Thread.sleep(forTimeInterval: 1)
            p.refresh()
            p.apps = AppEnergy.sample()
            if args.contains("--plugged") {   // pretend a charger is connected, to check that layout
                p.onAC = true; p.charging = true; p.percent = 62; p.limit = 80; p.minutesLeft = 41
                p.batteryW = 38; p.systemW = 24; p.adapterW = 62; p.lossW = 5
            }
            let host = NSHostingView(rootView: PanelView(p: p).background(Color(nsColor: .windowBackgroundColor)))
            let win = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: host.fittingSize),
                               styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            win.displayIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
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
