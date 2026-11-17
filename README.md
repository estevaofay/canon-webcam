# canon-webcam

Use an old Canon EOS DSLR as a webcam on a modern Mac. It needs no Canon software and no paid Apple account.

Canon's EOS Webcam Utility has dropped (or never had) support for many older bodies, such as the Rebel T3i (600D) and the Rebel T5 (1200D). These cameras still have excellent sensors and lenses, and they all speak the same USB live-view protocol. canon-webcam talks to the camera directly over USB, using the open-source [libgphoto2](https://github.com/gphoto/libgphoto2) library and its own fast path for Canon live view, and feeds the live view into a macOS virtual camera. Zoom, Google Meet, FaceTime, Teams, Slack and other apps can then use it like any other camera.

```
 Canon DSLR ──USB──▶ canon-webcam ──frames──▶ virtual camera ──▶ Zoom / Meet / FaceTime
            (live view: ~28 fps JPEG,       (OBS Virtual Camera, or this
             1056×704; sent as it arrives)   repo's own "Canon Webcam")
```

## Supported cameras

canon-webcam should work with any camera that libgphoto2 can stream live view from, which includes most Canon EOS bodies from about 2008 onward. Canon EOS bodies use canon-webcam's faster direct USB path; other cameras use libgphoto2.

| Camera | Status |
| --- | --- |
| EOS Rebel T5 / 1200D / Kiss X70 | Tested end to end through OBS Virtual Camera: 1056×704, about 28 fps from the camera and to apps |
| EOS Rebel T3i / 600D / Kiss X5 | Tested end to end through OBS Virtual Camera: 1056×704, about 30 fps from the camera and to apps |

Run `canon-webcam info` to check your camera. If it reports `Live view: supported`, it should work. Reports for other models are welcome.

## Install

### 1. OBS Virtual Camera (free, no Apple account)

macOS only lets signed Camera Extensions provide virtual cameras. OBS Studio ships one that is already signed. Its input accepts frames from any app, so canon-webcam can feed it directly. OBS itself does not need to be running.

1. Install [OBS Studio](https://obsproject.com/download) (or `brew install --cask obs`).
2. Open OBS once and click **Start Virtual Camera**. macOS will ask you to allow the camera extension: go to **System Settings → General → Login Items & Extensions → Camera Extensions** and switch on **OBS Virtual Camera**. Then quit OBS.

### 2. The menu bar app

For now the app needs an Apple silicon Mac running macOS 27 or later.

1. Download `canon-webcam-<version>.dmg` from the [latest release](https://github.com/estevaofay/canon-webcam/releases/latest), open it, and drag **canon-webcam** to **Applications**. What changed in each version is in [CHANGELOG.md](CHANGELOG.md).
2. Open it. The app isn't signed with an Apple Developer ID, so the first time macOS refuses to open it. Go to **System Settings → Privacy & Security**, scroll down to the message about canon-webcam, click **Open Anyway**, and confirm.
3. When macOS asks whether canon-webcam may use the camera, click **Allow**: feeding a virtual camera counts as camera access, and without it macOS silently drops every frame. macOS asks again after each update, because every build has a new signature.
4. Connect the camera over USB, set the mode dial to P or M, and switch it on. The camera icon in the menu bar gets a red dot when it's live; click it to see what video apps see.
5. In Zoom, Meet or FaceTime, choose **OBS Virtual Camera**.

To build the app and the DMG yourself: install the Xcode Command Line Tools and `brew install libusb`, then run `make dmg` (the app is written to `dist/`).

### Or: the command-line tool

You need macOS 13 or later, [Homebrew](https://brew.sh), and the Xcode Command Line Tools (`xcode-select --install`).

```bash
brew install libgphoto2
git clone https://github.com/estevaofay/canon-webcam.git
cd canon-webcam
make install          # builds and installs to ~/.local/bin/canon-webcam
```

With OBS Virtual Camera allowed (step 1 above), connect the camera over USB, switch it on, and run:

```bash
canon-webcam
```

The first time, macOS asks whether your terminal app (Terminal, iTerm, …) may use the camera. Click **Allow**. Then choose **OBS Virtual Camera** in your video app.

To confirm the whole path works without opening a video app, run `canon-webcam check`. It feeds the virtual camera and reads it back the way Zoom would, then reports how many of the DSLR's own frames came out.

### Without OBS: this repo's own "Canon Webcam" camera (needs an Apple Developer account)

The `Extension/` folder contains a native Camera Extension that shows up as **Canon Webcam**, plus a small app that installs it. Camera Extensions are *system extensions*: macOS only installs them when they are signed by a paid Apple Developer team with the System Extension capability, and when the host app is in `/Applications`. A free Apple ID ("Personal Team") cannot get that entitlement. Unsigned builds compile, but macOS refuses to load them while System Integrity Protection is on.

If you have a membership:

1. `brew install xcodegen`, then `cd Extension && xcodegen generate`
2. Open `Extension/CanonWebcam.xcodeproj`. For both targets, set your team and change the `io.github.estevaofay` bundle-id prefix to one you own. Archive or build, then copy `CanonWebcam.app` to `/Applications`.
3. Open it, click **Install camera**, and approve it in System Settings.
4. Run `canon-webcam --camera "Canon Webcam"`. Until frames arrive, apps see a placeholder card with that command.

`make extension` builds an unsigned copy, which is useful for checking that it compiles.

## Usage

```
canon-webcam [run] [--camera NAME] [--fit] [--expose] [--fps N] [--keep-alo]
                   [--no-camera-screen] [--gphoto2]
    Stream live view into a virtual camera until Ctrl-C.
    --camera NAME  virtual camera to feed (default "OBS Virtual Camera")
    --fit          show the whole 3:2 frame with side bars (default: crop to 16:9)
    --expose       set 1/60s + ISO Auto on every connect (mode dial on M)
    --fps N        send apps a steady N fps, repeating the newest camera frame
                   when the next isn't ready (default 0 = each frame as it arrives)
    --keep-alo     leave Auto Lighting Optimizer as set on the camera (by default
                   it is off while streaming and restored afterwards)
    --no-camera-screen
                   send live view only to the computer (by default it also
                   shows on the camera's own screen)
    --gphoto2      read live view through libgphoto2 instead of the faster
                   direct USB path (for troubleshooting)
canon-webcam check [--camera NAME] [--no-camera-screen] [SECONDS]
    Feed the virtual camera and read it back like a video app, to confirm the
    DSLR's frames come out the other side.
canon-webcam peek [--camera NAME] [-o FILE] [SECONDS]
    Watch a virtual camera like a video app (read-only, safe next to a running
    feed) and save the last frame it shows: "what does Zoom see right now?"
canon-webcam cameras          list virtual cameras that accept frames
canon-webcam info             camera model, live-view support, exposure, battery
canon-webcam expose           set webcam-friendly exposure: 1/60s, ISO Auto
canon-webcam snap [FILE]      save one live-view frame as JPEG
canon-webcam bench [--keep-alo] [--no-camera-screen] [--gphoto2] [SECONDS]
                              measure the live-view frame rate
```

If the camera is unplugged, switched off or times out, canon-webcam keeps running and reconnects when the camera comes back.

## Camera tips

- **Exposure.** With the mode dial on **M**, live view shows the exposure you set: at 1/4000s it is almost black. Run `canon-webcam expose` once (1/60s, ISO Auto), or use `--expose`. **P** mode also works.
- **Frame rate.** Over USB a Rebel T3i delivers its full 30 live-view frames per second and a Rebel T5 about 28; canon-webcam passes each frame on as soon as it arrives, so apps get the camera's own rate with the least delay (`--fps N` sends a steady N instead, repeating frames to fill gaps). Both run live view on a 30 fps clock, but on the T5 the **Auto Lighting Optimizer** (ALO) processing makes it miss slots: with ALO on, it manages about 21 fps (the T3i keeps up either way). canon-webcam therefore switches ALO off while streaming and puts your setting back when it stops; `--keep-alo` leaves it alone. If canon-webcam is force-quit or the camera is unplugged while streaming, the next run with that camera restores it. With the mode dial on the movie position, a T3i refuses setting changes, so ALO stays as it is (the movie position has its own ALO setting); P or M avoids that. Shutter speed, ISO, autofocus method, picture style and live-view size made no real difference in our tests, and movie mode is no faster. A true 30 or 60 needs the camera's HDMI output and a capture device, and on the T5 that output includes the camera's on-screen information.
- **Camera screen.** While streaming, live view also shows on the camera's own screen, which helps with framing and focus; it costs no frame rate. `--no-camera-screen` turns it off.
- **Focus** once, manually or with a half-press, before you start. These bodies have no continuous autofocus in live view.
- **Power.** Live view drains the battery in well under an hour. Use an AC dummy battery: Canon ACK-E8 for the T3i (LP-E8), ACK-E10 for the T5 (LP-E10), or a third-party equivalent.
- **Turn off auto power-off** (camera menu → Auto power off → Disable).
- **Close Photos and Image Capture.** macOS's camera service (`ptpcamerad`) grabs the camera when it is plugged in. canon-webcam stops it right before connecting; it restarts by itself afterwards.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `Could not claim the USB device` | Another app has the camera (Photos, Image Capture, EOS Utility, gphoto2). Quit it and retry. |
| `virtual camera "OBS Virtual Camera" not found` | The OBS camera extension isn't allowed yet: see Install, step 1. `canon-webcam cameras` lists what is available. |
| `camera access is not allowed for the app running canon-webcam` | Allow your terminal app in **System Settings → Privacy & Security → Camera**. |
| Apps only show the OBS placeholder; `check` reports 0 DSLR frames | The camera extension can get stuck if something fed it without camera permission. Restart it: switch **OBS Virtual Camera** off and on in System Settings → General → Login Items & Extensions → Camera Extensions (or run `sudo killall com.obsproject.obs-studio.mac-camera-extension`; macOS relaunches it). |
| `peek` shows the DSLR, but Meet/Zoom shows something else or doesn't list the camera | The app is holding an old connection, typically after the camera extension restarted: pick another camera and switch back, or quit the app or browser completely (Cmd-Q) and reopen it. Reloading the tab is not enough. Run only one `canon-webcam` at a time: two copies keep taking the DSLR from each other. If it shows an OBS scene, the OBS app's own **Start Virtual Camera** is on and competing for the camera: stop it in OBS. Browsers also need camera access in System Settings → Privacy & Security → Camera. |
| The image is black or very dark | Shutter speed is too fast for live view; run `canon-webcam expose`. |
| `waiting: no camera found` | Check the USB cable and that the camera is on. Some bodies need the mode dial off the full-auto green square. |
| Video freezes for a moment | The camera is busy (metering or autofocus); it recovers by itself. |

## How it works

- `Sources/CanonCapture` talks to the camera. `DirectLiveView` speaks Canon's PTP live-view commands over USB through libusb, asking only for frames (libgphoto2 spends four extra USB round trips per frame, which caps a T5 at about 14 fps), and switches off Auto Lighting Optimizer while streaming. `EOSCamera` wraps libgphoto2 for everything else (`info`, `expose`, `snap`) and for live view on cameras the direct path doesn't support. Both stop `ptpcamerad` before connecting.
- `Sources/VirtualCamera` decodes each JPEG with Core Image into a 1920×1080 BGRA `CVPixelBuffer`, then finds the target camera through CoreMediaIO. It opens the camera's *sink* stream (`CMIOStreamCopyBufferQueue` + `CMIODeviceStartStream`) and enqueues each frame as a `CMSampleBuffer`. The Camera Extension forwards those frames to its *source* stream, which is what video apps read.
- `Extension/` is a Camera Extension with exactly that sink → source design, written from scratch for this project.
- `scripts/t5cam.sh` is the original shell prototype, using the `gphoto2` command-line tool and ffmpeg. It is kept as a dependency-light fallback.

## Contributing

Bug reports, camera reports ("works with my EOS …") and pull requests are welcome. Please open an issue first for anything big.

- Build and test: `swift test`, `make install` (command-line tool), `make app` (menu bar app in `dist/`).
- Hardware checks: with a camera connected, `canon-webcam bench` measures live view and `canon-webcam check` confirms frames reach the virtual camera.
- Releases are made with `make release`; see [docs/RELEASING.md](docs/RELEASING.md).

## License

MIT; see [LICENSE](LICENSE). libgphoto2 and libusb are LGPL-2.1. The command-line tool links them dynamically from your Homebrew install; the menu bar app ships an unmodified copy of libusb as a replaceable dynamic library, with its license and a pointer to its source in `canon-webcam.app/Contents/Resources`. Not affiliated with Canon or OBS Studio.
