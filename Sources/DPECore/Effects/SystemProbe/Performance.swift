import Foundation
import Darwin
import IOKit
import IOKit.ps

struct LiveStats {
    var cpuUser = 0.0, cpuSystem = 0.0, cpuIdle = 1.0
    var memUsed: UInt64 = 0, memTotal: UInt64 = 0
    var memWired: UInt64 = 0, memCompressed: UInt64 = 0, memActive: UInt64 = 0, memCached: UInt64 = 0
    var swapUsed: UInt64 = 0, swapTotal: UInt64 = 0
    var load: (Double, Double, Double) = (0, 0, 0)
    var processes = 0
    var threads = 0
    var thermal = "nominal"
    var battery: String?
    var batteryFraction: Double?
    var uptime: TimeInterval = 0
    var cpuBusy: Double { 1.0 - cpuIdle }
    var memFraction: Double { memTotal == 0 ? 0 : Double(memUsed) / Double(memTotal) }
}

final class Sampler {
    private var previous: host_cpu_load_info?

    func sample() -> LiveStats {
        var s = LiveStats()

        // CPU ---------------------------------------------------------------
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            if let prev = previous {
                let user = Double(info.cpu_ticks.0 - prev.cpu_ticks.0)
                let sys = Double(info.cpu_ticks.1 - prev.cpu_ticks.1)
                let idle = Double(info.cpu_ticks.2 - prev.cpu_ticks.2)
                let nice = Double(info.cpu_ticks.3 - prev.cpu_ticks.3)
                let total = user + sys + idle + nice
                if total > 0 {
                    s.cpuUser = (user + nice) / total
                    s.cpuSystem = sys / total
                    s.cpuIdle = idle / total
                }
            }
            previous = info
        }

        // Memory ------------------------------------------------------------
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vkr = withUnsafeMutablePointer(to: &vm) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
            }
        }
        let page = UInt64(vm_kernel_page_size)
        s.memTotal = UInt64(sysctlInt("hw.memsize") ?? 0)
        if vkr == KERN_SUCCESS {
            s.memActive = UInt64(vm.active_count) * page
            s.memWired = UInt64(vm.wire_count) * page
            s.memCompressed = UInt64(vm.compressor_page_count) * page
            s.memCached = UInt64(vm.external_page_count) * page
            s.memUsed = s.memActive + s.memWired + s.memCompressed + UInt64(vm.inactive_count) * page - s.memCached
        }
        var xsw = xsw_usage()
        var xswSize = MemoryLayout<xsw_usage>.size
        var mib: [Int32] = [CTL_VM, VM_SWAPUSAGE]
        if sysctl(&mib, 2, &xsw, &xswSize, nil, 0) == 0 {
            s.swapUsed = xsw.xsu_used
            s.swapTotal = xsw.xsu_total
        }

        // Load / processes ---------------------------------------------------
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 { s.load = (loads[0], loads[1], loads[2]) }
        s.processes = Int(max(0, proc_listallpids(nil, 0)))
        s.threads = Int(sysctlInt("machdep.cpu.thread_count") ?? 0)

        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  s.thermal = "nominal"
        case .fair:     s.thermal = "fair"
        case .serious:  s.thermal = "SERIOUS — throttling likely"
        case .critical: s.thermal = "CRITICAL"
        @unknown default: s.thermal = "unknown"
        }

        s.uptime = ProcessInfo.processInfo.systemUptime

        // Power --------------------------------------------------------------
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for src in list {
                guard let d = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any] else { continue }
                let cur = d[kIOPSCurrentCapacityKey as String] as? Int ?? 0
                let max = d[kIOPSMaxCapacityKey as String] as? Int ?? 100
                let state = d[kIOPSPowerSourceStateKey as String] as? String ?? "?"
                let charging = d[kIOPSIsChargingKey as String] as? Bool ?? false
                s.batteryFraction = max > 0 ? Double(cur) / Double(max) : nil
                var text = "\(cur)%  \(state)"
                if charging { text += " · charging" }
                if let mins = d[kIOPSTimeToEmptyKey as String] as? Int, mins > 0 { text += " · \(mins / 60)h \(mins % 60)m remaining" }
                if let mins = d[kIOPSTimeToFullChargeKey as String] as? Int, mins > 0 { text += " · \(mins)m to full" }
                s.battery = text
            }
        }
        return s
    }
}

func batteryHealthLines() -> [TermLine] {
    var out: [TermLine] = []
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return out }
    defer { IOObjectRelease(service) }
    func prop(_ k: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
    if let cycles = prop("CycleCount") as? Int { out.append(kv("battery cycles", "\(cycles)")) }
    if let design = prop("DesignCapacity") as? Int, let raw = prop("AppleRawMaxCapacity") as? Int, design > 0 {
        out.append(kv("battery health", "\(raw) / \(design) mAh  (\(Int(Double(raw) / Double(design) * 100))% of design)"))
    }
    if let serial = prop("BatterySerialNumber") as? String { out.append(kv("battery serial", serial, kind: .alert)) }
    if let temp = prop("Temperature") as? Int { out.append(kv("battery temp", String(format: "%.1f °C", Double(temp) / 100.0))) }
    return out
}

func performanceSection(_ s: LiveStats) -> [TermLine] {
    var out = section("performance")
    out.append(TermLine(label: "cpu load", text: "[\(bar(s.cpuBusy))] \(pct(s.cpuBusy)) busy   user \(pct(s.cpuUser)) · sys \(pct(s.cpuSystem))"))
    out.append(TermLine(label: "memory", text: "[\(bar(s.memFraction))] \(bytes(s.memUsed)) of \(bytes(s.memTotal))"))
    out.append(kv("  breakdown", "wired \(bytes(s.memWired)) · active \(bytes(s.memActive)) · compressed \(bytes(s.memCompressed)) · cached \(bytes(s.memCached))"))
    if s.swapTotal > 0 { out.append(kv("  swap", "\(bytes(s.swapUsed)) used of \(bytes(s.swapTotal))")) }
    out.append(kv("load average", String(format: "%.2f  %.2f  %.2f   (1m / 5m / 15m)", s.load.0, s.load.1, s.load.2)))
    out.append(kv("processes", "\(s.processes) running"))
    out.append(TermLine(label: "thermal state", text: s.thermal, kind: s.thermal == "nominal" ? .ok : .warn))
    if let b = s.battery { out.append(kv("power source", b)) }
    out.append(contentsOf: batteryHealthLines())
    out.append(kv("awake time", duration(s.uptime) + "   (excludes sleep)"))
    return out
}
