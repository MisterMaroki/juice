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
    @Published var flowIn: [Double] = []
    @Published var flowOut: [Double] = []
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
        updateFlows()
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

    // Sankey inputs. Outputs are derived from inputs so both sides always add up to the same total,
    // and values are smoothed so the chart doesn't twitch every refresh.
    static let sourceNodes = [Node(name: "Charger", color: .mint), Node(name: "Battery", color: .orange)]
    static let sinkNodes = [Node(name: "CPU", color: .blue), Node(name: "GPU", color: .purple), Node(name: "Memory", color: .teal),
                            Node(name: "Display & other", color: .indigo), Node(name: "Battery", color: .green)]

    func updateFlows() {
        let charge = max(batteryW, 0), discharge = max(-batteryW, 0)
        let adapter = onAC ? max(adapterW, 0) : 0
        let total = adapter + discharge
        let toBattery = min(charge, total)
        let system = max(total - toBattery, 0)
        var comp = [parts.cpu, parts.gpu, parts.memory]
        let sum = comp.reduce(0, +)
        if sum > system, sum > 0 { comp = comp.map { $0 * system / sum } }
        let rawIn = [adapter, discharge]
        let rawOut = comp + [max(system - comp.reduce(0, +), 0), toBattery]
        func smooth(_ old: [Double], _ new: [Double]) -> [Double] {
            guard old.count == new.count, old.contains(where: { $0 > 0 }) else { return new }
            return zip(old, new).map { o, n in (n < 0.05 || o < 0.05) ? n : o + (n - o) * 0.4 }
        }
        flowIn = smooth(flowIn, rawIn)
        flowOut = smooth(flowOut, rawOut)
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

struct Node { let name: String; let color: Color }

/// Two-stage flow: sources merge into one trunk, the trunk splits into outputs.
/// Heights are strictly proportional to watts; labels sit in fixed columns either side.
struct Sankey: View {
    let sources: [(node: Node, watts: Double)]
    let sinks: [(node: Node, watts: Double)]

    var body: some View {
        Canvas { ctx, size in
            let ins = sources.filter { $0.watts > 0.05 }, outs = sinks.filter { $0.watts > 0.05 }
            let totalIn = ins.reduce(0) { $0 + $1.watts }, totalOut = outs.reduce(0) { $0 + $1.watts }
            guard totalIn > 0.05, totalOut > 0.05 else {
                ctx.draw(Text("No power flowing").font(.caption).foregroundStyle(.secondary), at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let leftGutter: CGFloat = 52, rightGutter: CGFloat = 118, barW: CGFloat = 4, gap: CGFloat = 5
            let trunkH = size.height - gap * CGFloat(max(ins.count, outs.count) - 1)
            let trunkTop = (size.height - trunkH) / 2
            let xL = leftGutter, xR = size.width - rightGutter - barW, xT = ((xL + xR) / 2).rounded()

            func column(_ items: [(node: Node, watts: Double)], total: Double, x: CGFloat) -> [CGRect] {
                let hs = items.map { max(CGFloat($0.watts / total) * trunkH, 1.5) }
                var y = (size.height - hs.reduce(0, +) - gap * CGFloat(items.count - 1)) / 2
                return hs.map { h in defer { y += h + gap }; return CGRect(x: x, y: y, width: barW, height: h) }
            }
            let inR = column(ins, total: totalIn, x: xL), outR = column(outs, total: totalOut, x: xR)

            func band(x0: CGFloat, y0: CGFloat, h0: CGFloat, x1: CGFloat, y1: CGFloat, h1: CGFloat, color: Color, nodeOnLeft: Bool) {
                let mid = (x0 + x1) / 2
                var p = Path()
                p.move(to: CGPoint(x: x0, y: y0))
                p.addCurve(to: CGPoint(x: x1, y: y1), control1: CGPoint(x: mid, y: y0), control2: CGPoint(x: mid, y: y1))
                p.addLine(to: CGPoint(x: x1, y: y1 + h1))
                p.addCurve(to: CGPoint(x: x0, y: y0 + h0), control1: CGPoint(x: mid, y: y1 + h1), control2: CGPoint(x: mid, y: y0 + h0))
                p.closeSubpath()
                // Strong at the node, fading towards the trunk.
                let strong = color.opacity(0.6), soft = color.opacity(0.28)
                ctx.fill(p, with: .linearGradient(Gradient(colors: nodeOnLeft ? [strong, soft] : [soft, strong]),
                                                  startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x1, y: 0)))
            }

            var y = trunkTop
            for (i, item) in ins.enumerated() {
                let h = CGFloat(item.watts / totalIn) * trunkH
                band(x0: xL + barW, y0: inR[i].minY, h0: inR[i].height, x1: xT, y1: y, h1: h, color: item.node.color, nodeOnLeft: true)
                y += h
            }
            y = trunkTop
            for (i, item) in outs.enumerated() {
                let h = CGFloat(item.watts / totalOut) * trunkH
                band(x0: xT + barW, y0: y, h0: h, x1: xR, y1: outR[i].minY, h1: outR[i].height, color: item.node.color, nodeOnLeft: false)
                y += h
            }

            ctx.fill(Path(roundedRect: CGRect(x: xT, y: trunkTop, width: barW, height: trunkH), cornerRadius: 2), with: .color(.primary.opacity(0.55)))
            for (i, item) in ins.enumerated() { ctx.fill(Path(roundedRect: inR[i], cornerRadius: 2), with: .color(item.node.color)) }
            for (i, item) in outs.enumerated() { ctx.fill(Path(roundedRect: outR[i], cornerRadius: 2), with: .color(item.node.color)) }

            // Labels: keep each next to its bar, but never closer together than one line.
            func spread(_ ys: [CGFloat], minGap: CGFloat) -> [CGFloat] {
                var v = ys
                let lo = minGap / 2, hi = size.height - minGap / 2
                for i in v.indices { v[i] = max(v[i], i == 0 ? lo : v[i - 1] + minGap) }
                for i in v.indices.reversed() { v[i] = min(v[i], i == v.count - 1 ? hi : v[i + 1] - minGap) }
                return v
            }
            func watts(_ w: Double) -> String { String(format: w < 9.95 ? "%.1f W" : "%.0f W", w) }
            let nameFont = Font.system(size: 10.5, weight: .medium), wattFont = Font.system(size: 10.5, weight: .bold).monospacedDigit()

            let inY = spread(inR.map { $0.midY }, minGap: 28)
            for (i, item) in ins.enumerated() {
                ctx.draw(Text(item.node.name).font(nameFont).foregroundStyle(.secondary), at: CGPoint(x: xL - 7, y: inY[i] - 6.5), anchor: .trailing)
                ctx.draw(Text(watts(item.watts)).font(wattFont).foregroundStyle(.primary), at: CGPoint(x: xL - 7, y: inY[i] + 6.5), anchor: .trailing)
            }
            let outY = spread(outR.map { $0.midY }, minGap: 14)
            for (i, item) in outs.enumerated() {
                ctx.draw(Text(item.node.name).font(nameFont).foregroundStyle(.secondary), at: CGPoint(x: xR + barW + 7, y: outY[i]), anchor: .leading)
                ctx.draw(Text(watts(item.watts)).font(wattFont).foregroundStyle(.primary), at: CGPoint(x: size.width, y: outY[i]), anchor: .trailing)
            }
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
        .frame(width: 360)
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
                    Text(String(format: "%.1f W", p.flowIn.reduce(0, +)))
                        .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                }
                Sankey(sources: Array(zip(Power.sourceNodes, p.flowIn)).map { (node: $0.0, watts: $0.1) },
                       sinks: Array(zip(Power.sinkNodes, p.flowOut)).map { (node: $0.0, watts: $0.1) })
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
