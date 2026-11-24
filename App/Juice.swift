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
    @Published var batteryW = 0.0      // + charging, - discharging (live sensor)
    @Published var systemW = 0.0       // live sensor
    @Published var adapterW = 0.0      // power coming in from the charger (live sensor)
    @Published var parts = ComponentPower()
    @Published var cpu = CPULoad()
    @Published var mem = MemInfo()
    @Published var minutesLeft: Int?
    @Published var tempC: Double?
    @Published var cycles: Int?
    @Published var health: Int?
    @Published var procs: [AppUse] = []
    @Published var flowIn: [Double] = [0, 0]
    @Published var flowOut: [Double] = [0, 0, 0, 0, 0, 0]
    @Published var mode = 0            // 0 auto, 1 low, 2 high
    @Published var limit = 100
    @Published var helperInstalled = FileManager.default.fileExists(atPath: helperPath)
    @Published var error: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let energy = EnergySampler()
    private let cpuSampler = CPUSampler()
    private var timer: Timer?
    private var ticks = 0
    private var panelOpen = false
    private var procLoop: Task<Void, Never>?

    init() {
        refresh(); readMode(); readLimit()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        refresh()
        ticks += 1
        if ticks % 10 == 0 { readMode(); readLimit() }
    }

    func refresh() {
        if let p = energy.sample() { parts = p }
        if let c = cpuSampler.sample() { cpu = c }
        mem = MemInfo.read()

        // Slow-moving battery facts come from the battery gauge.
        var gaugeW = 0.0
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if svc != 0 {
            defer { IOObjectRelease(svc) }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let d = props?.takeRetainedValue() as? [String: Any] {
                func num(_ k: String) -> Double? { (d[k] as? NSNumber).map { Double($0.int64Value) } }
                let cur = num("CurrentCapacity") ?? 0, cap = num("MaxCapacity") ?? 100
                percent = Int((cur / max(cap, 1) * 100).rounded())
                gaugeW = (num("Voltage") ?? 0) / 1000 * (num("Amperage") ?? 0) / 1000
                let gaugeCharging = (d["IsCharging"] as? Bool) ?? false
                let t = num(gaugeCharging ? "AvgTimeToFull" : "AvgTimeToEmpty") ?? 65535
                minutesLeft = (t > 0 && t < 6000) ? Int(t) : nil
                tempC = num("Temperature").map { $0 / 100 }
                cycles = num("CycleCount").map { Int($0) }
                if let raw = num("AppleRawMaxCapacity"), let design = num("DesignCapacity"), design > 0 {
                    health = min(100, Int((raw / design * 100).rounded()))
                }
            }
        }

        // Live power figures come straight from the SMC sensors, which update every second.
        // (The battery gauge above can lag by half a minute or more.)
        onAC = runningOnCharger()
        let chargerIn = juice_smc_float("PDTR"), system = juice_smc_float("PSTR")
        let mA = juice_smc_si16("B0AC"), mV = juice_smc_si16("B0AV")
        var batt = (mA > -1e8 && mV > 0) ? mA * mV / 1e6 : gaugeW
        adapterW = (onAC && chargerIn > 0.3) ? chargerIn : 0
        systemW = system > 0 ? system : max(adapterW - batt, 0)
        // Sign guard: the battery can only be a source if the charger isn't covering the system.
        if !onAC { batt = -abs(batt) } else if batt > 0, adapterW + 1 < systemW { batt = -batt }
        batteryW = abs(batt) < 0.05 ? 0 : batt
        charging = onAC && batteryW > 0.2
        if onAC && !charging { minutesLeft = nil }
        updateFlows()
    }

    // MARK: Energy flow

    static let sourceNodes = [
        Node(name: "Charger", color: .mint, symbol: "powerplug.fill"),
        Node(name: "Battery", color: .orange, symbol: "battery.100percent"),
    ]
    static let sinkNodes = [
        Node(name: "CPU", color: .blue, symbol: "cpu"),
        Node(name: "GPU", color: .purple, symbol: "square.stack.3d.up.fill"),
        Node(name: "Memory", color: .teal, symbol: "memorychip"),
        Node(name: "Display & other", color: .indigo, symbol: "display"),
        Node(name: "Battery", color: .green, symbol: "battery.100percent.bolt"),
        Node(name: "Conversion loss", color: .gray, symbol: "thermometer.medium"),
    ]

    /// Every number here is a direct sensor reading except "Display & other" (system total minus the
    /// measured chips) and "Conversion loss" (what came in minus what was delivered).
    func updateFlows() {
        let charge = max(batteryW, 0), discharge = max(-batteryW, 0)
        let totalIn = adapterW + discharge
        var comp = [parts.cpu, parts.gpu, parts.memory]
        let sum = comp.reduce(0, +)
        if sum > systemW, sum > 0 { comp = comp.map { $0 * systemW / sum } }
        let other = max(systemW - comp.reduce(0, +), 0)
        let loss = totalIn - systemW - charge
        flowIn = [adapterW, discharge]
        flowOut = comp + [other, charge, loss > 0.3 ? loss : 0]
    }

    struct Drill { let source: FlowItem; let sinks: [FlowItem]; let note: String }

    /// Second level of the chart: what one output is made of.
    func drill(_ id: Int) -> Drill {
        let total = flowOut[id]
        let source = FlowItem(node: Power.sinkNodes[id], watts: total)
        let palette: [Color] = [.blue, .cyan, .teal, .mint, .indigo]

        func byApp(_ value: (AppUse) -> Double, note: String) -> Drill {
            let ranked = procs.filter { value($0) > 0 }.sorted { value($0) > value($1) }
            let all = procs.reduce(0) { $0 + value($1) }
            guard all > 0, total > 0.05 else { return Drill(source: source, sinks: [], note: procs.isEmpty ? "Measuring apps…" : note) }
            var sinks: [FlowItem] = [], used = 0.0
            for (i, a) in ranked.prefix(5).enumerated() {
                let w = total * value(a) / all
                used += w
                sinks.append(FlowItem(node: Node(name: a.name, color: palette[i % palette.count], icon: a.icon), watts: w))
            }
            sinks.append(FlowItem(node: Node(name: "Everything else", color: .gray, symbol: "ellipsis.circle"), watts: max(total - used, 0)))
            return Drill(source: source, sinks: sinks, note: note)
        }

        switch id {
        case 0: return byApp({ $0.cpu }, note: "Estimate: CPU power split by each app's share of CPU time.")
        case 2: return byApp({ $0.memory }, note: "Estimate: memory power split by each app's share of memory.")
        case 3:
            var rails = [
                ("Display driver", parts.displayController, Color.indigo, "display"),
                ("Memory bus", parts.memoryController, Color.teal, "memorychip"),
                ("Neural Engine", parts.neuralEngine, Color.pink, "brain"),
                ("Media engines", parts.mediaEngines, Color.orange, "film"),
            ]
            let sum = rails.reduce(0) { $0 + $1.1 }
            if sum > total, sum > 0 { rails = rails.map { ($0.0, $0.1 * total / sum, $0.2, $0.3) } }
            var sinks = rails.map { FlowItem(node: Node(name: $0.0, color: $0.2, symbol: $0.3), watts: $0.1) }
            sinks.append(FlowItem(node: Node(name: "Screen & the rest", color: .gray, symbol: "sun.max"),
                                  watts: max(total - min(sum, total), 0)))
            return Drill(source: source, sinks: sinks, note: "Measured chip rails. The rest (screen backlight, SSD, radios, fans) has no separate sensor, so it can't be split further or assigned to apps.")
        default:
            return Drill(source: source, sinks: [], note: "macOS doesn't report GPU power per app, so this can't be broken down honestly.")
        }
    }

    // MARK: Actions

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
        guard v != limit else { return }
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
        } else { error = nil }
        readLimit(); readMode()
    }

    func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { self.error = "Open at Login: \(error.localizedDescription)" }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func quit(_ app: AppUse, force: Bool) {
        AppEnergy.quit(app, force: force)
        procs.removeAll { $0.id == app.id }
    }

    /// The per-app list costs a one-second `top` run, so it only refreshes while the panel is open.
    func panelOpened() {
        panelOpen = true
        refresh(); readMode(); readLimit()
        guard procLoop == nil else { return }
        procLoop = Task { [weak self] in
            while let self, self.panelOpen {
                let list = await Task.detached { AppEnergy.sample() }.value
                if !list.isEmpty { self.procs = list }
                try? await Task.sleep(for: .seconds(3))
            }
            self?.procLoop = nil
        }
    }

    func panelClosed() { panelOpen = false }

    // MARK: Text

    var heldAtLimit: Bool { onAC && !charging && limit < 100 && percent >= limit - 3 }

    var statusText: String {
        if !onAC { return "On Battery" }
        if charging { return "Charging" }
        if heldAtLimit { return "Holding at \(limit)%" }
        if percent >= 99 { return "Fully Charged" }
        if batteryW < -0.2 { return "Charger can't keep up" }
        return "Plugged In, Not Charging"
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

func wattText(_ w: Double) -> String { String(format: w < 9.95 ? "%.1f W" : "%.0f W", w) }

// MARK: - Sankey

struct Node {
    let name: String
    let color: Color
    var symbol: String? = nil
    var icon: NSImage? = nil
}

struct FlowItem {
    let node: Node
    let watts: Double
    var tapID: Int? = nil      // set when clicking this output opens a breakdown
}

/// Two-stage flow: sources merge into one trunk, the trunk splits into outputs.
/// Heights are strictly proportional to watts; labels sit in fixed columns either side.
struct Sankey: View {
    let sources: [FlowItem]
    let sinks: [FlowItem]
    var onTap: (Int) -> Void = { _ in }

    private struct Layout {
        var ins: [FlowItem] = [], outs: [FlowItem] = []
        var inR: [CGRect] = [], outR: [CGRect] = [], inY: [CGFloat] = [], outY: [CGFloat] = []
        var totalIn = 0.0, totalOut = 0.0
        var xL: CGFloat = 0, xR: CGFloat = 0, xT: CGFloat = 0, trunkTop: CGFloat = 0, trunkH: CGFloat = 0
    }
    private let leftGutter: CGFloat = 58, rightGutter: CGFloat = 150, barW: CGFloat = 4, gap: CGFloat = 5

    private func layout(_ size: CGSize) -> Layout? {
        var l = Layout()
        l.ins = sources.filter { $0.watts > 0.05 }
        l.outs = sinks.filter { $0.watts > 0.05 }
        l.totalIn = l.ins.reduce(0) { $0 + $1.watts }
        l.totalOut = l.outs.reduce(0) { $0 + $1.watts }
        guard l.totalIn > 0.05, l.totalOut > 0.05 else { return nil }
        l.trunkH = size.height - gap * CGFloat(max(l.ins.count, l.outs.count) - 1)
        l.trunkTop = (size.height - l.trunkH) / 2
        l.xL = leftGutter; l.xR = size.width - rightGutter - barW; l.xT = ((l.xL + l.xR) / 2).rounded()

        func column(_ items: [FlowItem], total: Double, x: CGFloat) -> [CGRect] {
            let hs = items.map { max(CGFloat($0.watts / total) * l.trunkH, 1.5) }
            var y = (size.height - hs.reduce(0, +) - gap * CGFloat(items.count - 1)) / 2
            return hs.map { h in defer { y += h + gap }; return CGRect(x: x, y: y, width: barW, height: h) }
        }
        // Keep each label next to its bar, but never closer together than one line.
        func spread(_ ys: [CGFloat], minGap: CGFloat) -> [CGFloat] {
            var v = ys
            let lo = minGap / 2, hi = size.height - minGap / 2
            for i in v.indices { v[i] = max(v[i], i == 0 ? lo : v[i - 1] + minGap) }
            for i in v.indices.reversed() { v[i] = min(v[i], i == v.count - 1 ? hi : v[i + 1] - minGap) }
            return v
        }
        l.inR = column(l.ins, total: l.totalIn, x: l.xL)
        l.outR = column(l.outs, total: l.totalOut, x: l.xR)
        l.inY = spread(l.inR.map { $0.midY }, minGap: 30)
        l.outY = spread(l.outR.map { $0.midY }, minGap: 16)
        return l
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                guard let l = layout(size) else {
                    ctx.draw(Text("No power flowing").font(.caption).foregroundStyle(.secondary), at: CGPoint(x: size.width / 2, y: size.height / 2))
                    return
                }
                func band(x0: CGFloat, y0: CGFloat, h0: CGFloat, x1: CGFloat, y1: CGFloat, h1: CGFloat, color: Color, nodeOnLeft: Bool) {
                    let mid = (x0 + x1) / 2
                    var p = Path()
                    p.move(to: CGPoint(x: x0, y: y0))
                    p.addCurve(to: CGPoint(x: x1, y: y1), control1: CGPoint(x: mid, y: y0), control2: CGPoint(x: mid, y: y1))
                    p.addLine(to: CGPoint(x: x1, y: y1 + h1))
                    p.addCurve(to: CGPoint(x: x0, y: y0 + h0), control1: CGPoint(x: mid, y: y1 + h1), control2: CGPoint(x: mid, y: y0 + h0))
                    p.closeSubpath()
                    let strong = color.opacity(0.6), soft = color.opacity(0.28)   // strong at the node, fading to the trunk
                    ctx.fill(p, with: .linearGradient(Gradient(colors: nodeOnLeft ? [strong, soft] : [soft, strong]),
                                                      startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x1, y: 0)))
                }
                var y = l.trunkTop
                for (i, item) in l.ins.enumerated() {
                    let h = CGFloat(item.watts / l.totalIn) * l.trunkH
                    band(x0: l.xL + barW, y0: l.inR[i].minY, h0: l.inR[i].height, x1: l.xT, y1: y, h1: h, color: item.node.color, nodeOnLeft: true)
                    y += h
                }
                y = l.trunkTop
                for (i, item) in l.outs.enumerated() {
                    let h = CGFloat(item.watts / l.totalOut) * l.trunkH
                    band(x0: l.xT + barW, y0: y, h0: h, x1: l.xR, y1: l.outR[i].minY, h1: l.outR[i].height, color: item.node.color, nodeOnLeft: false)
                    y += h
                }
                ctx.fill(Path(roundedRect: CGRect(x: l.xT, y: l.trunkTop, width: barW, height: l.trunkH), cornerRadius: 2), with: .color(.primary.opacity(0.55)))
                for (i, item) in l.ins.enumerated() { ctx.fill(Path(roundedRect: l.inR[i], cornerRadius: 2), with: .color(item.node.color)) }
                for (i, item) in l.outs.enumerated() { ctx.fill(Path(roundedRect: l.outR[i], cornerRadius: 2), with: .color(item.node.color)) }

                let nameFont = Font.system(size: 11, weight: .medium), wattFont = Font.system(size: 11, weight: .semibold).monospacedDigit()
                func glyph(_ n: Node, center: CGPoint) {
                    if let icon = n.icon {
                        ctx.draw(Image(nsImage: icon), in: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14))
                    } else if let s = n.symbol {
                        ctx.draw(Text(Image(systemName: s)).font(.system(size: 10, weight: .medium)).foregroundStyle(n.color), at: center)
                    }
                }
                func short(_ s: String, _ n: Int) -> String { s.count > n ? s.prefix(n - 1).trimmingCharacters(in: .whitespaces) + "…" : s }

                // Sources: icon + name over the watts, right-aligned against the bar.
                for (i, item) in l.ins.enumerated() {
                    if item.node.icon != nil || item.node.symbol != nil, l.ins.count == 1 {
                        // A single source (drill-down): icon above the name.
                        glyph(item.node, center: CGPoint(x: l.xL - 14, y: l.inY[i] - 22))
                    }
                    ctx.draw(Text(short(item.node.name, 9)).font(nameFont).foregroundStyle(.secondary), at: CGPoint(x: l.xL - 7, y: l.inY[i] - 7), anchor: .trailing)
                    ctx.draw(Text(wattText(item.watts)).font(wattFont).foregroundStyle(.primary), at: CGPoint(x: l.xL - 7, y: l.inY[i] + 7), anchor: .trailing)
                }
                // Outputs: icon, name, watts column, and a chevron where there's a breakdown.
                let anyTap = l.outs.contains { $0.tapID != nil }
                for (i, item) in l.outs.enumerated() {
                    let x = l.xR + barW + 7
                    glyph(item.node, center: CGPoint(x: x + 7, y: l.outY[i]))
                    ctx.draw(Text(short(item.node.name, 16)).font(nameFont).foregroundStyle(.primary), at: CGPoint(x: x + 19, y: l.outY[i]), anchor: .leading)
                    ctx.draw(Text(wattText(item.watts)).font(wattFont).foregroundStyle(.secondary),
                             at: CGPoint(x: size.width - (anyTap ? 11 : 0), y: l.outY[i]), anchor: .trailing)
                    if item.tapID != nil {
                        ctx.draw(Text(Image(systemName: "chevron.right")).font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary),
                                 at: CGPoint(x: size.width - 3, y: l.outY[i]))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { tap in
                guard let l = layout(geo.size), tap.location.x > l.xT else { return }
                for (i, item) in l.outs.enumerated() {
                    guard let id = item.tapID else { continue }
                    let onLabel = tap.location.x > l.xR && abs(tap.location.y - l.outY[i]) <= 8
                    let onBar = tap.location.x <= l.xR + barW && l.outR[i].insetBy(dx: -200, dy: -2).contains(tap.location)
                    if onLabel || onBar { onTap(id); return }
                }
            })
        }
    }
}

// MARK: - Building blocks

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
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).frame(width: 16)
            Text(title).font(.system(size: 13, weight: .semibold))
        }
    }
}

/// A card whose body folds away; the header keeps a one-line summary visible.
struct Collapsible<Content: View>: View {
    let symbol: String, title: String, summary: String
    @Binding var expanded: Bool
    @ViewBuilder var content: Content
    var body: some View {
        Card {
            VStack(spacing: 10) {
                Button { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } } label: {
                    HStack {
                        CardTitle(symbol: symbol, title: title)
                        Spacer()
                        Text(summary).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded { content }
            }
        }
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
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .frame(maxWidth: .infinity).frame(height: 56)
            .foregroundStyle(selected ? (color == .yellow ? Color.black : Color.white) : Color.primary)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? AnyShapeStyle(color.gradient) : AnyShapeStyle(Color.primary.opacity(hover ? 0.11 : 0.06))))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(selected ? 0 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Control Centre-style slider: a filled capsule with a knob, 1% steps, drag anywhere.
struct LimitSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let active: Bool
    let onCommit: () -> Void

    var body: some View {
        GeometryReader { g in
            let h = g.size.height, w = g.size.width
            let frac = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let fill = h + (w - h) * frac
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(active ? AnyShapeStyle(Color.green.gradient) : AnyShapeStyle(Color.primary.opacity(0.22)))
                    .frame(width: fill)
                Image(systemName: "bolt.fill").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(active ? 0.9 : 0.5)).padding(.leading, 8)
                Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .frame(width: h - 4, height: h - 4).offset(x: fill - h + 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { d in
                    let f = min(max((d.location.x - h / 2) / (w - h), 0), 1)
                    value = (range.lowerBound + f * (range.upperBound - range.lowerBound)).rounded()
                }
                .onEnded { _ in onCommit() })
        }
        .frame(height: 22)
    }
}

struct Stat: View {
    let value: String, label: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// One app in a list. Hover for Quit (hold Option for Force Quit); right-click for both.
struct ProcessRow: View {
    let app: AppUse, value: String, fraction: Double, color: Color
    let quit: (Bool) -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: app.icon).resizable().frame(width: 18, height: 18)
            Text(app.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if hover && app.canQuit {
                Button(NSEvent.modifierFlags.contains(.option) ? "Force Quit" : "Quit") {
                    quit(NSEvent.modifierFlags.contains(.option))
                }
                .buttonStyle(.bordered).controlSize(.mini)
                .help("Quit \(app.name). Hold Option to force quit.")
            } else {
                Capsule().fill(color.opacity(0.8))
                    .frame(width: max(3, 56 * min(max(fraction, 0), 1)), height: 4)
                    .frame(width: 56, alignment: .trailing)
            }
            Text(value).font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
        }
        .frame(height: 22)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hover ? 0.07 : 0)))
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            if app.canQuit {
                Button("Quit \(app.name)") { quit(false) }
                Button("Force Quit \(app.name)") { quit(true) }
            } else {
                Text("System process, can't be quit from here")
            }
        }
    }
}

/// A menu-style row with a hover highlight, like the items at the bottom of Apple's own menu bar panels.
struct MenuRow: View {
    let title: String
    var checked: Bool? = nil
    var shortcut: String? = nil
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let checked { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).opacity(checked ? 1 : 0).frame(width: 12) }
                Text(title).font(.system(size: 13))
                Spacer()
                if let shortcut { Text(shortcut).font(.system(size: 12)).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hover ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Panel

struct PanelContent: View {
    @ObservedObject var p: Power
    var expandAll = false
    @State var drill: Int? = nil
    @State private var sliderLimit = 80.0
    @State private var dragging = false
    @AppStorage("showEnergyApps") private var showEnergyApps = true
    @AppStorage("showMemory") private var showMemory = false
    @AppStorage("showCPU") private var showCPU = false

    var body: some View {
        VStack(spacing: 10) {
            hero
            if !p.helperInstalled { installCard }
            modes
            limitCard
            flowCard
            energyAppsCard
            memoryCard
            cpuCard
            statsCard
            if let e = p.error { Text(e).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }
            footer
        }
        .padding(12)
        .frame(width: 372)
        .onAppear { syncSlider() }
        .onChange(of: p.limit) { if !dragging { syncSlider() } }
    }

    private func open(_ flag: Binding<Bool>) -> Binding<Bool> {
        expandAll ? .constant(true) : flag
    }

    private var levelColor: Color {
        if p.percent <= 10 && !p.onAC { return .red }
        return p.mode == 1 ? .yellow : .green
    }

    // MARK: Battery

    private var hero: some View {
        Card(padding: 14) {
            VStack(spacing: 12) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text("\(p.percent)").font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                            Text("%").font(.system(size: 20, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                        }
                        Label(p.statusText, systemImage: p.statusSymbol)
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        if let t = p.timeText {
                            Text(t.value).font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                            Text(t.label).font(.system(size: 11)).foregroundStyle(.secondary)
                        } else {
                            Text(wattText(p.systemW)).font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                            Text("system load").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                LevelBar(percent: p.percent, limit: dragging ? Int(sliderLimit) : p.limit, color: levelColor)
            }
        }
    }

    private var installCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Juice needs a small helper to change power modes and limit charging.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Install Helper…") { p.installHelper() }.buttonStyle(.borderedProminent)
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
        let on = p.limit < 100
        return Card {
            VStack(spacing: 10) {
                HStack {
                    CardTitle(symbol: "battery.75percent", title: "Charge Limit")
                    Spacer()
                    Text(on || dragging ? "\(Int(sliderLimit))%" : "Off")
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(on || dragging ? Color.primary : Color.secondary)
                        .contentTransition(.numericText())
                    Toggle("", isOn: Binding(get: { on }, set: { p.setLimit($0 ? Int(min(sliderLimit, 99)) : 100) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                }
                LimitSlider(value: $sliderLimit, range: 40...100, active: on || dragging) {
                    dragging = false
                    p.setLimit(Int(sliderLimit))
                }
                .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in dragging = true })
                Text(on ? "Stops charging at \(p.limit)%, starts again at \(p.limit - 3)%."
                        : "No limit. The battery charges to 100%.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .disabled(!p.helperInstalled)
    }

    // MARK: Energy flow

    private func sourceReadout(_ i: Int) -> some View {
        let node = Power.sourceNodes[i], w = p.flowIn[i]
        return HStack(spacing: 6) {
            Image(systemName: node.symbol ?? "circle.fill").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(w > 0.05 ? node.color : Color.secondary.opacity(0.5)).frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text("From \(node.name.lowercased())").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(String(format: "%.1f W", w)).font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(w > 0.05 ? Color.primary : Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var flowCard: some View {
        Card {
            VStack(spacing: 10) {
                if let d = drill {
                    let detail = p.drill(d)
                    HStack {
                        Button { withAnimation(.easeInOut(duration: 0.18)) { drill = nil } } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                                Text("Energy Flow").font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(Color.accentColor).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Text("\(detail.source.node.name)  \(wattText(detail.source.watts))")
                            .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    }
                    if !detail.sinks.isEmpty {
                        Sankey(sources: [detail.source], sinks: detail.sinks).frame(height: 150)
                    }
                    Text(detail.note).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack {
                        CardTitle(symbol: "arrow.triangle.branch", title: "Energy Flow")
                        Spacer()
                        Text("Live").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green)
                        Circle().fill(.green).frame(width: 6, height: 6)
                    }
                    HStack(spacing: 8) { sourceReadout(0); sourceReadout(1) }
                    Sankey(sources: zip(Power.sourceNodes, p.flowIn).map { FlowItem(node: $0, watts: $1) },
                           sinks: zip(Power.sinkNodes, p.flowOut).enumerated().map { i, pair in
                               FlowItem(node: pair.0, watts: pair.1, tapID: i < 4 ? i : nil)
                           },
                           onTap: { id in withAnimation(.easeInOut(duration: 0.18)) { drill = id } })
                        .frame(height: 150)
                }
            }
        }
    }

    // MARK: App lists

    private func list(_ apps: [AppUse], value: @escaping (AppUse) -> Double, text: @escaping (AppUse) -> String, color: Color) -> some View {
        let top = max(apps.first.map(value) ?? 1, 0.0001)
        return VStack(spacing: 2) {
            if apps.isEmpty {
                Text("Measuring…").font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(apps) { app in
                ProcessRow(app: app, value: text(app), fraction: value(app) / top, color: color) { force in p.quit(app, force: force) }
            }
        }
    }

    private var energyAppsCard: some View {
        let apps = Array(p.procs.filter { $0.impact >= 1 }.sorted { $0.impact > $1.impact }.prefix(5))
        return Collapsible(symbol: "bolt.fill", title: "Using Significant Energy",
                           summary: apps.first?.name ?? "", expanded: open($showEnergyApps)) {
            list(apps, value: { $0.impact }, text: { String(format: "%.0f", $0.impact) }, color: .orange)
        }
    }

    private var memoryCard: some View {
        let m = p.mem
        let apps = Array(p.procs.sorted { $0.memory > $1.memory }.prefix(6))
        let parts: [(String, Double, Color)] = [
            ("App Memory", m.app, .blue), ("Wired", m.wired, .orange), ("Compressed", m.compressed, .yellow), ("Cached Files", m.cached, .gray),
        ]
        return Collapsible(symbol: "memorychip", title: "Memory",
                           summary: "\(gigabytes(m.used)) of \(gigabytes(m.total))", expanded: open($showMemory)) {
            VStack(spacing: 10) {
                GeometryReader { g in
                    HStack(spacing: 1.5) {
                        ForEach(parts, id: \.0) { part in
                            Rectangle().fill(part.2.opacity(part.0 == "Cached Files" ? 0.45 : 0.9))
                                .frame(width: max(0, g.size.width * part.1 / m.total))
                        }
                        Spacer(minLength: 0)
                    }
                    .background(Color.primary.opacity(0.1))
                    .clipShape(Capsule())
                }
                .frame(height: 8)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 4) {
                    ForEach(parts + [("Free", m.free, Color.primary.opacity(0.25))], id: \.0) { part in
                        HStack(spacing: 5) {
                            Circle().fill(part.2).frame(width: 6, height: 6)
                            Text(part.0).font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Text(gigabytes(part.1)).font(.system(size: 11, weight: .medium).monospacedDigit())
                        }
                    }
                }
                Divider()
                list(apps, value: { $0.memory }, text: { gigabytes($0.memory) }, color: .blue)
            }
        }
    }

    private var cpuCard: some View {
        let c = p.cpu
        let apps = Array(p.procs.filter { $0.cpu >= 0.1 }.sorted { $0.cpu > $1.cpu }.prefix(6))
        return Collapsible(symbol: "cpu", title: "CPU",
                           summary: String(format: "%.0f%%", c.total * 100), expanded: open($showCPU)) {
            VStack(spacing: 10) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(c.cores.enumerated()), id: \.offset) { _, busy in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.1))
                            RoundedRectangle(cornerRadius: 2).fill(Color.blue.gradient).frame(height: max(2, 34 * busy))
                        }
                        .frame(height: 34)
                    }
                }
                HStack {
                    legend("User", c.user, .blue); Spacer()
                    legend("System", c.system, .red); Spacer()
                    legend("Idle", max(1 - c.total, 0), Color.primary.opacity(0.25))
                }
                Divider()
                list(apps, value: { $0.cpu }, text: { String(format: "%.1f%%", $0.cpu) }, color: .blue)
            }
        }
    }

    private func legend(_ name: String, _ fraction: Double, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(name).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(String(format: "%.0f%%", fraction * 100)).font(.system(size: 11, weight: .medium).monospacedDigit())
        }
    }

    // MARK: Bottom

    private var statsCard: some View {
        Card(padding: 10) {
            HStack(spacing: 0) {
                Stat(value: p.health.map { "\($0)%" } ?? "–", label: "Health")
                Divider().frame(height: 24)
                Stat(value: p.cycles.map(String.init) ?? "–", label: "Cycles")
                Divider().frame(height: 24)
                Stat(value: p.tempC.map { String(format: "%.0f°C", $0) } ?? "–", label: "Temperature")
                Divider().frame(height: 24)
                Stat(value: wattText(abs(p.batteryW)), label: p.batteryW > 0 ? "Charging At" : "Battery Draw")
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 1) {
            Divider().padding(.bottom, 4)
            MenuRow(title: "Open at Login", checked: p.launchAtLogin) { p.toggleLaunchAtLogin() }
            if p.error != nil || !p.helperInstalled { MenuRow(title: "Reinstall Helper…", checked: false) { p.installHelper() } }
            MenuRow(title: "Quit Juice", checked: false, shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private func syncSlider() { if p.limit < 100 { sliderLimit = Double(p.limit) } }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The panel scrolls once it would be taller than the screen (e.g. with every section open).
struct PanelView: View {
    @ObservedObject var p: Power
    @State private var contentHeight: CGFloat = 600

    var body: some View {
        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 900) - 24
        ScrollView(.vertical) {
            PanelContent(p: p)
                .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
        }
        .scrollIndicators(.never)
        .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
        .frame(width: 372, height: min(contentHeight, maxHeight))
        .onAppear { p.panelOpened() }
        .onDisappear { p.panelClosed() }
    }
}

// MARK: - App

@main
struct JuiceApp: App {
    @StateObject private var power = Power()

    init() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        // Build / debug helpers: render assets and exit instead of launching the menu bar app.
        if let path = value("--icons") { StatusIcon.renderPreview(to: path); exit(0) }
        if let path = value("--appicon") { StatusIcon.renderAppIcon(to: path); exit(0) }
        if let path = value("--snapshot") {   // [--dark] [--expand] [--drill N]
            _ = NSApplication.shared
            let p = Power()
            Thread.sleep(forTimeInterval: 1)
            p.refresh()
            p.procs = AppEnergy.sample()
            let view = PanelContent(p: p, expandAll: args.contains("--expand"), drill: value("--drill").flatMap(Int.init))
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            let win = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: host.fittingSize),
                               styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            win.displayIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
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
