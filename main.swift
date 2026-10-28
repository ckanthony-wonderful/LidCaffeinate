// LidCaffeinate — menu-bar port of the `lidcaffeinate` script.
// Keeps the Mac awake with the lid closed (on battery too) while the app is open,
// keeps the network alive (pings, joins a hotspot when it drops), releases the
// hold at a battery threshold and re-arms above it or on AC. Quitting restores sleep.
//
// Lid-closed sleep on battery needs `pmset disablesleep 1`, which needs root.
// The app runs `sudo -n /usr/bin/pmset -a disablesleep 0|1`, allowed by a one-line
// rule in /etc/sudoers.d/lidcaffeinate that the menu can install (admin prompt once).

import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import ServiceManagement
import SwiftUI
import SQLite3

// MARK: - Settings

enum Settings {
    static let d = UserDefaults.standard
    static func register() {
        d.register(defaults: [
            "enabled": true,
            "threshold": 45,          // release hold at/below this % on battery; 0 = never
            "sleepAtThreshold": false,
            "keepDisplayAwake": true, // caffeinate -d parity
            "pingHost": "1.1.1.1",
            "pingInterval": 30,       // seconds between network checks
            "hotspot": "",            // Wi-Fi to join when the network drops; empty = off
            "showTimes": true,        // two time rows next to the menu-bar icon
            "topRowLidClosed": true,      // top row (time to release %) estimates with the lid-closed draw
            "bottomRowLidClosed": false,  // bottom row (time to 0%) estimates with the lid-open draw
            "lidClosedWattsLearned": 0.0, // learned while the lid is closed on battery, kept across launches
        ])
    }
    static var enabled: Bool { get { d.bool(forKey: "enabled") } set { d.set(newValue, forKey: "enabled") } }
    static var threshold: Int { get { d.integer(forKey: "threshold") } set { d.set(newValue, forKey: "threshold") } }
    static var sleepAtThreshold: Bool { get { d.bool(forKey: "sleepAtThreshold") } set { d.set(newValue, forKey: "sleepAtThreshold") } }
    static var keepDisplayAwake: Bool { get { d.bool(forKey: "keepDisplayAwake") } set { d.set(newValue, forKey: "keepDisplayAwake") } }
    static var pingInterval: Int { get { d.integer(forKey: "pingInterval") } set { d.set(newValue, forKey: "pingInterval") } }
    static var pingHost: String { get { d.string(forKey: "pingHost") ?? "1.1.1.1" } set { d.set(newValue, forKey: "pingHost") } }
    static var lidClosedWattsLearned: Double { get { d.double(forKey: "lidClosedWattsLearned") } set { d.set(newValue, forKey: "lidClosedWattsLearned") } }
    static var topRowLidClosed: Bool { get { d.bool(forKey: "topRowLidClosed") } set { d.set(newValue, forKey: "topRowLidClosed") } }
    static var bottomRowLidClosed: Bool { get { d.bool(forKey: "bottomRowLidClosed") } set { d.set(newValue, forKey: "bottomRowLidClosed") } }
    static var showTimes: Bool { get { d.bool(forKey: "showTimes") } set { d.set(newValue, forKey: "showTimes") } }
    static var hotspot: String { get { d.string(forKey: "hotspot") ?? "" } set { d.set(newValue, forKey: "hotspot") } }
}

// MARK: - Shell helpers

@discardableResult
func run(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice   // sudo -n must never wait on a tty
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Runs a shell command as root via the standard macOS admin password dialog.
func runAsAdmin(_ shell: String) -> Bool {
    let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    var err: NSDictionary?
    NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&err)
    return err == nil
}

// MARK: - Power

struct BatteryInfo {
    var pct: Int? = nil
    var onAC = true
    var charging = false
    var toEmptyMin: Int? = nil   // system estimate, nil while "calculating"
    var toFullMin: Int? = nil
    var mAh: Int? = nil          // charge left, from the battery gauge
    var mV: Int? = nil
    var mA: Int? = nil           // averaged current, negative = discharging, positive = charging
    var mAhMax: Int? = nil
    var fullyCharged = false
    var systemLoadW: Double? = nil  // what the computer itself draws, reported on AC too
    var powerInW: Double? = nil     // power arriving from the charger
    var systemToFullMin: Int? = nil // macOS's own estimate, shown for comparison
    var lidClosed = false

    /// Power the computer is using right now, in watts (also on AC: "if we unplug now").
    var watts: Double? {
        if let w = systemLoadW, w > 0.3 { return w }
        guard let a = mA, a < 0, let v = mV else { return nil }
        return Double(-a) * Double(v) / 1_000_000
    }
    /// Energy between the current level and `target` %, in watt-hours.
    func energyWh(downTo target: Int) -> Double? {
        guard let pct, pct > 0, let mAh, let mV else { return nil }
        return Double(mAh) * Double(mV) / 1_000_000 * Double(max(0, pct - target)) / Double(pct)
    }
}

enum Power {
    static func battery() -> BatteryInfo {
        var b = BatteryInfo()
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return b }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        b.onAC = providing == kIOPMACPowerKey
        guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return b }
        for src in list {
            guard let desc = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cur = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            b.pct = cur * 100 / max
            b.charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            if let m = desc[kIOPSTimeToEmptyKey] as? Int, m > 0 { b.toEmptyMin = m }
            if let m = desc[kIOPSTimeToFullChargeKey] as? Int, m > 0 { b.toFullMin = m }
            break
        }
        if b.toEmptyMin == nil, !b.onAC {
            let s = IOPSGetTimeRemainingEstimate()
            if s > 0 { b.toEmptyMin = Int(s / 60) }
        }
        if let gauge = service("AppleSmartBattery") {
            b.mAh = number(gauge, "AppleRawCurrentCapacity")
            b.mV = number(gauge, "Voltage")
            b.mA = number(gauge, "Amperage")
            b.mAhMax = number(gauge, "AppleRawMaxCapacity")
            b.fullyCharged = number(gauge, "FullyCharged") == 1
            if let t = IORegistryEntryCreateCFProperty(gauge, "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any], let mw = (t["SystemLoad"] as? NSNumber)?.doubleValue, mw > 0 {
                b.systemLoadW = mw / 1000
                if let pin = (t["SystemPowerIn"] as? NSNumber)?.doubleValue, pin > 0 { b.powerInW = pin / 1000 }
            }
            IOObjectRelease(gauge)
        }
        if let root = service("IOPMrootDomain") {
            b.lidClosed = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Bool ?? false
            IOObjectRelease(root)
        }
        // time to full: macOS's estimate (it knows the charger's power and the slowdown near full).
        // Right after plugging in macOS may have none yet; then use a rough estimate.
        b.systemToFullMin = b.toFullMin
        if b.onAC, b.charging {
            if let h = ChargeModel.historyMinutes(b) { b.toFullMin = h }                 // this Mac's own charging history
            else if b.toFullMin == nil, let est = ChargeModel.minutesToFull(b) { b.toFullMin = est }
        }
        // macOS can sit on "calculating" for minutes; fall back to charge / live draw
        if b.toEmptyMin == nil, !b.onAC, let e = b.energyWh(downTo: 0), let w = b.watts, w > 0.3 {
            b.toEmptyMin = Int(e / w * 60)
        }
        return b
    }

    static func service(_ name: String) -> io_service_t? {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))
        return s == 0 ? nil : s
    }

    static func number(_ s: io_service_t, _ key: String) -> Int? {
        let v = IORegistryEntryCreateCFProperty(s, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
        return v.map { Int(truncatingIfNeeded: $0.int64Value) }   // Amperage is a signed value stored as 64-bit
    }

    /// Time to `target` % at a given draw: "at this rate, how long can we still go".
    static func minutes(to target: Int, _ b: BatteryInfo, watts w: Double) -> Int? {
        guard w > 0, let e = b.energyWh(downTo: target) else { return nil }
        return Int(e / w * 60)
    }

    /// Linear share of the time-to-empty estimate spent getting from pct down to target.
    static func minutes(to target: Int, _ b: BatteryInfo) -> Int? {
        guard let pct = b.pct, let e = b.toEmptyMin, pct > 0 else { return nil }
        if pct <= target { return 0 }
        return e * (pct - target) / pct
    }

    /// Current system-wide SleepDisabled value as reported by `pmset -g`.
    static func sleepDisabled() -> Bool {
        let out = run("/usr/bin/pmset", ["-g"]).out
        return out.split(separator: "\n").contains { line in
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            return f.count >= 2 && f[0] == "SleepDisabled" && f[1] == "1"
        }
    }

    /// `pmset -a disablesleep N` through the passwordless sudo rule. false = rule missing.
    static func setSleepDisabled(_ on: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]).status == 0
    }
}

// MARK: - Charging model

/// Rough time to full, used only until macOS has its own estimate (right after plugging in):
/// charge still needed divided by the current charging speed, slowing down above 80%.
enum ChargeModel {
    static let taperDefault: [Double] = [1, 1, 1, 1, 1, 1, 1, 1, 0.55, 0.3]

    static func minutesToFull(_ b: BatteryInfo) -> Int? {
        guard let cur = b.mAh, let mx = b.mAhMax, mx > cur, let a = b.mA, a > 50 else { return nil }
        let live = Double(a) / 60                                      // mAh per minute right now
        let liveBand = min(9, cur * 10 / mx)
        var minutes = 0.0
        for band in liveBand...9 {
            let lo = Double(mx) * Double(band) / 10, hi = Double(mx) * Double(band + 1) / 10
            let need = hi - max(Double(cur), lo)
            if need > 0 { minutes += need / max(live * taperDefault[band] / taperDefault[liveBand], 1) }
        }
        return Int(minutes.rounded())
    }

    /// Time to full from this Mac's charging history: learned minutes per 1% for every level still to go.
    /// Below 80% (full-speed charging) it's scaled to today's charger and load; the slowdown near full comes from history.
    static func historyMinutes(_ b: BatteryInfo) -> Int? {
        guard let pct = b.pct, pct < 100 else { return nil }
        let cur = min(9, pct / 10)
        let ref = max(PowerHistory.chargePeakW, b.powerInW ?? 0)                 // this charger's power
        guard let histNow = PowerHistory.chargeRate(cur, refW: ref) else { return nil }
        var scale = 1.0
        if cur < 8, let a = b.mA, a > 50, let mx = b.mAhMax {
            let liveNow = 60 * Double(mx) / (100 * Double(a))      // minutes per 1% at today's charging speed
            scale = min(3, max(0.5, liveNow / histNow))
        }
        var m = 0.0
        for p in pct..<100 {
            let band = min(9, p / 10)
            guard let r = PowerHistory.chargeRate(band, refW: ref) else { return nil }
            m += band < 8 ? r * scale : r
        }
        return Int(m.rounded())
    }
}

// MARK: - Power history (macOS power log)

/// One past charge: its peak power in (identifies the charger) and the time / % gained per 10% band.
struct ChargeSession: Codable { var peak: Double; var t: [Double]; var d: [Double] }

struct HistoryResult: Codable {
    var chargeMinutesPerPercent: [Double]   // per 10% band; -1 = not enough data
    var lidClosedWatts: Double?             // screen off, on battery, awake
    var lidClosedMinutes: Double
    var days: Double
    var screenShareW: Double? = nil         // how much less the Mac draws once the screen is off (learned from lid closes)
    var lidClosePairs: Int? = nil           // lid closes on battery with a usable before/after
    var sessions: [ChargeSession]? = nil    // per-charge stats, to match past charges to today's charger
}

/// Learns from the power log macOS keeps on every Mac (readable without admin rights):
/// how long each 1% took to charge, and the power draw while the screen was off on battery.
enum PowerHistory {
    static let path = "/private/var/db/powerlog/Library/BatteryLife/CurrentPowerlog.PLSQL"
    static var result: HistoryResult? = load()
    static var lastRefresh: Date?
    static var refreshing = false

    static func load() -> HistoryResult? {
        guard let data = UserDefaults.standard.data(forKey: "powerHistory") else { return nil }
        return try? JSONDecoder().decode(HistoryResult.self, from: data)
    }

    /// Re-read the log in the background, at most hourly unless forced. Keeps the last result if the log can't be read.
    static func refresh(force: Bool = false, done: (() -> Void)? = nil) {
        if refreshing { return }
        if !force, let l = lastRefresh, Date().timeIntervalSince(l) < 3600 { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async {
            let r = compute()
            DispatchQueue.main.async {
                refreshing = false
                lastRefresh = Date()
                if let r {
                    result = r
                    if let d = try? JSONEncoder().encode(r) { UserDefaults.standard.set(d, forKey: "powerHistory") }
                }
                done?()
            }
        }
    }

    /// Peak power in during the current charge (set by the app), used to match past charges to this charger.
    static var chargePeakW = 0.0

    /// Minutes per 1% per band from past charges whose peak power in was at least 70% of this charger's.
    /// Bands without such data use all history; -1 = no data.
    static func curve(refW: Double) -> [Double] {
        guard let r = result, r.chargeMinutesPerPercent.count == 10 else { return [] }
        let all = r.chargeMinutesPerPercent
        guard refW > 0, let ss = r.sessions, ss.contains(where: { $0.peak > 0 }) else { return all }
        var t = [Double](repeating: 0, count: 10), d = t
        for s in ss where s.peak >= 0.7 * refW && s.t.count == 10 && s.d.count == 10 {
            for b in 0..<10 { t[b] += s.t[b]; d[b] += s.d[b] }
        }
        return (0..<10).map { d[$0] >= 3 ? t[$0] / 60 / d[$0] : all[$0] }
    }

    /// Minutes per 1% for a band; a band without data borrows the nearest one, preferring the slower band above.
    static func chargeRate(_ band: Int, refW: Double = 0) -> Double? {
        let m = curve(refW: refW)
        guard m.count == 10 else { return nil }
        if m[band] > 0 { return m[band] }
        for k in 1..<10 {
            for c in [band + k, band - k] where (0..<10).contains(c) && m[c] > 0 { return m[c] }
        }
        return nil
    }

    /// Screen share assumed until at least 3 lid closes have been seen.
    static let defaultScreenShare = 2.0

    /// The current log plus macOS's older daily archives, unpacked once into the app's cache folder.
    static func logFiles() -> [String] {
        let fm = FileManager.default
        var files: [String] = []
        let archDir = "/private/var/db/powerlog/Library/BatteryLife/Archives"
        if let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("LidCaffeinate/powerlog") {
            try? fm.createDirectory(at: cache, withIntermediateDirectories: true)
            let archives = ((try? fm.contentsOfDirectory(atPath: archDir)) ?? []).filter { $0.hasSuffix(".PLSQL.gz") }.sorted()
            let wanted = Set(archives.map { String($0.dropLast(3)) })
            for name in (try? fm.contentsOfDirectory(atPath: cache.path)) ?? [] where !wanted.contains(name) {
                try? fm.removeItem(at: cache.appendingPathComponent(name))       // macOS dropped that archive
            }
            for a in archives {
                let out = cache.appendingPathComponent(String(a.dropLast(3)))
                if !fm.fileExists(atPath: out.path), fm.createFile(atPath: out.path, contents: nil),
                   let h = FileHandle(forWritingAtPath: out.path) {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
                    p.arguments = ["-c", "\(archDir)/\(a)"]
                    p.standardOutput = h
                    p.standardError = FileHandle.nullDevice
                    var ok = false
                    if (try? p.run()) != nil { p.waitUntilExit(); ok = p.terminationStatus == 0 }
                    try? h.close()
                    if !ok { try? fm.removeItem(at: out) }
                }
                if fm.fileExists(atPath: out.path) { files.append(out.path) }
            }
        }
        files.append(path)
        return files
    }

    struct Row { var t: Double; var level: Double?; var charging, ext, full: Bool; var mA, mV, adapterW: Double? }

    /// Reads one log; checks which tables and columns exist so it works across Macs and macOS versions.
    static func read(_ file: String) -> (rows: [Row], backlight: [(Double, Int)])? {
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(file)?immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        func query(_ sql: String, _ each: (OpaquePointer) -> Void) -> Bool {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let s = st else { return false }
            defer { sqlite3_finalize(s) }
            while sqlite3_step(s) == SQLITE_ROW { each(s) }
            return true
        }
        func num(_ s: OpaquePointer, _ i: Int32) -> Double? {
            sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_double(s, i)
        }
        var cols = Set<String>()
        _ = query("pragma table_info('PLBatteryAgent_EventBackward_Battery')") { s in
            if let c = sqlite3_column_text(s, 1) { cols.insert(String(cString: c)) }
        }
        guard cols.contains("timestamp"), cols.contains("Level") else { return nil }
        func col(_ names: [String], _ fallback: String) -> String { names.first(where: cols.contains) ?? fallback }
        let sql = "select timestamp, Level, \(col(["IsCharging"], "0")), \(col(["ExternalConnected"], "0")), " +
                  "\(col(["FullyCharged"], "0")), \(col(["InstantAmperage", "Amperage"], "NULL")), \(col(["Voltage"], "NULL")), " +
                  "\(col(["AdapterPower"], "NULL")) " +
                  "from PLBatteryAgent_EventBackward_Battery order by timestamp"
        var rows: [Row] = []
        guard query(sql, { s in
            rows.append(Row(t: sqlite3_column_double(s, 0), level: num(s, 1), charging: sqlite3_column_int(s, 2) == 1,
                            ext: sqlite3_column_int(s, 3) == 1, full: sqlite3_column_int(s, 4) == 1, mA: num(s, 5), mV: num(s, 6),
                            adapterW: num(s, 7)))
        }) else { return nil }
        var backlight: [(Double, Int)] = []
        _ = query("select timestamp, Active from PLDisplayAgent_EventPoint_Display where Block='Backlight' order by timestamp") { s in
            backlight.append((sqlite3_column_double(s, 0), Int(sqlite3_column_int(s, 1))))
        }
        return (rows, backlight)
    }

    static func compute() -> HistoryResult? {
        // merge all logs in time order, skipping overlap
        var parts = logFiles().compactMap(read).filter { !$0.rows.isEmpty }
        parts.sort { $0.rows[0].t < $1.rows[0].t }
        var rows: [Row] = [], backlight: [(Double, Int)] = []
        for p in parts {
            let lastT = rows.last?.t ?? 0
            rows += p.rows.filter { $0.t > lastT }
            let lastB = backlight.last?.0 ?? 0
            backlight += p.backlight.filter { $0.0 > lastB }
        }
        guard rows.count > 1 else { return nil }

        var bandT = [Double](repeating: 0, count: 10), bandD = bandT
        var offSecs = 0.0, offWattSecs = 0.0, bi = -1
        var sessions: [ChargeSession] = [], sessionOpen = false
        let zeros = [Double](repeating: 0, count: 10)
        for i in 0..<(rows.count - 1) {
            let a = rows[i], b = rows[i + 1], dt = b.t - a.t
            guard dt > 0, dt < 1800 else { sessionOpen = false; continue }
            // charging curve: all charging time per 10% band, including time sitting on the same %,
            // also kept per charging session with its peak power in, to match the charger later
            if a.charging, a.ext {
                if !sessionOpen { sessions.append(ChargeSession(peak: 0, t: zeros, d: zeros)); sessionOpen = true }
                let k = sessions.count - 1
                sessions[k].peak = max(sessions[k].peak, a.adapterW ?? 0)
                if b.ext, !a.full, let l0 = a.level, let l1 = b.level, l0 < 100 {
                    let band = min(9, Int(l0 / 10)), gain = max(0, l1 - l0)
                    bandT[band] += dt; bandD[band] += gain
                    sessions[k].t[band] += dt; sessions[k].d[band] += gain
                }
            } else { sessionOpen = false }
            // screen-off draw: on battery, awake (no sleep gap), backlight off for at least 2 minutes
            while bi + 1 < backlight.count && backlight[bi + 1].0 <= a.t { bi += 1 }
            if !a.ext, !b.ext, dt <= 300, bi >= 0, backlight[bi].1 == 0, a.t - backlight[bi].0 >= 120,
               let i0 = a.mA, let i1 = b.mA, let v0 = a.mV, let v1 = b.mV {
                offWattSecs += -(i0 * v0 + i1 * v1) / 2 / 1_000_000 * dt
                offSecs += dt
            }
        }

        // screen share: draw in the 10 minutes before each lid close on battery, minus the draw after it
        func avgW(_ from: Double, _ to: Double) -> (Double, Double) {
            var lo = 0, hi = rows.count
            while lo < hi { let m = (lo + hi) / 2; if rows[m].t < from { lo = m + 1 } else { hi = m } }
            var ws = 0.0, secs = 0.0, i = lo
            while i + 1 < rows.count, rows[i + 1].t <= to {
                let a = rows[i], b = rows[i + 1], dt = b.t - a.t
                if !a.ext, !b.ext, dt > 0, dt <= 300, let i0 = a.mA, let i1 = b.mA, let v0 = a.mV, let v1 = b.mV {
                    ws += -(i0 * v0 + i1 * v1) / 2 / 1_000_000 * dt; secs += dt
                }
                i += 1
            }
            return (secs > 0 ? ws / secs : 0, secs)
        }
        var diffs: [Double] = []
        for (k, e) in backlight.enumerated() where e.1 == 0 {
            let on = backlight[(k + 1)...].first(where: { $0.1 == 1 })?.0 ?? e.0 + 1800
            let before = avgW(e.0 - 600, e.0), after = avgW(e.0 + 120, min(on, e.0 + 3600))
            if before.1 >= 120, after.1 >= 120 { diffs.append(before.0 - after.0) }
        }
        var share: Double? = nil
        if diffs.count >= 3 {
            let d = diffs.sorted(), m = d.count / 2
            share = min(10, max(0, d.count % 2 == 1 ? d[m] : (d[m - 1] + d[m]) / 2))
        }

        return HistoryResult(chargeMinutesPerPercent: (0..<10).map { bandD[$0] >= 3 ? bandT[$0] / 60 / bandD[$0] : -1 },
                             lidClosedWatts: offSecs >= 600 && offWattSecs > 0 ? offWattSecs / offSecs : nil,
                             lidClosedMinutes: offSecs / 60,
                             days: (rows[rows.count - 1].t - rows[0].t) / 86400,
                             screenShareW: share, lidClosePairs: diffs.count,
                             sessions: sessions.filter { $0.d.reduce(0, +) > 0 })
    }
}

// MARK: - Sudoers rule

enum Permission {
    static let path = "/etc/sudoers.d/lidcaffeinate"
    static var installed: Bool { FileManager.default.fileExists(atPath: path) }

    static func install() -> Bool {
        let user = NSUserName()
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        // validate with visudo before installing so a bad rule can never break sudo
        let sh = """
        t=$(/usr/bin/mktemp) && /usr/bin/printf '%s\\n' '\(rule)' > "$t" && \
        /usr/sbin/visudo -cf "$t" >/dev/null && \
        /usr/bin/install -m 0440 -o root -g wheel "$t" \(path); r=$?; /bin/rm -f "$t"; exit $r
        """
        return runAsAdmin(sh)
    }

    static func uninstall() -> Bool {
        runAsAdmin("/usr/bin/pmset -a disablesleep 0; /bin/rm -f \(path)")
    }
}

// MARK: - Menu-bar icon

enum CupStyle { case none, filled, outline }

enum IconRenderer {
    static let height: CGFloat = 22

    static func hmm(_ m: Int?) -> String {
        guard let m else { return "--:--" }
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    /// Two rows next to the icon: (label, time).
    /// estimate(target%, lidClosed) -> (minutes, lid-closed rate actually used)
    typealias Estimator = (Int, Bool) -> (Int?, Bool)

    static func rows(_ b: BatteryInfo, threshold t: Int, topClosed: Bool, bottomClosed: Bool,
                     estimate: Estimator, single: Bool = false) -> [(String, String)] {
        guard let pct = b.pct else { return [] }
        if single {
            // not keeping awake: one big timer — time to full on AC, time to empty on battery
            if b.onAC { return [("", b.fullyCharged || pct >= 100 ? "✓" : !b.charging ? "paused" : hmm(b.toFullMin))] }
            let e = estimate(0, bottomClosed)
            return [(e.1 ? "☾" : "", hmm(e.0))]
        }
        if b.onAC {
            // top: how long we'd last if unplugged now; bottom: time to full
            let target = t > 0 ? t : 0
            let e = estimate(target, topClosed)
            let full = b.fullyCharged || pct >= 100 ? "✓" : !b.charging ? "paused" : hmm(b.toFullMin)
            return [((e.1 ? "☾" : "") + "\(target)%", pct <= target ? "—" : hmm(e.0)), ("AC", full)]
        }
        var r: [(String, String)] = []
        if t > 0 {
            let e = estimate(t, topClosed)
            r.append(((e.1 ? "☾" : "") + "\(t)%", pct <= t ? "—" : hmm(e.0)))
        }
        let e = estimate(0, bottomClosed)
        r.append(((e.1 ? "☾" : "") + "0%", hmm(e.0)))
        return r
    }

    static func image(_ b: BatteryInfo, cup: CupStyle, low: Bool, rows: [(String, String)], big: Bool = false) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: big ? 13 : 9, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let labelW = rows.map { ($0.0 as NSString).size(withAttributes: attrs).width }.max() ?? 0
        let timeW = rows.map { ($0.1 as NSString).size(withAttributes: attrs).width }.max() ?? 0
        let iconW: CGFloat = cup == .none ? 24 : 22
        let gap: CGFloat = labelW > 0 ? 3 : 0
        let textW = rows.isEmpty ? 0 : ceil(labelW + gap + timeW) + 4
        let size = NSSize(width: iconW + textW, height: height)

        let img = NSImage(size: size, flipped: false) { _ in
            let ink: NSColor = low ? .labelColor : .black
            ink.setFill(); ink.setStroke()
            let ctx = NSGraphicsContext.current!.cgContext

            // battery: bigger when alone, compact under the cup
            let body = cup == .none ? NSRect(x: 0.5, y: 5.5, width: 21, height: 11)
                                    : NSRect(x: 0.5, y: 1.5, width: 19, height: 9)
            let frame = NSBezierPath(roundedRect: body, xRadius: 2.8, yRadius: 2.8)
            frame.lineWidth = 1
            frame.stroke()
            let nub = NSRect(x: body.maxX + 1, y: body.midY - 2, width: 1.5, height: 4)
            NSBezierPath(roundedRect: nub, xRadius: 0.75, yRadius: 0.75).fill()

            let inner = body.insetBy(dx: 1.5, dy: 1.5)
            let frac = CGFloat(max(0, min(100, b.pct ?? 0))) / 100
            let fill = NSRect(x: inner.minX, y: inner.minY, width: max(frac > 0 ? 1.5 : 0, inner.width * frac), height: inner.height)
            (low ? NSColor.systemRed : ink).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 1.2, yRadius: 1.2).fill()
            ink.setFill()

            // charging bolt: solid, with a transparent halo so it reads on top of the fill (macOS style)
            if b.onAC {
                let bolt = boltPath(in: NSRect(x: body.midX - 3, y: body.minY + 0.8, width: 6, height: body.height - 1.6))
                ctx.saveGState()
                NSBezierPath(rect: inner).addClip()   // halo only cuts the fill, never the outline
                ctx.setBlendMode(.clear)
                bolt.lineWidth = 1.6; bolt.lineJoinStyle = .round
                bolt.stroke(); bolt.fill()
                ctx.restoreGState()
                bolt.fill()
            }

            // coffee cup sitting on the battery (the battery is the saucer)
            if cup != .none {
                let cupPath = NSBezierPath()
                cupPath.move(to: NSPoint(x: 4.5, y: 20.5))
                cupPath.line(to: NSPoint(x: 14, y: 20.5))
                cupPath.line(to: NSPoint(x: 13.3, y: 15.2))
                cupPath.curve(to: NSPoint(x: 9.25, y: 12.2), controlPoint1: NSPoint(x: 12.9, y: 13.0), controlPoint2: NSPoint(x: 11.2, y: 12.2))
                cupPath.curve(to: NSPoint(x: 5.2, y: 15.2), controlPoint1: NSPoint(x: 7.3, y: 12.2), controlPoint2: NSPoint(x: 5.6, y: 13.0))
                cupPath.close()
                let handle = NSBezierPath(ovalIn: NSRect(x: 11.6, y: 14.6, width: 5, height: 4.6))
                handle.lineWidth = 1.3
                ctx.saveGState()
                NSBezierPath(rect: NSRect(x: 13, y: 0, width: 10, height: height)).addClip()
                handle.stroke()
                ctx.restoreGState()
                if cup == .filled { cupPath.fill() } else { cupPath.lineWidth = 1.1; cupPath.stroke() }
            }

            // two rows: label left, time right-aligned
            let x0 = iconW + 4
            for (i, r) in rows.enumerated() {
                let lineH = font.ascender - font.descender
                let y: CGFloat = rows.count == 1 ? round((height - lineH) / 2) : (i == 0 ? 11 : 1)
                let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
                (r.0 as NSString).draw(at: NSPoint(x: x0, y: y), withAttributes: a)
                let tw = (r.1 as NSString).size(withAttributes: a).width
                (r.1 as NSString).draw(at: NSPoint(x: x0 + labelW + gap + timeW - tw, y: y), withAttributes: a)
            }
            return true
        }
        img.isTemplate = !low   // template = follows light/dark menu bar; low state needs real red
        return img
    }

    static func boltPath(in r: NSRect) -> NSBezierPath {
        let pts: [(CGFloat, CGFloat)] = [(0.62, 1), (0.12, 0.43), (0.46, 0.43), (0.36, 0), (0.88, 0.57), (0.54, 0.57)]
        let p = NSBezierPath()
        for (i, q) in pts.enumerated() {
            let pt = NSPoint(x: r.minX + q.0 * r.width, y: r.minY + q.1 * r.height)
            i == 0 ? p.move(to: pt) : p.line(to: pt)
        }
        p.close()
        return p
    }

    /// Debug: `LidCaffeinate --render-icons DIR` writes PNG previews (light + dark) and exits.
    static func renderPreviews(to dir: String) {
        let full = BatteryInfo(pct: 100, onAC: true, charging: false, toEmptyMin: nil, toFullMin: nil, mAh: 5900, mV: 12900, mA: 0, fullyCharged: true)
        let chg = BatteryInfo(pct: 61, onAC: true, charging: true, toEmptyMin: nil, toFullMin: 52, mAh: 3500, mV: 11800, mA: 4900)
        let bat = BatteryInfo(pct: 61, onAC: false, charging: false, toEmptyMin: 101, toFullMin: nil, mAh: 3500, mV: 11800, mA: -2900)
        let low = BatteryInfo(pct: 18, onAC: false, charging: false, toEmptyMin: 25, toFullMin: nil)
        let cases: [(String, BatteryInfo, CupStyle, Bool)] = [
            ("holding-battery", bat, .filled, false), ("holding-charging", chg, .filled, false),
            ("noperm", bat, .outline, false), ("off-battery", bat, .none, false),
            ("off-full", full, .none, false), ("released-low", low, .none, true),
        ]
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, b, cup, isLow) in cases {
            let est: Estimator = { t, closed in (Power.minutes(to: t, b, watts: closed ? 6 : 14.4), closed) }
            let img = image(b, cup: cup, low: isLow, rows: rows(b, threshold: 45, topClosed: true, bottomClosed: false,
                                                                estimate: est, single: cup == .none), big: cup == .none)
            for dark in [false, true] {
                let scale: CGFloat = 8
                let W = Int((img.size.width + 8) * scale), H = Int((img.size.height + 4) * scale)
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = NSSize(width: img.size.width + 8, height: img.size.height + 4)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                    (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                    NSRect(origin: .zero, size: rep.size).fill()
                    let r = NSRect(x: 4, y: 2, width: img.size.width, height: img.size.height)
                    if img.isTemplate {
                        // tint the template like the menu bar does
                        let t = NSImage(size: img.size, flipped: false) { rr in
                            img.draw(in: rr); (dark ? NSColor.white : NSColor.black).set(); rr.fill(using: .sourceAtop); return true
                        }
                        t.draw(in: r)
                    } else { img.draw(in: r) }
                }
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}

// MARK: - App

enum HoldState { case off, holding, lowBattery, noPermission }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var timer: Timer?
    var activity: NSObjectProtocol?
    var assertions: [IOPMAssertionID] = []
    var assertionsDisplay = false
    var weDisabledSleep = false
    var state: HoldState = .off
    var battery = BatteryInfo()
    var netOK = true
    var netFails = 0
    var lastJoin = ""
    let netQueue = DispatchQueue(label: "net")
    var netBusy = false
    var signalSources: [DispatchSourceSignal] = []
    var lidClosedSince: Date?
    var lastSample: Date?
    var openSamples: [(Date, Double)] = []   // lid-open watts, last 5 minutes
    let live = LiveModel()                    // feeds the Settings window
    var settingsWindow: NSWindow?
    var settingsTabs: NSTabViewController?
    var inTick = false, tickScheduled = false
    var wasCharging = false
    var netTimer: Timer?
    var lidPort: IONotificationPortRef?
    var lidNotifier: io_object_t = 0
    var lidTimer: Timer?
    var lastLid: Bool?
    var netTimerInterval = 0

    func applicationDidFinishLaunching(_ n: Notification) {
        // single instance: a second copy exits without touching sleep settings
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0.processIdentifier != me.processIdentifier }) { exit(0) }
        Settings.register()
        // "run forever while open": no App Nap, no timer coalescing, no automatic termination
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "LidCaffeinate keeps the Mac awake")
        startWatchdog()          // before signal handlers, so the child doesn't inherit SIG_IGN
        installSignalHandlers()

        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly

        // react immediately to plug/unplug and wake, plus a 30s heartbeat like the script
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            Unmanaged<AppDelegate>.fromOpaque(ctx!).takeUnretainedValue().tick()
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        watchLid()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.tick() }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)   // keep ticking while a menu or alert is open
        timer = t

        if !Permission.installed { DispatchQueue.main.async { self.offerPermission() } }
        // Settings window writes UserDefaults directly: apply changes right away (coalesced)
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.inTick, !self.tickScheduled else { return }
            self.tickScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.tickScheduled = false; self.tick() }
        }
        tick()
        PowerHistory.refresh(force: true) { [weak self] in self?.tick() }
    }

    func applicationWillTerminate(_ n: Notification) { release() }

    /// Power management tells us the instant the lid opens or closes.
    func watchLid() {
        guard let root = Power.service("IOPMrootDomain"), let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, .main)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { ctx, _, type, arg in
            guard type == 0xE003_4100 else { return }          // kIOPMMessageClamshellStateChange
            let closed = (UInt(bitPattern: arg) & 1) != 0       // kClamshellStateBit
            Unmanaged<AppDelegate>.fromOpaque(ctx!).takeUnretainedValue().lidChanged(closed: closed)
        }, ctx, &lidNotifier)
        IOObjectRelease(root)
        lidPort = port
        // the notification isn't always delivered to user apps; a cheap registry read every 2 s backs it up
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.pollLid() }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        lidTimer = t
    }

    func pollLid() {
        guard let root = Power.service("IOPMrootDomain") else { return }
        let closed = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool ?? false
        IOObjectRelease(root)
        if lastLid == nil { lastLid = closed; return }
        lidChanged(closed: closed)
    }

    /// Lid closed while holding: let the display sleep and turn it off now, so the panel is really dark.
    /// Skipped when an external display is in use (clamshell mode), so that screen keeps working.
    func lidChanged(closed: Bool) {
        guard closed != lastLid else { return }   // notification and poll may both report the same change
        lastLid = closed
        NSLog("LidCaffeinate: lid %@", closed ? "closed" : "opened")
        if !closed { PowerHistory.refresh(force: true) { [weak self] in self?.updateIcon() } }   // include the lid-closed time just logged
        tick()
        guard closed, state == .holding || state == .noPermission, !Self.externalDisplayActive() else { return }
        run("/usr/bin/pmset", ["displaysleepnow"])
        NSLog("LidCaffeinate: lid closed, display sleep requested")
    }

    static func externalDisplayActive() -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    // SIGTERM/SIGINT/SIGHUP (kill, logout scripts) -> clean quit so sleep is restored.
    func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { NSApp.terminate(nil) }
            s.resume()
            signalSources.append(s)
        }
    }

    // If the app is force-quit or crashes, IOKit assertions die with it but the
    // pmset SleepDisabled flag would persist. A tiny detached watcher resets it.
    func startWatchdog() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 3; done; " +
                             // a restarted instance may already hold again: don't undo it
                             "/usr/bin/pgrep -x LidCaffeinate >/dev/null || " +
                             "/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 </dev/null >/dev/null 2>&1"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    // MARK: hold logic (same rules as the script)

    func tick() {
        inTick = true
        defer { inTick = false }
        battery = Power.battery()
        if battery.charging && !wasCharging { PowerHistory.refresh(force: true) { [weak self] in self?.updateIcon() } }
        wasCharging = battery.charging
        PowerHistory.chargePeakW = battery.onAC && battery.charging ? max(PowerHistory.chargePeakW, battery.powerInW ?? 0) : 0
        PowerHistory.refresh { [weak self] in self?.updateIcon() }   // hourly
        learnDraw()
        let t = Settings.threshold
        let low = t > 0 && !battery.onAC && (battery.pct.map { $0 <= t } ?? false)

        if !Settings.enabled {
            release()
            state = .off
        } else if low {
            if state == .holding || state == .noPermission {
                release()
                if Settings.sleepAtThreshold { run("/usr/bin/pmset", ["sleepnow"]) }
            }
            state = .lowBattery
        } else {
            hold()
        }
        scheduleNetTimer()
        updateIcon()
        live.nowW = battery.watts; live.openW = openWatts; live.closedW = closedWatts
        live.applyHistoryNotes()
        live.permission = Permission.installed
        live.onAC = battery.onAC; live.docked = Self.externalDisplayActive()
    }

    /// Learn the real draw from the battery gauge, every ~30 s on battery:
    ///  - lid open:   rolling 5-minute average = "at the current load" (on AC too, from system load)
    ///  - lid closed: slow running average, saved, skipping 2 min after closing (display/GPU winding down)
    func learnDraw() {
        let now = Date()
        if !battery.lidClosed { lidClosedSince = nil }
        guard let w = battery.watts, w > 0.3 else { return }
        if let l = lastSample, now.timeIntervalSince(l) < 20 { return }
        lastSample = now
        if battery.lidClosed {
            // lid closed on AC usually means an external display: not representative, skip
            guard !battery.onAC else { return }
            guard let since = lidClosedSince else { lidClosedSince = now; return }
            guard now.timeIntervalSince(since) > 120 else { return }
            let old = Settings.lidClosedWattsLearned
            Settings.lidClosedWattsLearned = old > 0 ? old * 0.9 + w * 0.1 : w
        } else {
            openSamples.append((now, w))
            openSamples.removeAll { now.timeIntervalSince($0.0) > 300 }
        }
    }

    var openWatts: Double? {
        openSamples.isEmpty ? battery.watts : openSamples.map(\.1).reduce(0, +) / Double(openSamples.count)
    }
    /// Lid-closed draw: what the Mac is using now minus the screen's share (background work keeps running
    /// after the lid closes). Falls back to the history average, then to live learning.
    var closedWatts: Double? {
        if !battery.lidClosed, let open = openWatts, open > 0.5 {
            return max(0.5, open - (PowerHistory.result?.screenShareW ?? PowerHistory.defaultScreenShare))
        }
        return PowerHistory.result?.lidClosedWatts ?? (Settings.lidClosedWattsLearned > 0 ? Settings.lidClosedWattsLearned : nil)
    }

    /// Minutes to `t` % at the lid-open or lid-closed rate. Lid-closed falls back to lid-open until learned.
    func estimate(_ t: Int, _ closed: Bool) -> (Int?, Bool) {
        if closed, let w = closedWatts { return (Power.minutes(to: t, battery, watts: w), true) }
        if let w = openWatts, let m = Power.minutes(to: t, battery, watts: w) { return (m, false) }
        return (t == 0 ? battery.toEmptyMin : Power.minutes(to: t, battery), false)
    }

    func hold() {
        // lid open: keep the built-in screen on; lid closed: only an external screen (docked) is worth keeping on
        let wantDisplay = Settings.keepDisplayAwake && (!battery.lidClosed || Self.externalDisplayActive())
        if assertions.isEmpty || assertionsDisplay != wantDisplay {
            releaseAssertions()
            var types = ["PreventUserIdleSystemSleep", "PreventSystemSleep", "PreventDiskIdle"] // caffeinate -ims
            if wantDisplay { types.append("PreventUserIdleDisplaySleep") }                      // caffeinate -d
            for t in types {
                var id: IOPMAssertionID = 0
                if IOPMAssertionCreateWithName(t as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                               "LidCaffeinate" as CFString, &id) == kIOReturnSuccess {
                    assertions.append(id)
                }
            }
            assertionsDisplay = wantDisplay
        }
        // re-assert every tick in case something else flipped it back
        if !Power.sleepDisabled() { weDisabledSleep = Power.setSleepDisabled(true) && Power.sleepDisabled() }
        else { weDisabledSleep = true }
        state = weDisabledSleep ? .holding : .noPermission
    }

    func release() {
        releaseAssertions()
        if weDisabledSleep || Power.sleepDisabled() { _ = Power.setSleepDisabled(false) }
        weDisabledSleep = false
    }

    func releaseAssertions() {
        assertions.forEach { IOPMAssertionRelease($0) }
        assertions.removeAll()
    }

    // MARK: network keep-alive

    /// (Re)start the ping timer when the interval setting changes.
    func scheduleNetTimer() {
        let iv = max(5, Settings.pingInterval)
        guard netTimer == nil || netTimerInterval != iv else { return }
        netTimer?.invalidate()
        let t = Timer(timeInterval: TimeInterval(iv), repeats: true) { [weak self] _ in
            if Settings.enabled { self?.checkNetwork() }
        }
        t.tolerance = Double(iv) * 0.1
        RunLoop.main.add(t, forMode: .common)
        netTimer = t
        netTimerInterval = iv
        if Settings.enabled { checkNetwork() }   // check right away on start or change
    }

    func checkNetwork() {
        guard !netBusy else { return }
        netBusy = true
        let host = Settings.pingHost, ssid = Settings.hotspot
        netQueue.async { [weak self] in
            let ok = run("/sbin/ping", ["-c1", "-t2", host]).status == 0
            DispatchQueue.main.async {
                guard let self else { return }
                self.netOK = ok
                self.netFails = ok ? 0 : self.netFails + 1
                // two misses in a row before touching Wi-Fi, so a single dropped ping doesn't reconnect
                if self.netFails == 2, !ssid.isEmpty {
                    self.netQueue.async {
                        let iface = Self.wifiInterface()
                        let r = run("/usr/sbin/networksetup", ["-setairportnetwork", iface, ssid])
                        DispatchQueue.main.async {
                            self.lastJoin = "joined \(ssid) at \(Self.clock()) " + (r.status == 0 && r.out.isEmpty ? "" : "(\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
                            self.netBusy = false
                        }
                    }
                } else {
                    self.netBusy = false
                }
            }
        }
    }

    static func wifiInterface() -> String {
        let lines = run("/usr/sbin/networksetup", ["-listallhardwareports"]).out.split(separator: "\n").map(String.init)
        for (i, l) in lines.enumerated() where l.hasPrefix("Hardware Port: Wi-Fi") && i + 1 < lines.count {
            return lines[i + 1].replacingOccurrences(of: "Device: ", with: "")
        }
        return "en0"
    }

    static func clock() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: Date())
    }

    // MARK: UI

    func updateIcon() {
        let tip: String
        let cup: CupStyle
        switch state {
        case .holding:      cup = .filled;  tip = "Awake: lid can close"
        case .noPermission: cup = .outline; tip = "Awake, but lid-close sleep not disabled (permission missing)"
        case .lowBattery:   cup = .none;    tip = "Released: battery at or below \(Settings.threshold)%"
        case .off:          cup = .none;    tip = "Off: normal sleep"
        }
        let low = !battery.onAC && (state == .lowBattery || (battery.pct ?? 100) <= 20)
        let rows = Settings.showTimes ? IconRenderer.rows(battery, threshold: Settings.threshold, topClosed: Settings.topRowLidClosed,
                                                                bottomClosed: Settings.bottomRowLidClosed, estimate: estimate,
                                                                single: cup == .none) : []
        statusItem.button?.image = IconRenderer.image(battery, cup: cup, low: low, rows: rows, big: cup == .none)
        statusItem.button?.image?.accessibilityDescription = tip
        statusItem.button?.toolTip = "LidCaffeinate — \(tip)"
    }

    static func long(_ m: Int?) -> String {
        guard let m else { return "calculating…" }
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }

    func menuNeedsUpdate(_ menu: NSMenu) { tick(); rebuildMenu() }

    /// The menu is for status and quick switches; everything else lives in Settings.
    func rebuildMenu() {
        menu.removeAllItems()
        func info(_ s: String, _ symbol: String) {
            let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(i)
        }
        func item(_ s: String, _ sel: Selector, on: Bool? = nil, key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: s, action: sel, keyEquivalent: key); i.target = self
            if let on { i.state = on ? .on : .off }
            menu.addItem(i); return i
        }

        // status
        switch state {
        case .holding:      info("Keeping awake — lid can close", "cup.and.saucer.fill")
        case .noPermission: info("Awake, but lid-close sleep isn’t allowed", "exclamationmark.triangle")
        case .lowBattery:   info("Released at \(Settings.threshold)% battery", "battery.25percent")
        case .off:          info("Off — normal sleep", "moon.zzz")
        }
        let pct = battery.pct.map { "\($0)%" } ?? "—"
        let draw = battery.watts.map { String(format: " · %.1f W", $0) } ?? ""
        if battery.onAC {
            let s = battery.fullyCharged || (battery.pct ?? 0) >= 100 ? "Fully charged"
                : battery.charging ? "Full in \(Self.long(battery.toFullMin))" : "Charging paused"
            info("\(pct) · \(s)\(draw)", "bolt.fill")
            if battery.charging, let a = battery.mA, a > 0, let v = battery.mV {
                var c = String(format: "Charging at %.0f W", Double(a) * Double(v) / 1_000_000)
                if let pin = battery.powerInW, let load = battery.systemLoadW {
                    c += String(format: " · %.0f W in, %.0f W used by the Mac", pin, load)
                }
                if let sys = battery.systemToFullMin, sys != battery.toFullMin { c += " · macOS: \(Self.long(sys))" }
                info(c, "powerplug")
            }
        } else {
            info("\(pct) · On battery\(draw)", "battery.75percent")
        }
        let t = Settings.threshold, unplug = battery.onAC ? "If unplugged: " : ""
        func how(_ e: (Int?, Bool)) -> String { e.1 ? " · lid closed" : " · lid open" }
        if t > 0 {
            if (battery.pct ?? 0) <= t { info("\(t)% reached", "clock") }
            else { let e = estimate(t, Settings.topRowLidClosed); info("\(unplug)\(t)% in \(Self.long(e.0))\(how(e))", "clock") }
        }
        let e0 = estimate(0, Settings.bottomRowLidClosed)
        info("\(unplug)Empty in \(Self.long(e0.0))\(how(e0))", "clock")
        if !netOK {
            info("Network unreachable" + (Settings.hotspot.isEmpty ? "" : " — joining \(Settings.hotspot)"), "wifi.exclamationmark")
        }
        menu.addItem(.separator())

        // quick switches
        _ = item("Keep Awake", #selector(toggleEnabled), on: Settings.enabled)
        _ = item("Keep Display Awake", #selector(toggleDisplay), on: Settings.keepDisplayAwake)
        let thr = NSMenuItem(title: "Release at Battery", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for v in [0, 20, 30, 40, 45, 50, 60, 70] {
            let i = NSMenuItem(title: v == 0 ? "Never" : "\(v)%", action: #selector(setThreshold(_:)), keyEquivalent: "")
            i.target = self; i.tag = v; i.state = Settings.threshold == v ? .on : .off
            sub.addItem(i)
        }
        thr.submenu = sub
        menu.addItem(thr)
        _ = item("Show Times in Menu Bar", #selector(toggleTimes), on: Settings.showTimes)
        menu.addItem(.separator())

        if !Permission.installed { _ = item("Allow Lid-Close Sleep Control…", #selector(grantPermission)) }
        _ = item("About LidCaffeinate", #selector(openAbout))
        _ = item("LidCaffeinate Help", #selector(openHelp), key: "?")
        _ = item("Settings…", #selector(openSettings), key: ",")
        _ = item("Quit LidCaffeinate", #selector(quit), key: "q")
    }

    // MARK: actions

    @objc func toggleEnabled() { Settings.enabled.toggle(); tick() }
    @objc func setThreshold(_ s: NSMenuItem) { Settings.threshold = s.tag; tick() }
    @objc func toggleDisplay() { Settings.keepDisplayAwake.toggle(); tick() }
    @objc func toggleTimes() { Settings.showTimes.toggle(); updateIcon() }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func openSettings() { showSettings(.general) }
    @objc func openHelp() { showSettings(.help) }
    @objc func openAbout() { showSettings(.about) }

    var settingsActions: SettingsActions {
        SettingsActions(grant: { [weak self] in self?.grantPermission() },
                        remove: { [weak self] in self?.removePermission() },
                        resetLearning: { [weak self] in PowerHistory.refresh(force: true) { self?.tick() } },
                        setLogin: { [weak self] on in self?.setLogin(on) })
    }

    /// Standard Mac preferences window: toolbar tabs, window resizes per tab.
    func showSettings(_ tab: SettingsTab) {
        if settingsWindow == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            for t in SettingsTab.allCases {
                let host = NSHostingController(rootView: settingsView(t, model: live, actions: settingsActions))
                host.sizingOptions = []
                host.title = t.title          // the window shows the selected tab's title
                host.preferredContentSize = t.size
                host.view.frame.size = t.size
                let item = NSTabViewItem(viewController: host)
                item.label = t.title
                item.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title)
                tabs.addTabViewItem(item)
            }
            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable]
            w.toolbarStyle = .preference
            w.isReleasedWhenClosed = false
            settingsTabs = tabs
            settingsWindow = w
        }
        live.login = SMAppService.mainApp.status == .enabled
        settingsTabs?.selectedTabViewItemIndex = tab.rawValue
        settingsWindow?.title = tab.title
        settingsWindow?.center()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            alert("Couldn’t change Launch at Login", "\(error.localizedDescription)\nMove the app to the Applications folder and try again.")
        }
        live.login = SMAppService.mainApp.status == .enabled
    }

    func offerPermission() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Allow LidCaffeinate to keep the Mac awake with the lid closed?"
        a.informativeText = """
        This needs one admin setting: a rule that lets your account run only “pmset disablesleep 0/1” without a password. \
        You’ll be asked for your password once.

        Without it, the app still prevents sleep while the lid is open.
        """
        a.addButton(withTitle: "Allow…"); a.addButton(withTitle: "Not Now")
        if a.runModal() == .alertFirstButtonReturn { grantPermission() }
    }

    @objc func grantPermission() {
        if Permission.install() { tick() }
        else { alert("Permission not added", "The password prompt was cancelled or the rule failed validation.") }
    }

    func removePermission() {
        release()
        if Permission.uninstall() { Settings.enabled = false }
        tick()
    }

    func alert(_ t: String, _ m: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = t; a.informativeText = m; a.runModal()
    }
}

// MARK: - Settings window

final class LiveModel: ObservableObject {
    @Published var nowW: Double?
    @Published var openW: Double?
    @Published var closedW: Double?
    @Published var permission = Permission.installed
    @Published var login = SMAppService.mainApp.status == .enabled
    @Published var onAC = true
    @Published var docked = false
    @Published var closedNote = "Not learned yet"
    @Published var historyNote = "Not available, using macOS"

    /// Where the lid-closed draw and the charging curve come from, for Settings.
    func applyHistoryNotes() {
        if let h = PowerHistory.result, let s = h.screenShareW {
            closedNote = String(format: "Current draw − %.1f W screen · from %d lid closes", s, h.lidClosePairs ?? 0)
        } else {
            closedNote = String(format: "Current draw − %.0f W screen · default until learned", PowerHistory.defaultScreenShare)
        }
        if let h = PowerHistory.result, h.chargeMinutesPerPercent.contains(where: { $0 > 0 }) {
            historyNote = h.days >= 1 ? "Learned from \(Int(h.days.rounded())) days of history"
                                      : "Learned from \(max(1, Int(h.days * 24))) hours of history"
        } else { historyNote = "Not available, using macOS" }
    }
}

struct SettingsActions {
    let grant: () -> Void
    let remove: () -> Void
    let resetLearning: () -> Void
    let setLogin: (Bool) -> Void
}

enum SettingsTab: Int, CaseIterable {
    case general, menuBar, network, help, about
    var title: String { ["General", "Menu Bar", "Network", "Help", "About"][rawValue] }
    var symbol: String { ["gearshape", "menubar.rectangle", "wifi", "questionmark.circle", "info.circle"][rawValue] }
    var size: NSSize {
        [NSSize(width: 560, height: 700), NSSize(width: 520, height: 520), NSSize(width: 520, height: 300),
         NSSize(width: 560, height: 640), NSSize(width: 420, height: 380)][rawValue]
    }
}

func settingsView(_ tab: SettingsTab, model: LiveModel, actions: SettingsActions) -> AnyView {
    let v: AnyView
    switch tab {
    case .general: v = AnyView(GeneralTab(model: model, actions: actions))
    case .menuBar: v = AnyView(MenuBarTab(model: model, actions: actions))
    case .network: v = AnyView(NetworkTab())
    case .help:    v = AnyView(HelpTab())
    case .about:   v = AnyView(AboutTab())
    }
    return AnyView(v.frame(width: tab.size.width, height: tab.size.height))
}

private func footer(_ s: String) -> some View { Text(s).font(.footnote).foregroundStyle(.secondary) }

struct GeneralTab: View {
    @ObservedObject var model: LiveModel
    let actions: SettingsActions
    @AppStorage("enabled") private var enabled = true
    @AppStorage("keepDisplayAwake") private var keepDisplayAwake = true
    @AppStorage("threshold") private var threshold = 45
    @AppStorage("sleepAtThreshold") private var sleepAtThreshold = false

    var body: some View {
        Form {
            Section {
                Toggle("Keep Mac awake", isOn: $enabled)
                Toggle("Keep display awake", isOn: $keepDisplayAwake).disabled(!enabled)
            } footer: {
                BehaviourTable(keepAwake: enabled, keepDisplay: keepDisplayAwake, permission: model.permission,
                               threshold: threshold, onAC: model.onAC, docked: model.docked)
            }
            Section {
                Toggle("Launch at login", isOn: Binding(get: { model.login }, set: { actions.setLogin($0) }))
            }
            Section {
                Picker("Release hold at", selection: $threshold) {
                    Text("Never").tag(0)
                    ForEach([20, 30, 40, 45, 50, 60, 70], id: \.self) { Text("\($0)%").tag($0) }
                }
                Toggle("Put Mac to sleep when released", isOn: $sleepAtThreshold)
            } header: { Text("Battery") } footer: {
                footer("On battery, the hold is released at this level. It comes back when you plug in or the level rises.")
            }
            Section {
                LabeledContent("Lid-close sleep control") {
                    if model.permission {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Not allowed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                if model.permission { Button("Remove Permission…", action: actions.remove) }
                else { Button("Allow…", action: actions.grant) }
            } header: { Text("Permission") } footer: {
                footer("Needed to stay awake with the lid closed on battery. See Help for details.")
            }
        }
        .formStyle(.grouped)
    }
}

/// What the two switches do in each situation. The row matching the Mac right now is highlighted.
struct BehaviourTable: View {
    let keepAwake: Bool, keepDisplay: Bool, permission: Bool, threshold: Int, onAC: Bool, docked: Bool

    private func open(_ d: Bool) -> String {
        keepDisplay ? (d ? "Awake · screens stay on" : "Awake · screen stays on")
                    : (d ? "Awake · screens sleep as usual" : "Awake · screen sleeps as usual")
    }
    private func closed(battery: Bool, docked d: Bool) -> String {
        // docked on power is macOS clamshell mode; every other lid-closed case needs the permission
        if !permission && !(d && !battery) { return "Sleeps · needs permission" }
        if d { return keepDisplay ? "Awake · external screen stays on" : "Awake · external screen sleeps as usual" }
        return "Awake · screen off"
    }
    @ViewBuilder private func row(_ title: String, battery: Bool, docked d: Bool) -> some View {
        let now = battery == !onAC && d == docked
        GridRow {
            HStack(spacing: 4) {
                Image(systemName: "arrowtriangle.right.fill").font(.system(size: 7)).opacity(now ? 1 : 0)
                Text(title)
            }
            Text(open(d))
            Text(closed(battery: battery, docked: d))
        }
        .foregroundStyle(now ? .primary : .secondary)
        .fontWeight(now ? .semibold : .regular)
    }

    var body: some View {
        if !keepAwake {
            Text("Off: your Mac follows its normal sleep settings. Closing the lid puts it to sleep, except when it’s docked on power, where macOS keeps running on the external display.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        Text("")
                        Text("Lid open").fontWeight(.semibold)
                        Text("Lid closed").fontWeight(.semibold)
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    row("On battery", battery: true, docked: false)
                    row("On power", battery: false, docked: false)
                    row("Docked, on power", battery: false, docked: true)
                    row("Docked, on battery", battery: true, docked: true)
                }
                if keepDisplay {
                    Label {
                        Text("While the screen is kept on, your Mac won’t lock itself when you walk away. That’s a security risk if other people can reach it. Lock it with Control-Command-Q, or turn Keep display awake off.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.orange)
                } else {
                    Text("The screen turns off as usual, so your Mac locks according to your Lock Screen settings.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Docked means an external display is connected." +
                     (threshold > 0 ? " On battery, the hold is released at \(threshold)%." : "") +
                     " The network stays connected whenever the Mac is awake.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct MenuBarTab: View {
    @ObservedObject var model: LiveModel
    let actions: SettingsActions
    @AppStorage("showTimes") private var showTimes = true
    @AppStorage("topRowLidClosed") private var topClosed = true
    @AppStorage("bottomRowLidClosed") private var bottomClosed = false

    private func watts(_ w: Double?) -> String { w.map { String(format: "%.1f W", $0) } ?? "—" }

    var body: some View {
        Form {
            Section {
                Toggle("Show time estimates", isOn: $showTimes)
                Picker("Top row — time to release level", selection: $topClosed) {
                    Text("Lid open").tag(false); Text("Lid closed").tag(true)
                }
                Picker("Bottom row — time to empty", selection: $bottomClosed) {
                    Text("Lid open").tag(false); Text("Lid closed").tag(true)
                }
            } footer: {
                footer("Each row is estimated at the power draw you’d have with the lid open or closed. ☾ marks a lid-closed estimate.")
            }
            Section {
                LabeledContent("Right now", value: watts(model.nowW))
                LabeledContent("Lid open, 5-minute average", value: watts(model.openW))
                LabeledContent("Lid closed, learned", value: model.closedNote)
                LabeledContent("Charging curve", value: model.historyNote)
                Button("Refresh from History", action: actions.resetLearning)
            } header: { Text("Power Draw") } footer: {
                footer("Learned from this Mac’s own power history and refreshed every hour. Lid closed is your current draw minus the screen’s share, learned by comparing the draw before and after past lid closes on battery. The charging curve is how long each 1% took to charge.")
            }
        }
        .formStyle(.grouped)
    }
}

struct NetworkTab: View {
    @AppStorage("pingHost") private var pingHost = "1.1.1.1"
    @AppStorage("hotspot") private var hotspot = ""
    @AppStorage("pingInterval") private var pingInterval = 30

    var body: some View {
        Form {
            Section {
                TextField("Ping host", text: $pingHost)
                Picker("Ping every", selection: $pingInterval) {
                    ForEach([(10, "10 seconds"), (15, "15 seconds"), (30, "30 seconds"), (60, "1 minute"),
                             (120, "2 minutes"), (300, "5 minutes")], id: \.0) { Text($0.1).tag($0.0) }
                }
                TextField("Hotspot fallback", text: $hotspot, prompt: Text("Off"))
            } footer: {
                footer("If two pings in a row fail, the Mac joins the hotspot. A shorter interval reconnects faster but uses a little more power. Join the hotspot once from the Wi-Fi menu first so its password is saved. Leave it empty to turn this off.")
            }
        }
        .formStyle(.grouped)
    }
}

struct HelpTab: View {
    private func topic(_ title: String, _ symbol: String, _ body: String) -> some View {
        Section {
            Text(body).fixedSize(horizontal: false, vertical: true)
        } header: {
            Label(title, systemImage: symbol)
        }
    }

    var body: some View {
        Form {
            topic("What LidCaffeinate does", "cup.and.saucer",
                  "Keeps your Mac awake while the app is running, even with the lid closed and on battery. The network stays connected too. Quit the app and normal sleep comes back.")
            topic("Lid-close sleep control", "lock.shield",
                  "On battery, macOS always sleeps when you close the lid. Preventing that needs one admin setting, so LidCaffeinate adds a rule that lets your account run only “pmset disablesleep” without a password. You approve it once with your password. Without it, the Mac still stays awake while the lid is open.")
            topic("Screen with the lid closed", "display",
                  "When you close the lid, the display is put to sleep right away, so the screen is really off and saves power. Opening the lid wakes it. When docked to an external display, that screen keeps working; Keep display awake decides whether it stays on or sleeps as usual. General settings shows a table of what happens in each situation.\n\nSecurity: while a screen is kept on, your Mac doesn’t lock itself, so anyone nearby could use it. Lock it with Control-Command-Q when you step away.")
            topic("Release level", "battery.25percent",
                  "On battery, the hold is released at the level you choose, so the Mac can sleep normally before the battery runs out. It comes back when you plug in or the level rises. You can also have the Mac go to sleep right away when that happens.")
            topic("The menu-bar icon", "menubar.rectangle",
                  "Cup on the battery: keeping awake. Outlined cup: awake, but lid-close sleep isn’t allowed yet. Battery only: off, or released at your battery level.\n\nOn battery, the top row is the time until the release level and the bottom row is the time until empty. On power, the top row is the time you’d get if you unplugged now, and the bottom row is the time until full.")
            topic("What “learned” means", "brain",
                  "Times are based on how much power your Mac actually uses, measured from the battery every 30 seconds. Each time is the energy left above the target level, divided by the average power draw.\n\nLid open: the average of the last 5 minutes, so it follows whatever you’re doing now. It’s measured on power too, so “if unplugged” times work.\n\nLid closed: your current power draw minus the screen’s share, because background work keeps running after you close the lid. The screen’s share is learned from this Mac’s power history by comparing the draw before and after past lid closes on battery. Until there are 3 of them, it assumes 2 W. Until it’s learned, lid-closed rows use the lid-open rate, and ☾ appears once the lid-closed rate is in use.")
            topic("Time to full", "bolt",
                  "While charging, the time to full is learned from this Mac’s own charging history in the macOS power log: how many minutes each 1% took at each level, using past charges with a similar charger, so the slowdown near full is included. Below 80%, the speed is adjusted to today’s charger and load. Without history, macOS’s own estimate is used. The menu shows the charging power, the power coming in minus what the Mac is using, and macOS’s figure for comparison.")
            topic("Network keep-alive", "wifi",
                  "The app pings a host at the interval you set, every 30 seconds by default. If two pings in a row fail, it joins your hotspot. Join the hotspot once from the Wi-Fi menu first so its password is saved.")
            topic("Safety", "checkmark.shield",
                  "If the app quits, crashes or is force-quit, lid-close sleep is turned back on automatically.")
        }
        .formStyle(.grouped)
    }
}

struct AboutTab: View {
    private var version: String {
        let i = Bundle.main.infoDictionary
        return "Version \(i?["CFBundleShortVersionString"] as? String ?? "1.0") (\(i?["CFBundleVersion"] as? String ?? "1"))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable().frame(width: 112, height: 112)
            Text("LidCaffeinate").font(.title).bold()
            Text(version).foregroundStyle(.secondary)
            Text("Keeps your Mac awake with the lid closed, on battery, with the network connected.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 30)
            Divider().padding(.vertical, 6).padding(.horizontal, 60)
            Text("Wonderful Hong Kong 2026")
            Text(verbatim: "anthony.chan@wonderful.ai")   // plain text: no automatic mail link
                .textSelection(.enabled)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--render-icons"), i + 1 < CommandLine.arguments.count {
    IconRenderer.renderPreviews(to: CommandLine.arguments[i + 1]); exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--render-settings"), i + 1 < CommandLine.arguments.count {
    // debug: render every Settings tab offscreen to <dir>/settings-<tab>.png
    Settings.register()
    NSApplication.shared.setActivationPolicy(.prohibited)
    PowerHistory.result = PowerHistory.compute() ?? PowerHistory.result
    let model = LiveModel(); model.nowW = 23.4; model.openW = 18.2; model.onAC = false; model.docked = false
    model.applyHistoryNotes()
    let acts = SettingsActions(grant: {}, remove: {}, resetLearning: {}, setLogin: { _ in })
    for t in SettingsTab.allCases {
        let v = NSHostingView(rootView: settingsView(t, model: model, actions: acts))
        v.frame = NSRect(origin: .zero, size: t.size)
        let w = NSWindow(contentRect: v.frame, styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = v
        v.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: "\(CommandLine.arguments[i + 1])/settings-\(t.title.replacingOccurrences(of: " ", with: "")).png"))
    }
    exit(0)
}
if CommandLine.arguments.contains("--battery") {   // debug: print the numbers behind the estimates
    Settings.register()
    PowerHistory.result = PowerHistory.compute() ?? PowerHistory.result
    if let h = PowerHistory.result {
        print(String(format: "history: %.1f days · screen share %@ from %d lid closes · screen-off avg %@ from %.0f min · charge min/%% per band %@", h.days,
                     h.screenShareW.map { String(format: "%.1f W", $0) } ?? "n/a", h.lidClosePairs ?? 0,
                     h.lidClosedWatts.map { String(format: "%.1f W", $0) } ?? "n/a", h.lidClosedMinutes,
                     h.chargeMinutesPerPercent.map { $0 > 0 ? String(format: "%.2f", $0) : "-" }.joined(separator: " ")))
    } else { print("history: power log not readable") }
    let b = Power.battery(), t = Settings.threshold
    print("pct=\(b.pct.map(String.init) ?? "?") onAC=\(b.onAC) lidClosed=\(b.lidClosed) mAh=\(b.mAh ?? -1) mV=\(b.mV ?? -1) mA=\(b.mA ?? 0)")
    print("watts now=\(b.watts.map { String(format: "%.1f", $0) } ?? "?")  energy to \(t)%=\(b.energyWh(downTo: t).map { String(format: "%.1f Wh", $0) } ?? "?")")
    print("to empty (system or fallback)=\(b.toEmptyMin ?? -1) min  to \(t)% now=\(Power.minutes(to: t, b) ?? -1) min")
    print("time to full: shown=\(b.toFullMin ?? -1) min  macOS=\(b.systemToFullMin ?? -1) min  power in=\(b.powerInW.map { String(format: "%.1f", $0) } ?? "?") W")
    print("charger-matched curve (\(Int(b.powerInW ?? 0)) W, \(PowerHistory.result?.sessions?.count ?? 0) past charges): " +
          PowerHistory.curve(refW: b.powerInW ?? 0).map { $0 > 0 ? String(format: "%.2f", $0) : "-" }.joined(separator: " "))
    let lw = Settings.lidClosedWattsLearned
    print("lid closed learned=\(String(format: "%.1f", lw)) W  to \(t)% lid closed=\(lw > 0 ? Power.minutes(to: t, b, watts: lw) ?? -1 : -1) min  to 0% lid closed=\(lw > 0 ? Power.minutes(to: 0, b, watts: lw) ?? -1 : -1) min")
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // belt and braces with LSUIElement: no Dock icon
app.run()
