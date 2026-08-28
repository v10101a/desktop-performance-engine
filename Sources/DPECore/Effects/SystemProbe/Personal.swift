import Foundation
import CoreLocation

// MARK: - Geolocation

final class LocationProbe: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var finished = false
    private var emit: (([TermLine]) -> Void)?

    func run(_ emit: @escaping ([TermLine]) -> Void) {
        self.emit = emit
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            begin()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, !self.finished else { return }
            // The gate may have warmed a fix up before the show started; better the
            // one we have than none at all.
            if let c = LocationStore.shared.coordinate {
                self.deliver([
                    TermLine(label: "  coordinates",
                             text: String(format: "%.6f, %.6f", c.latitude, c.longitude), kind: .alert),
                    kv("  locality", LocationStore.shared.placeName, kind: .alert),
                    note("  (from the pre-show fix — the live request timed out)")
                ])
            } else {
                self.deliver([warn("  location request timed out — no fix acquired")])
            }
        }
    }

    private func begin() {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            deliver([
                warn("  location services DENIED for this app"),
                note("  grant access in System Settings › Privacy & Security › Location Services")
            ])
        default:
            if CLLocationManager.locationServicesEnabled() {
                manager.requestLocation()
            } else {
                deliver([warn("  location services are switched off system-wide")])
            }
        }
    }

    private func deliver(_ lines: [TermLine]) {
        guard !finished else { return }
        finished = true
        var out = section("geolocation")
        out.append(contentsOf: lines)
        emit?(out)
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if m.authorizationStatus != .notDetermined { begin() }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        deliver([warn("  location fix failed: \(error.localizedDescription)")])
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        LocationStore.shared.record(loc)          // the map flies here later
        var lines: [TermLine] = [
            TermLine(label: "  coordinates",
                     text: String(format: "%.6f, %.6f", loc.coordinate.latitude, loc.coordinate.longitude),
                     kind: .alert),
            kv("  accuracy", String(format: "±%.0f m horizontal · ±%.0f m vertical", loc.horizontalAccuracy, max(0, loc.verticalAccuracy))),
            kv("  altitude", String(format: "%.1f m above sea level", loc.altitude)),
            kv("  fix timestamp", stamp(loc.timestamp)),
            kv("  map link", String(format: "https://maps.apple.com/?ll=%.6f,%.6f", loc.coordinate.latitude, loc.coordinate.longitude))
        ]
        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] places, _ in
            guard let self else { return }
            if let p = places?.first {
                LocationStore.shared.record(place: p)
                let street = [p.subThoroughfare, p.thoroughfare].compactMap { $0 }.joined(separator: " ")
                if !street.isEmpty { lines.append(kv("  street", street, kind: .alert)) }
                lines.append(kv("  locality", [p.locality, p.subAdministrativeArea].compactMap { $0 }.joined(separator: ", "), kind: .alert))
                lines.append(kv("  region", [p.administrativeArea, p.postalCode].compactMap { $0 }.joined(separator: " ")))
                lines.append(kv("  country", [p.country, p.isoCountryCode].compactMap { $0 }.joined(separator: " · ")))
                if let areas = p.areasOfInterest, !areas.isEmpty { lines.append(kv("  near", areas.joined(separator: ", "))) }
                if let tz = p.timeZone { lines.append(kv("  local time zone", tz.identifier)) }
            } else {
                lines.append(note("  reverse geocoding unavailable"))
            }
            self.deliver(lines)
        }
    }
}
