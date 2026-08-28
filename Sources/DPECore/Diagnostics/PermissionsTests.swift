import Foundation

/// What the intro gate asks for.
///
/// The point of the gate is that NOTHING the show needs is asked for after the first
/// beat, and that is easy to regress: add an effect that touches a protected folder and
/// the dialog quietly moves back into the middle of the song, where nobody is watching
/// the logs. `Permissions.plan` exists so this can be asserted without firing a prompt —
/// these tests deliberately never call `preflight`.
enum PermissionsTests {
    private static func event(_ json: String) -> ResolvedEvent? {
        guard let ev = try? JSONDecoder().decode(TimelineEvent.self, from: Data(json.utf8))
        else { return nil }
        return ResolvedEvent(fireTime: 0, action: ev.action)
    }

    static func run(_ t: TestHarness) {
        t.suite("permissions") { t in
            let home = FileManager.default.homeDirectoryForCurrentUser
            func folder(_ name: String) -> Permissions.Request {
                .folder(home.appendingPathComponent(name))
            }

            // A show that uses nothing gated asks for nothing at all.
            t.equal(Permissions.plan(for: []), [], "an empty show raises no prompts")
            if let flash = event(#"{"beat":0,"type":"screenFlash","params":{"id":"f"}}"#) {
                t.equal(Permissions.plan(for: [flash]), [],
                        "an effect that touches nothing gated raises no prompts")
            } else { t.expect(false, "screenFlash failed to decode") }

            // The probe reads the home-directory census, so its three gated folders are
            // warmed at the gate rather than prompting over the report at ~60 s.
            if let probe = event(#"{"beat":0,"type":"systemProbe","params":{"id":"p"}}"#) {
                t.equal(Permissions.plan(for: [probe]),
                        [.location, folder("Desktop"), folder("Documents"), folder("Downloads")],
                        "systemProbe asks for location and its three gated census folders")
            } else { t.expect(false, "systemProbe failed to decode") }

            // The photo wall's default roots include ~/Pictures, which macOS does NOT
            // gate — warming it would be a read that buys nothing.
            if let wall = event(#"{"beat":0,"type":"photoWall","params":{"id":"w"}}"#) {
                let plan = Permissions.plan(for: [wall])
                t.expect(!plan.contains(folder("Pictures")),
                         "~/Pictures is not gated, so it is not warmed")
                t.equal(plan.count, 3, "the photo wall warms exactly its three gated roots")
            } else { t.expect(false, "photoWall failed to decode") }

            // Authored roots are honoured, and a lookalike outside the home directory is
            // not mistaken for the real ~/Desktop.
            let decoy = home.appendingPathComponent("archive/Desktop").path
            if let wall = event(#"""
                {"beat":0,"type":"photoWall","params":{"id":"w","dirs":["\#(decoy)","~/Downloads"]}}
                """#) {
                t.equal(Permissions.plan(for: [wall]), [folder("Downloads")],
                        "only the real ~/Downloads is warmed; a nested lookalike is not")
            } else { t.expect(false, "photoWall with dirs failed to decode") }

            // Two events wanting the same folder must not produce two dialogs.
            if let probe = event(#"{"beat":0,"type":"systemProbe","params":{"id":"p"}}"#),
               let wall = event(#"{"beat":0,"type":"photoWall","params":{"id":"w"}}"#) {
                let plan = Permissions.plan(for: [probe, wall])
                t.equal(plan.count, Set(plan.map(\.description)).count,
                        "a folder wanted by two events is only asked for once")
            } else { t.expect(false, "probe + wall failed to decode") }

            // Camera leads, because it is the one prompt the viewer must answer before
            // anything else can be shown to them.
            if let booth = event(#"""
                    {"beat":0,"type":"photoBooth","params":{"id":"b","durationBeats":16,"count":3,"stepBeats":4}}
                    """#),
               let probe = event(#"{"beat":0,"type":"systemProbe","params":{"id":"p"}}"#) {
                t.equal(Permissions.plan(for: [probe, booth]).first, .camera,
                        "the camera prompt is raised first")
            } else { t.expect(false, "photoBooth failed to decode") }

            // Finder automation is asked for at the gate too, and only by the events that
            // actually drive Finder.
            if let icons = event(#"""
                    {"beat":0,"type":"rearrangeIcons","params":{"id":"i","layout":"scatter"}}
                    """#) {
                t.equal(Permissions.plan(for: [icons]), [.finderAutomation],
                        "rearrangeIcons asks for Finder automation")
            } else { t.expect(false, "rearrangeIcons failed to decode") }

            // The shipped show: this is the list the viewer actually sees, and it must
            // stay a list that is fully answerable before the first beat.
            // Bundle.module, not resolveResourcePath: the show's timeline lives in
            // DPECore's SwiftPM resource bundle, which that helper does not search.
            let url = Bundle.module.url(forResource: "timeline", withExtension: "json")
            if let url, let loaded = try? TimelineLoader.load(from: url) {
                t.equal(Permissions.plan(for: loaded.events),
                        [.camera, .location,
                         folder("Desktop"), folder("Documents"), folder("Downloads")],
                        "the shipped show raises camera, location and three folders — nothing else")
            } else {
                t.expect(false, "the shipped timeline failed to load")
            }
        }
    }
}
