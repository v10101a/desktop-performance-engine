import Foundation
import CoreLocation
import Contacts

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

// MARK: - Address book "me" card

func contactCard(_ emit: @escaping ([TermLine]) -> Void) {
    let store = CNContactStore()
    store.requestAccess(for: .contacts) { granted, _ in
        var out = section("address book · me card")
        guard granted else {
            out.append(warn("  contacts access denied — personal card not read"))
            emit(out); return
        }
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
            CNContactJobTitleKey, CNContactEmailAddressesKey, CNContactPhoneNumbersKey,
            CNContactPostalAddressesKey, CNContactBirthdayKey
        ].map { $0 as CNKeyDescriptor }
        guard let me = try? store.unifiedMeContactWithKeys(toFetch: keys) else {
            out.append(note("  no \"me\" card is set in Contacts"))
            emit(out); return
        }
        let name = [me.givenName, me.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        if !name.isEmpty { out.append(kv("  name on card", name, kind: .alert)) }
        if !me.organizationName.isEmpty { out.append(kv("  organization", me.organizationName)) }
        if !me.jobTitle.isEmpty { out.append(kv("  job title", me.jobTitle)) }
        for e in me.emailAddresses.prefix(4) {
            out.append(kv("  email", e.value as String, kind: .alert))
        }
        for p in me.phoneNumbers.prefix(4) {
            out.append(kv("  phone", p.value.stringValue, kind: .alert))
        }
        for a in me.postalAddresses.prefix(3) {
            let f = CNPostalAddressFormatter.string(from: a.value, style: .mailingAddress)
                .replacingOccurrences(of: "\n", with: ", ")
            out.append(kv("  postal address", f, kind: .alert))
        }
        if let b = me.birthday, let m = b.month, let d = b.day {
            out.append(kv("  birthday", "\(m)/\(d)" + (b.year.map { "/\($0)" } ?? ""), kind: .alert))
        }
        if out.count <= 2 { out.append(note("  me card exists but contains no readable fields")) }
        emit(out)
    }
}
