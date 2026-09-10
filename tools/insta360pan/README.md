# insta360pan

Pan and zoom around an Insta360 in webcam mode, and hand the view to Resolume over
Syphon. A macOS app, built with nothing but the Command Line Tools.

## What the camera sends, and what this does with it

In webcam mode the camera delivers one 1920×1080 frame with the **front lens in the top
half** and the **rear lens in the bottom half**, each 1920×540. What each half holds is a
fisheye picture — the lens's circular image of everything within about 100° of its axis —
cropped to a band: the top and bottom quarters of the lens's frame are not transmitted.

So the halves are not treated as flat strips to be laid side by side. Each is treated as
what it is, a fisheye, and the sphere is rebuilt from the pair. For every output pixel the
shader works out which direction in the world that pixel looks at, asks each lens where
that direction lands on its image circle, and cross-fades the two where their fields
overlap. That is the stitch, and it accounts for two things a flat join cannot:

- **Lens distortion.** Angle-from-axis becomes radius-on-sensor through the lens's
  projection — equidistant (f·θ) by default, with equisolid, stereographic and orthographic
  available — scaled by the field of view and the image circle's centre and radii. Those
  are the calibration.
- **The gap between the lenses.** The two entrance pupils sit a few centimetres apart, so
  the lenses disagree about where things are: anything on a seam shows twice, or with a
  gap, by an angle that depends on how far away it is. The **stitch distance** is the
  distance the seams are aligned for; each lens is sampled from its own pupil position,
  which is exact for things at that distance, and the **baseline** is the pupil separation.

The view is a window onto that sphere — a band of the equirectangular loop by default, or
a rectilinear virtual camera — and **the window is exactly the frame Syphon publishes**:
what you see in the app is what Resolume gets, pixel for pixel.

## Build and run

```bash
./build.sh
open insta360pan.app
```

The first launch asks for camera access. The build is ad-hoc signed, and an ad-hoc
signature changes identity whenever the binary changes, so macOS asks again after a
rebuild; point `SIGN_IDENTITY` at a self-signed certificate to keep the grant.

Syphon is not on macOS by default. `build.sh` borrows `Syphon.framework` from
TouchDesigner (or `/Library/Frameworks`, or `SYPHON_FRAMEWORK=…`) and copies it into the
bundle, so the app does not depend on TouchDesigner staying installed. It needs a Syphon 5
build that ships `SyphonSubclassing.h` — OBS's copy has no headers and Resolume's is built
with the pre-5 class names, so neither qualifies; the SDK from
https://github.com/Syphon/Syphon-Framework/releases dropped in `/Library/Frameworks` does.

At launch it opens the Insta360 if one is plugged in, else the first external camera,
else whatever is there — and if the Insta360 turns up later it switches to it, unless you
have picked a camera by hand.

## Controls

| do this | to |
| --- | --- |
| drag | pan |
| pinch | zoom about the pointer |
| two-finger scroll | pan |
| ⌥ + scroll | zoom (for a mouse) |
| two-finger double-tap | toggle 1× and 3× at the pointer |
| arrows | nudge |
| `=` / `-` | zoom in / out about the centre |
| `R` or `0` | reset: front lens centred, 1× |
| `V` | loop ↔ rectilinear |
| `X` | raw frame, with the lens model drawn over it |
| `K` (⌘K) | the calibration panel |
| `S` | swap halves — the rear lens is the top half |
| `M` / `N` | mirror the front / rear lens |
| `[` / `]` | seam blend narrower / wider |
| `,` / `.` | stitch distance nearer / farther |
| `D` | next camera · `C` back to the camera · `P` test scene |
| `H` | hide the control bar |
| ⌘O | open a video file as the source |
| ⌃⌘F | full screen |

Everything on a key is also in the menus and on the control bar under the picture. The
status line shows the frame size and rate coming in, the zoom, the yaw and pitch (0°/0° is
the front lens's axis, yaw positive to the right) and whether a Syphon client is attached.

## Calibrating the lens model

The defaults are a guess at the camera's layout — a 200° equidistant fisheye whose image
circle spans the width of the half, centred, with the transmitted band being its middle
— and a guess is all it can be until the real frame is in front of the app. Fitting it
takes a minute:

1. Press `X` for the **raw frame**. The magenta ring is where the model thinks the edge of
   the fisheye is, the cyan ring is 90° from the axis, the yellow ring is where the seam
   blend starts, and the green cross is the axis.
2. Press `K` for the **calibration panel** and move *circle centre* and *circle radius*
   until the magenta ring sits on the real edge of the fisheye and the cross on its centre.
   If the fisheye is wider than it is tall the radii differ; that is fine.
3. Press `X` again, pan to a seam (`→` until the yaw reads ±90°), and set *field of view*
   until things stop appearing twice or with a gap. Widen *seam blend* to soften what is
   left. If a seam is straight but tilted or stepped, the *rear yaw / pitch / roll* trims
   turn the rear lens to meet the front one.
4. Set *stitch distance* to how far away the people are. Nearer things then double up
   slightly and farther ones close up; that is the parallax and no calibration removes it,
   it only picks the distance that is right.
5. If the halves are the wrong way round or a lens reads backwards, **Swap** and
   **Mirror** in the bar or the Lens menu.

Every change is saved half a second later to
`~/Library/Application Support/insta360pan/calibration.json` and loaded next launch;
`--fresh` starts from the defaults and `--calibration PATH` keeps a model somewhere else.

The **test scene** (`P`, or `--test`) is a world painted on a sphere — a 15° graticule,
the horizon and the front axis bold, the rear axis black, magenta discs on the seams, a
checkered band above the horizon and a blue one below, a dot circling every twelve
seconds — rendered through the default lens model *as the camera would send it*, parallax
included. Stitched with the defaults it is seamless by construction, so every control
shows its effect against a stitch that was right: put the field of view wrong and the
discs double; put the stitch distance wrong and they ghost.

## In Resolume

Sources › Syphon › **Insta360 Pan**. The output frame is 1920×1080 by default; the *Out*
popup (or `--size`) offers 720p, 1440p and 4K, and the window re-letterboxes to match. A
frame is published only when something changed — a new camera frame, a pan, a zoom, a
setting — so a paused feed costs Resolume nothing. Syphon surfaces are bottom row first
(the OpenGL convention the format grew up with); the app renders them that way and turns
its own window's copy back over.

## Command line

```
usage: insta360pan [options]
  --camera NAME        open the camera whose name contains NAME
                       (default: the Insta360 if present, else the first external camera)
  --test               show the synthetic test scene instead of a camera
  --file PATH          loop a video file (a recording of the webcam feed) instead of a camera
  --size WxH           Syphon output frame size (default 1920x1080)
  --name NAME          Syphon server name (default "Insta360 Pan")
  --yaw DEG            starting yaw; 0 = front-lens axis, positive = right
  --pitch DEG          starting pitch; positive = up
  --zoom Z             starting zoom; 1 = the band's full height fills the frame
  --rect               rectilinear (virtual camera) view instead of the loop
  --raw                show the frame as it arrives, with the lens model drawn over it
  --calibrate          open the lens calibration panel at launch
  --snapshot PATH      render one output frame to a PNG at PATH and quit
lens model (saved as it changes to ~/Library/Application Support/insta360pan/calibration.json):
  --calibration PATH   load and save the lens model here instead
  --fresh              ignore the saved lens model; start from the defaults
  --fov DEG            lens field of view at the edge of its image circle
  --projection NAME    equidistant | equisolid | stereographic | orthographic
  --circle CX,CY,RX,RY image circle in a 1920×540 half: centre and radii, pixels
  --blend DEG          seam cross-fade width
  --distance M         stitch distance: things this far away join up across the seams
  --baseline M         distance between the two lenses' pupils
  --swap               the rear lens is the top half of the frame
  --mirror-front       the front lens's image reads backwards
  --mirror-rear        the rear lens's image reads backwards
```

`open insta360pan.app --args --test` works from Finder too. `--file` takes a recording of
the webcam feed (OBS, QuickTime) and loops it, so the lens model can be fitted without the
camera in the room.

## Checking the feed without Resolume

```bash
./probe.sh                # connect to "Insta360 Pan", print 30 frames' worth
./probe.sh "Insta360" 100
```

The probe is a separate process that connects the way any Syphon client would and prints
the frame size, the rate, and a few pixel values. `--snapshot` writes the output frame to a
PNG from inside the app; the two together prove the picture and the publishing without
anyone at the keyboard.

## How it is built

- `build.sh` runs `swiftc` straight to a bundle, the way `~/segcam/build.sh` does: no
  Xcode project, no SwiftPM. The Metal shaders are compiled at launch from a string
  (`Shaders.swift`), because the Metal compiler is part of Xcode, not the Command Line
  Tools.
- `Calibration.swift` is the lens model and how it becomes shader uniforms: each lens is a
  world→lens rotation, an image circle, a projection, a field of view and a pupil offset
  along the camera's axis. `Viewport.swift` is the whole pan/zoom model, a value type with
  no AppKit in it: yaw, pitch, zoom, loop or rectilinear, and how far up the band goes.
- The stitch is one fragment shader (`stitch_fragment`): output pixel → world direction →
  a point at the stitch distance → that point from each lens's pupil → each lens's image
  → weighted by how far from the edge of its field the direction is. There is no stitched
  intermediate image; the synthetic camera (`synth_fragment`) is the same maths run the
  other way.
- Syphon publishing goes through `SyphonServerBase` and its subclassing category
  (`copySurfaceForWidth:height:options:` and `publish`), not `SyphonMetalServer`: the
  framework builds that ship inside other apps mostly leave the Metal server out, and the
  base class plus an IOSurface is all the Metal server does internally anyway. The output
  texture *is* the Syphon surface, so rendering into it is publishing.
- `Camera.swift` is segcam's, with format selection added: it asks the device for
  1920×1080 explicitly rather than for a preset, because that frame is the point.
