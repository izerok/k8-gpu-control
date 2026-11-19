import AppKit
import Foundation

let stateDir = "/Users/Shared/K8Tune"
let statePath = stateDir + "/state.plist"

// MARK: - helpers

func sysctlValue(_ key: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
    p.arguments = ["-n", key]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func windowServerCPU() -> Double {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-Ao", "pcpu,comm"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return 0 }
    p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    for line in out.split(separator: "\n") where line.contains("WindowServer") {
        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
        if let first = parts.first, let v = Double(first) { return v }
    }
    return 0
}

func loadAverage() -> Double {
    let raw = sysctlValue("vm.loadavg")          // "{ 1.23 4.56 7.89 }"
    let parts = raw.replacingOccurrences(of: "{", with: "")
                   .replacingOccurrences(of: "}", with: "")
                   .split(separator: " ")
    if parts.count > 1, let v = Double(parts[1]) { return v }
    return 0
}

struct State {
    var profile: String = "balanced"
    var capMHz: Int = 1200
    var autoGovernor: Bool = false
}

func readState() -> State {
    var s = State()
    guard let d = NSDictionary(contentsOfFile: statePath) else { return s }
    if let p = d["profile"] as? String { s.profile = p }
    if let c = d["cap_mhz"] as? Int { s.capMHz = c }
    if let a = d["auto"] as? Bool { s.autoGovernor = a }
    return s
}

func writeState(_ s: State) {
    try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    let d: NSDictionary = ["profile": s.profile, "cap_mhz": s.capMHz, "auto": s.autoGovernor]
    d.write(toFile: statePath, atomically: true)
}

// MARK: - app

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var timer: Timer?
    var state = State()
    var statusLabels: [String: NSTextField] = [:]
    var presetButtons: [NSButton] = []
    var slider: NSSlider!
    var sliderValue: NSTextField!
    var autoCheckbox: NSButton!
    var hint: NSTextField!

    let presets: [(String, String, Int)] = [
        ("静音",   "silent",      800),
        ("省电",   "eco",         1000),
        ("均衡",   "balanced",    1200),
        ("性能",   "performance", 1600),
        ("满速",   "max",         2600),
        ("自动",   "auto",        2600)
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        state = readState()
        buildWindow()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: UI

    func label(_ text: String, _ frame: NSRect, size: CGFloat = 13, bold: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.frame = frame
        l.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        return l
    }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "K8 Tune — GPU 性能与散热控制"
        window.center()
        window.isReleasedWhenClosed = false
        let v = window.contentView!

        v.addSubview(label("K8 GPU 性能与散热控制", NSRect(x: 20, y: 440, width: 520, height: 24), size: 17, bold: true))

        // status box
        let box = NSBox(frame: NSRect(x: 20, y: 250, width: 520, height: 170))
        box.title = "实时状态"
        v.addSubview(box)
        let rows: [(String, String)] = [
            ("gfx",    "当前 GFX 频率"),
            ("mode",   "驱动频率策略"),
            ("cap",    "频率上限"),
            ("ws",     "WindowServer CPU"),
            ("load",   "系统负载 (1 min)")
        ]
        var y: CGFloat = 210
        for (key, title) in rows {
            let name = label(title, NSRect(x: 40, y: y, width: 220, height: 20))
            let val = label("—", NSRect(x: 300, y: y, width: 220, height: 20), bold: true)
            val.alignment = .right
            v.addSubview(name); v.addSubview(val)
            statusLabels[key] = val
            y -= 30
        }

        // presets
        v.addSubview(label("档位", NSRect(x: 20, y: 212, width: 200, height: 20), size: 14, bold: true))
        var x: CGFloat = 20
        for (i, p) in presets.enumerated() {
            let b = NSButton(title: p.0, target: self, action: #selector(presetClicked(_:)))
            b.tag = p.2
            b.identifier = NSUserInterfaceItemIdentifier(p.1)
            b.bezelStyle = .rounded
            b.frame = NSRect(x: x, y: 176, width: 80, height: 30)
            if i == 5 { b.toolTip = "每 2 秒按负载自动调整：高负载降档，低负载恢复" }
            v.addSubview(b)
            presetButtons.append(b)
            x += 88
        }

        // custom slider
        slider = NSSlider(value: Double(state.capMHz), minValue: 800, maxValue: 2600,
                          target: self, action: #selector(sliderChanged(_:)))
        slider.frame = NSRect(x: 20, y: 136, width: 380, height: 24)
        slider.numberOfTickMarks = 7
        slider.allowsTickMarkValuesOnly = false
        v.addSubview(slider)

        sliderValue = label("\(state.capMHz) MHz", NSRect(x: 406, y: 138, width: 72, height: 20), bold: true)
        sliderValue.alignment = .center
        v.addSubview(sliderValue)

        let apply = NSButton(title: "应用", target: self, action: #selector(applyCustom))
        apply.bezelStyle = .rounded
        apply.frame = NSRect(x: 480, y: 134, width: 60, height: 28)
        v.addSubview(apply)

        // auto governor
        autoCheckbox = NSButton(checkboxWithTitle: "负载联动（高负载自动降档，低负载恢复到档位上限）",
                                target: self, action: #selector(autoToggled))
        autoCheckbox.frame = NSRect(x: 20, y: 100, width: 520, height: 24)
        autoCheckbox.state = state.autoGovernor ? .on : .off
        v.addSubview(autoCheckbox)

        // fan note
        let note = label("风扇说明：K8 的风扇由 BIOS/EC 按固件温度控制，macOS 无法直接设转速。" +
                         "本应用通过 GPU 频率上限与负载联动降低发热，从而让固件自动降速。",
                         NSRect(x: 20, y: 44, width: 520, height: 44))
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 2
        note.textColor = .secondaryLabelColor
        v.addSubview(note)

        hint = label("档位会在 1 秒内由后台守护进程应用", NSRect(x: 20, y: 16, width: 520, height: 20))
        hint.textColor = .secondaryLabelColor
        v.addSubview(hint)

        highlightPreset()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: actions

    @objc func presetClicked(_ sender: NSButton) {
        let name = sender.identifier?.rawValue ?? "balanced"
        state.profile = name
        state.capMHz = sender.tag
        writeState(state)
        slider.doubleValue = Double(state.capMHz)
        sliderValue.stringValue = "\(state.capMHz) MHz"
        highlightPreset()
    }

    @objc func sliderChanged(_ sender: NSSlider) {
        sliderValue.stringValue = "\(Int(sender.doubleValue.rounded())) MHz"
    }

    @objc func applyCustom() {
        state.profile = "custom"
        state.capMHz = Int(slider.doubleValue.rounded())
        writeState(state)
        highlightPreset()
    }

    @objc func autoToggled() {
        state.autoGovernor = (autoCheckbox.state == .on)
        writeState(state)
    }

    func highlightPreset() {
        for b in presetButtons {
            let active = (b.identifier?.rawValue == state.profile)
            b.bezelColor = active ? NSColor.controlAccentColor : nil
        }
    }

    // MARK: refresh

    func refresh() {
        let gfx = sysctlValue("debug.phx_pm_gfxclk")
        let mode = sysctlValue("debug.phx_pm_mode")
        let cap = sysctlValue("debug.phx_pm_gfx_max")
        let modeText: String
        switch mode {
        case "0": modeText = "0 · PMFW 默认"
        case "1": modeText = "1 · 驱动自动范围"
        case "2": modeText = "2 · 负载调节器"
        default: modeText = mode.isEmpty ? "—" : mode
        }
        statusLabels["gfx"]?.stringValue = gfx.isEmpty ? "—" : gfx + " MHz"
        statusLabels["mode"]?.stringValue = modeText
        statusLabels["cap"]?.stringValue = (cap.isEmpty || cap == "0") ? "—" : cap + " MHz"
        statusLabels["ws"]?.stringValue = String(format: "%.0f %%", windowServerCPU())
        statusLabels["load"]?.stringValue = String(format: "%.2f", loadAverage())

        if state.autoGovernor && state.profile != "auto" {
            hint.stringValue = "负载联动已开启：目标上限 \(state.capMHz) MHz，当前实时 \(gfx.isEmpty ? "—" : gfx) MHz"
        } else {
            hint.stringValue = "档位会在 1 秒内由后台守护进程应用"
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
