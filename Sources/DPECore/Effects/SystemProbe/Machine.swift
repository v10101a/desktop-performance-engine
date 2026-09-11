import Foundation
import IOKit
import Metal
import Darwin

// MARK: - low level accessors

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    let s = String(cString: buf)
    return s.isEmpty ? nil : s
}

func sysctlInt(_ name: String) -> Int64? {
    var v64: Int64 = 0
    var s64 = MemoryLayout<Int64>.size
    if sysctlbyname(name, &v64, &s64, nil, 0) == 0, s64 == MemoryLayout<Int64>.size { return v64 }
    var v32: Int32 = 0
    var s32 = MemoryLayout<Int32>.size
    if sysctlbyname(name, &v32, &s32, nil, 0) == 0 { return Int64(v32) }
    return nil
}

func ioPlatform(_ key: String) -> String? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() else { return nil }
    if let s = raw as? String { return s }
    if let d = raw as? Data { return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) }
    return nil
}

func bootDate() -> Date? {
    var tv = timeval()
    var size = MemoryLayout<timeval>.size
    var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
    guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
}

// MARK: - sections

func identitySection() -> [TermLine] {
    var out = section("subject identity")
    let pw = getpwuid(getuid())?.pointee
    let gecos = pw.map { String(cString: $0.pw_gecos) }
    let shell = pw.map { String(cString: $0.pw_shell) }

    out.append(kv("full name", NSFullUserName(), kind: .alert))
    out.append(kv("account", NSUserName()))
    if let g = gecos, !g.isEmpty, g != NSFullUserName() { out.append(kv("gecos record", g)) }
    out.append(kv("uid / gid", "\(getuid()) / \(getgid())"))
    out.append(kv("home", NSHomeDirectory()))
    out.append(kv("login shell", shell))
    out.append(kv("computer name", Host.current().localizedName))
    out.append(kv("local hostname", Host.current().name))
    out.append(kv("time zone", "\(TimeZone.current.identifier)  (GMT\(TimeZone.current.secondsFromGMT() / 3600))"))
    out.append(kv("locale", "\(Locale.current.identifier)  \(Locale.current.currency?.identifier ?? "")"))
    out.append(kv("languages", Locale.preferredLanguages.prefix(3).joined(separator: ", ")))
    out.append(kv("probe time", stamp(Date())))
    return out
}

func machineSection() -> [TermLine] {
    var out = section("hardware fingerprint")
    let mem = sysctlInt("hw.memsize").map { bytes($0) }
    let cores = sysctlInt("hw.physicalcpu")
    let logical = sysctlInt("hw.logicalcpu")
    let perf = sysctlInt("hw.perflevel0.physicalcpu")
    let eff = sysctlInt("hw.perflevel1.physicalcpu")

    out.append(kv("model identifier", sysctlString("hw.model"), kind: .alert))
    out.append(kv("model number", ioPlatform("model-number")))
    out.append(kv("regulatory model", ioPlatform("regulatory-model-number")))
    out.append(kv("chip", sysctlString("machdep.cpu.brand_string")))
    if let c = cores, let l = logical {
        var s = "\(c) physical / \(l) logical"
        if let p = perf, let e = eff { s += "  (\(p)P + \(e)E)" }
        out.append(kv("cores", s))
    }
    out.append(kv("memory installed", mem))
    out.append(kv("serial number", ioPlatform("IOPlatformSerialNumber"), kind: .alert))
    out.append(kv("hardware uuid", ioPlatform("IOPlatformUUID"), kind: .alert))
    out.append(kv("board id", ioPlatform("board-id") ?? ioPlatform("target-type")))
    let os = ProcessInfo.processInfo.operatingSystemVersion
    out.append(kv("operating system", "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)  (\(sysctlString("kern.osversion") ?? "?"))"))
    out.append(kv("kernel", "\(sysctlString("kern.ostype") ?? "") \(sysctlString("kern.osrelease") ?? "")"))
    out.append(kv("architecture", sysctlString("hw.machine")))
    out.append(kv("rosetta / vm", (sysctlInt("sysctl.proc_translated") ?? 0) == 1 ? "translated process" : ((sysctlInt("kern.hv_vmm_present") ?? 0) == 1 ? "running under hypervisor" : "native, bare metal")))
    if let b = bootDate() {
        out.append(kv("last boot", stamp(b)))
        out.append(kv("time since boot", duration(Date().timeIntervalSince(b))))
    }
    return out
}

/// A deeper, nicher read than `machineSection` — the internals and peripherals the
/// "hardware fingerprint" panel doesn't cover: the GPU, the CPU's caches and clocks, the
/// displays, the USB bus, and the battery. Every field is `sysctl`/IOKit/Metal, so it
/// needs no entitlement (which is why the ex-`contacts` panel became this).
///
/// `displays` is passed in because `displayLines()` is `@MainActor` and this builder runs
/// off the main thread inside `Probe.gather` — the same reason `devicesSection` takes it.
func hardwareDeepSection(displays: [TermLine]) -> [TermLine] {
    var out = section("deep hardware scan")

    // The GPU. `MTLCreateSystemDefaultDevice()` is thread-safe, so it's fine off-main.
    if let gpu = MTLCreateSystemDefaultDevice() {
        out.append(TermLine(text: "  ── graphics ──", kind: .section))
        out.append(kv("  gpu", gpu.name, kind: .alert))
        out.append(kv("    vram budget", bytes(gpu.recommendedMaxWorkingSetSize)))
        out.append(kv("    memory model", gpu.hasUnifiedMemory ? "unified (shared with system RAM)" : "discrete"))
    }

    // The parts of the CPU the "machine" panel's core count doesn't reach.
    out.append(TermLine(text: "  ── processor internals ──", kind: .section))
    if let pk = sysctlInt("hw.packages") { out.append(kv("  cpu packages", "\(pk)")) }
    if let cl = sysctlInt("hw.cachelinesize") { out.append(kv("  cache line", "\(cl) bytes")) }
    if let l1i = sysctlInt("hw.l1icachesize") { out.append(kv("  l1 instruction", bytes(l1i))) }
    if let l1d = sysctlInt("hw.l1dcachesize") { out.append(kv("  l1 data", bytes(l1d))) }
    if let l2 = sysctlInt("hw.l2cachesize") ?? sysctlInt("hw.perflevel0.l2cachesize") {
        out.append(kv("  l2 cache", bytes(l2)))
    }
    if let l3 = sysctlInt("hw.l3cachesize"), l3 > 0 { out.append(kv("  l3 cache", bytes(l3))) }
    if let pg = sysctlInt("hw.pagesize") ?? sysctlInt("vm.pagesize") { out.append(kv("  page size", "\(pg) bytes")) }
    if let tb = sysctlInt("hw.tbfrequency"), tb > 0 {
        out.append(kv("  timebase", String(format: "%.2f MHz", Double(tb) / 1_000_000)))
    }
    if let cpuf = sysctlInt("hw.cpufrequency"), cpuf > 0 {
        out.append(kv("  cpu frequency", String(format: "%.2f GHz", Double(cpuf) / 1e9)))
    }
    let thermal: String
    switch ProcessInfo.processInfo.thermalState {
    case .nominal:  thermal = "nominal"
    case .fair:     thermal = "fair"
    case .serious:  thermal = "serious"
    case .critical: thermal = "critical"
    @unknown default: thermal = "unknown"
    }
    out.append(kv("  thermal state", thermal, kind: thermal == "nominal" ? .plain : .warn))

    // Displays (gathered on main and handed in), the USB bus, and the battery.
    out.append(TermLine(text: "  ── displays ──", kind: .section))
    out.append(contentsOf: displays)
    out.append(TermLine(text: "  ── usb bus ──", kind: .section))
    out.append(contentsOf: usbLines())
    let battery = batteryHealthLines()
    if !battery.isEmpty {
        out.append(TermLine(text: "  ── power ──", kind: .section))
        out.append(contentsOf: battery)
    }
    return out
}
