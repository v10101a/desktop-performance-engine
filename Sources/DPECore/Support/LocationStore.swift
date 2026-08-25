import Foundation
import CoreLocation

/// The one place the show keeps what it learned about WHERE the machine is.
///
/// The system probe asks Location Services for a fix and reverse-geocodes it; the intro
/// gate warms the same request up before the music starts so the fix is already in hand
/// when the probe wants it. Both write here. The Apple Maps window (`map.here`) and the
/// `{city}` / `{ip}` placeholders in window titles read from here.
///
/// **Nothing leaves the machine.** The fix is CoreLocation's; the address is Apple's
/// geocoder, which the probe already used; the IP is the interface address from
/// `getifaddrs`. There is no lookup against a third-party geo-IP service — that would
/// make a liar of the probe's "all readings are local" line.
final class LocationStore: NSObject, CLLocationManagerDelegate {
    static let shared = LocationStore()

    private(set) var coordinate: CLLocationCoordinate2D?
    private(set) var placeName: String?
    private var manager: CLLocationManager?
    private var warming = false
    private var onAuthorized: (() -> Void)?

    /// Remember a fix. Called by whichever probe got one first.
    func record(_ location: CLLocation) {
        coordinate = location.coordinate
    }

    func record(place: CLPlacemark) {
        let parts = [place.locality, place.administrativeArea, place.country]
            .compactMap { $0 }.filter { !$0.isEmpty }
        if !parts.isEmpty { placeName = parts.joined(separator: ", ") }
    }

    /// Ask for authorization now (the prompt, if it has never been answered) and start
    /// a fix. `done` fires once the authorization question is settled either way — it
    /// does NOT wait for the fix itself, which arrives whenever it arrives.
    func warm(done: @escaping () -> Void) {
        guard !warming else { done(); return }
        warming = true
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager = m
        if m.authorizationStatus == .notDetermined {
            onAuthorized = done
            m.requestWhenInUseAuthorization()
            // A prompt nobody answers must not hold the show hostage.
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
                guard let self, let pending = self.onAuthorized else { return }
                self.onAuthorized = nil
                pending()
            }
        } else {
            requestFix()
            done()
        }
    }

    private func requestFix() {
        guard let m = manager else { return }
        switch m.authorizationStatus {
        case .denied, .restricted: return
        default:
            if CLLocationManager.locationServicesEnabled() { m.requestLocation() }
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        guard m.authorizationStatus != .notDetermined else { return }
        requestFix()
        if let pending = onAuthorized {
            onAuthorized = nil
            pending()
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        record(loc)
        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] places, _ in
            if let p = places?.first { self?.record(place: p) }
        }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        NSLog("[DPE] location warm-up: \(error.localizedDescription)")
    }

    // MARK: - Placeholders

    /// `{ip}` → the machine's own IPv4 address, `{city}` → the geocoded place, if the
    /// show has learned them; otherwise something that still reads as an address.
    static func fill(_ s: String) -> String {
        guard s.contains("{") else { return s }
        return s.replacingOccurrences(of: "{ip}", with: localIPv4() ?? "127.0.0.1")
                .replacingOccurrences(of: "{city}", with: shared.placeName ?? "somewhere")
    }

    /// The first non-loopback IPv4 address on an interface that is up. Cached — the
    /// interface list doesn't change mid-show and `getifaddrs` is not free.
    static func localIPv4() -> String? {
        if let cached = cachedIP { return cached }
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }
        var found: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, Int32(sa.pointee.sa_family) == AF_INET,
                  ifa.ifa_flags & UInt32(IFF_UP) != 0,
                  ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard !name.hasPrefix("utun"), !name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                found = String(cString: host)
                // en0 (Wi-Fi) is the address a viewer recognises; keep looking past
                // anything else only until we have found one.
                if name == "en0" { break }
            }
        }
        cachedIP = found
        return found
    }
    private static var cachedIP: String?
}
