# Vendored effect code

Five directories under `Effects/` are **ports of standalone apps**, not code written for
this project:

| Directory | Upstream app |
| --- | --- |
| `PhotoWall/` | photowall |
| `GlassTorus/` | GlassTorus |
| `SystemProbe/` | systemprobe |
| `FileSwarm/` | FileSwarm |
| `DeskWallpaper/` | BlackWallpaper / GlitchWallpaper / RecursiveWallpaper |

Each is a mix of three kinds of file, and they have different rules.

## 1. Vendored — do not refactor

Files carried over byte-identical, or nearly so. Leave them alone even when they look
improvable: the value is that a fix upstream can be re-applied by diffing, and every
local edit makes that harder.

`PhotoWall/Coverage.swift`, `PhotoWall/Planner.swift`, `PhotoWall/PhotoIndex.swift`,
`GlassTorus/TorusScene.swift`, `GlassTorus/TorusMesh.swift`, `GlassTorus/Math.swift`,
`GlassTorus/Snapshot.swift`, `FileSwarm/Patterns.swift`, `FileSwarm/Geometry.swift`,
`FileSwarm/SwarmFileStore.swift`, `FileSwarm/SlotRegistrar.swift`,
`FileSwarm/DesktopIconPositioner.swift`, `DeskWallpaper/GlitchImage.swift`,
`SystemProbe/{Term,Machine,Performance,Storage,Devices,Personal,TerminalView}.swift`.

This is why a few unused accessors survive here (`SwarmFileStore.foreignFileCount`,
`ScreenEnvironment.isLive`, `SwarmEngine.desktopPath`). They fed control panels in the
standalone apps. Deleting them would buy nothing and widen the diff from upstream.

## 2. Vendored but modified — keep the diff small and explained

Files that had to change to work under the show clock. Every one carries a
`**Changed in the port.**` note saying what and why. Extend that note rather than
editing silently.

`PhotoWall/PhotoWindow.swift`, `GlassTorus/TorusRenderer.swift`,
`GlassTorus/TorusView.swift`, `GlassTorus/ScreenEnvironment.swift`,
`SystemProbe/Probe.swift`, `FileSwarm/SwarmEngine.swift`.

## 3. Ours — normal code

The adapters. Refactor freely; these are the seam between vendored code and the engine.

`*Controller.swift` in each directory, plus `PhotoWall/PhotoWallConfig.swift` and
`DeskWallpaper/WallpaperImage.swift`.

---

## The duplication trap

Vendoring means **the same helper can arrive several times under different names**, and
the compiler only complains when the names collide.

`SplitMix64` arrived three times — DPE's own copy in `DesktopIconController.swift`, one
in GlitchWallpaper, one in FileSwarm — all the same algorithm with the same constants
and slightly different helper methods. That was caught only because two of them shared a
name and the build broke. A differently-named copy would have shipped silently.

**Before adding a vendored file, grep for what it defines.** When a helper already
exists in DPE, delete the incoming copy and add whatever methods the ported code needs
as an `extension` on the existing type — that is what `DeskWallpaper/GlitchImage.swift`
and `FileSwarm/Geometry.swift` now do, so the ported code below those extensions is
still unmodified.

Where behaviour differed, the difference moves to the adapter rather than the vendored
file: FileSwarm's `SplitMix64` mapped seed 0 to the golden-ratio constant and DPE's does
not, so `FileSwarmController` applies that guard when it sets the seed, and the nine
seeded call sites in `Patterns.swift` stay untouched.

Things that look like duplication but are not, so nobody "fixes" them:

- `ScreenEnvironment` and `WallpaperImage.captureDisplay` both use ScreenCaptureKit, but
  one holds a live 20 fps stream and the other takes a single screenshot.
- `SystemProbe/Term.swift` has its own byte/percent formatters. They are part of the
  report's visual style and vendored with it.
