import Foundation
import AppKit
import IOKit
import IOKit.usb
import IOBluetooth
import CoreWLAN
import Darwin


// **Changed in the port.** `networkLines()` read the MAC address out of a copied
// `sockaddr_dl`, which trapped on any interface with a name longer than six
// characters (`bridge0` on most Macs). Fixed in place — this bug is upstream in
// systemprobe too and the fix should go back there. See Effects/VENDORING.md.
// MARK: - USB

func usbLines() -> [TermLine] {
    var out: [TermLine] = []
    var seen = Set<String>()
    for className in ["IOUSBHostDevice", "IOUSBDevice"] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { continue }
        defer { IOObjectRelease(iterator) }
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            func prop(_ k: String) -> Any? {
                IORegistryEntryCreateCFProperty(device, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            let name = (prop("USB Product Name") as? String)
                ?? (prop("kUSBProductString") as? String)
                ?? "unnamed device"
            let vendor = (prop("USB Vendor Name") as? String) ?? (prop("kUSBVendorString") as? String) ?? "unknown vendor"
            let serial = (prop("USB Serial Number") as? String) ?? (prop("kUSBSerialNumberString") as? String)
            let vid = prop("idVendor") as? Int ?? 0
            let pid = prop("idProduct") as? Int ?? 0
            let speed = prop("Device Speed") as? Int
            let key = "\(vid):\(pid):\(serial ?? name)"
            if seen.contains(key) { continue }
            seen.insert(key)

            var detail = "\(vendor)  ·  \(String(format: "%04x:%04x", vid, pid))"
            if let sp = speed {
                let names = ["low (1.5 Mb/s)", "full (12 Mb/s)", "high (480 Mb/s)", "super (5 Gb/s)", "super+ (10 Gb/s)", "super+ (20 Gb/s)"]
                if sp < names.count { detail += "  ·  \(names[sp])" }
            }
            out.append(TermLine(label: "  usb", text: name, kind: .alert))
            out.append(kv("    vendor", detail))
            if let s = serial { out.append(kv("    serial", s, kind: .alert)) }
        }
    }
    if out.isEmpty { out.append(note("  no external usb devices attached")) }
    return out
}

// MARK: - Bluetooth

func bluetoothLines() -> [TermLine] {
    var out: [TermLine] = []
    guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice], !paired.isEmpty else {
        out.append(note("  no paired bluetooth devices visible (permission may be required)"))
        return out
    }
    for d in paired.prefix(24) {
        let name = d.name ?? d.nameOrAddress ?? "unnamed"
        let connected = d.isConnected()
        out.append(TermLine(label: "  bluetooth", text: name + (connected ? "   ● CONNECTED" : "   ○ paired"),
                            kind: connected ? .alert : .dim))
        out.append(kv("    address", d.addressString, kind: connected ? .plain : .dim))
        if let last = d.recentAccessDate() { out.append(kv("    last seen", stamp(last), kind: .dim)) }
    }
    return out
}

// MARK: - Displays

@MainActor func displayLines() -> [TermLine] {
    var out: [TermLine] = []
    for screen in NSScreen.screens {
        let f = screen.frame
        let mode = "\(Int(f.width))×\(Int(f.height)) @ \(Int(screen.backingScaleFactor))x · \(screen.maximumFramesPerSecond) Hz"
        out.append(TermLine(label: "  display", text: screen.localizedName, kind: .alert))
        out.append(kv("    geometry", mode))
        let depth = screen.depth
        out.append(kv("    color", "\(screen.colorSpace?.localizedName ?? "unknown")  · \(depth.bitsPerPixel) bpp"))
    }
    if out.isEmpty { out.append(note("  no displays reported")) }
    return out
}

// MARK: - Network

func networkLines() -> [TermLine] {
    var out: [TermLine] = []
    var macs: [String: String] = [:]
    var addrs: [String: [String]] = [:]
    var flags: [String: UInt32] = [:]

    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0, let first = ifap else { return [warn("  interface enumeration failed")] }
    defer { freeifaddrs(ifap) }

    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let ifa = ptr.pointee
        let name = String(cString: ifa.ifa_name)
        guard let sa = ifa.ifa_addr else { continue }
        flags[name] = ifa.ifa_flags
        switch Int32(sa.pointee.sa_family) {
        case AF_INET, AF_INET6:
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                var s = String(cString: host)
                if let pcnt = s.firstIndex(of: "%") { s = String(s[s.startIndex..<pcnt]) }
                let tag = Int32(sa.pointee.sa_family) == AF_INET ? "ipv4" : "ipv6"
                addrs[name, default: []].append("\(tag) \(s)")
            }
        case AF_LINK:
            sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
                let d = dl.pointee
                guard d.sdl_alen == 6 else { return }
                // `sockaddr_dl` is VARIABLE-LENGTH. `sdl_data` holds the interface name
                // (`sdl_nlen` bytes) immediately followed by the link address
                // (`sdl_alen` bytes), and the real allocation is `sdl_len` bytes — which
                // for a long name is bigger than the struct Swift imports.
                //
                // Swift imports `sdl_data` as a *fixed 12-byte tuple*, so the obvious
                // `withUnsafeBytes(of: d.sdl_data) { $0[Int(d.sdl_nlen) + i] }` is wrong
                // twice over: copying `dl.pointee` truncates anything past 12 bytes, and
                // the index runs off the end for any interface whose name is longer than
                // six characters. `bridge0` is seven, and is present on most Macs — so
                // that read traps with a fatal error partway through the show.
                //
                // Read from the original allocation instead, bounded by `sdl_len`.
                let base = UnsafeRawPointer(dl)
                let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) ?? 8
                let start = dataOffset + Int(d.sdl_nlen)
                guard start + Int(d.sdl_alen) <= Int(d.sdl_len) else { return }
                let bytes = (0..<Int(d.sdl_alen)).map {
                    base.load(fromByteOffset: start + $0, as: UInt8.self)
                }
                macs[name] = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
            }
        default: break
        }
    }

    for name in addrs.keys.sorted() where !name.hasPrefix("utun") {
        let up = (flags[name] ?? 0) & UInt32(IFF_UP) != 0
        let list = addrs[name] ?? []
        let v4 = list.filter { $0.hasPrefix("ipv4") }
        guard up, !list.isEmpty else { continue }
        out.append(TermLine(label: "  interface", text: name + (v4.isEmpty ? "" : "   ● active"), kind: v4.isEmpty ? .dim : .alert))
        if let mac = macs[name] { out.append(kv("    mac address", mac, kind: .alert)) }
        for a in list.prefix(4) { out.append(kv("    address", a)) }
    }

    if let iface = CWWiFiClient.shared().interface() {
        out.append(TermLine(text: "", kind: .plain))
        out.append(TermLine(label: "  wi-fi", text: iface.interfaceName ?? "wireless", kind: .alert))
        out.append(kv("    ssid", iface.ssid() ?? "<hidden — needs location permission>", kind: .alert))
        out.append(kv("    bssid", iface.bssid() ?? "<hidden>"))
        out.append(kv("    signal", "\(iface.rssiValue()) dBm  · noise \(iface.noiseMeasurement()) dBm · tx \(iface.transmitRate()) Mb/s"))
        out.append(kv("    hardware mac", iface.hardwareAddress(), kind: .alert))
    }
    return out
}

func devicesSection(displays: [TermLine]) -> [TermLine] {
    var out = section("connected devices")
    out.append(TermLine(text: "  ── displays ──", kind: .section))
    out.append(contentsOf: displays)
    out.append(TermLine(text: "", kind: .plain))
    out.append(TermLine(text: "  ── usb bus ──", kind: .section))
    out.append(contentsOf: usbLines())
    out.append(TermLine(text: "", kind: .plain))
    out.append(TermLine(text: "  ── bluetooth ──", kind: .section))
    out.append(contentsOf: bluetoothLines())
    out.append(TermLine(text: "", kind: .plain))
    out.append(TermLine(text: "  ── network ──", kind: .section))
    out.append(contentsOf: networkLines())
    return out
}
