import Foundation
import IOKit
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
