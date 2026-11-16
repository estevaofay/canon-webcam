# canon-webcam

Use an old Canon EOS DSLR as a webcam on a modern Mac. It needs no Canon software and no paid Apple account.

Canon's EOS Webcam Utility has dropped (or never had) support for many older bodies, such as the Rebel T3i (600D) and the Rebel T5 (1200D). These cameras still have excellent sensors and lenses, and they all speak the same USB live-view protocol. canon-webcam talks to the camera directly through the open-source [libgphoto2](https://github.com/gphoto/libgphoto2) library and feeds its live view into a macOS virtual camera. Zoom, Google Meet, FaceTime, Teams, Slack and other apps can then use it like any other camera.

```
 Canon DSLR ──USB──▶ canon-webcam ──frames──▶ virtual camera ──▶ Zoom / Meet / FaceTime
            (libgphoto2 live view,          (OBS Virtual Camera, or this
             ~15 fps JPEG, 1056×704)         repo's own "Canon Webcam")
```

## Supported cameras

canon-webcam should work with any camera that libgphoto2 can stream live view from, which includes most Canon EOS bodies from about 2008 onward.

| Camera | Status |
| --- | --- |
| EOS Rebel T5 / 1200D / Kiss X70 | Tested end to end through OBS Virtual Camera: 1056×704, 10–18 fps |
| EOS Rebel T3i / 600D / Kiss X5 | Expected to work (same protocol); not yet tested |

Run `canon-webcam info` to check your camera. If it reports `Live view: supported`, it should work. Reports for other models are welcome.

## Install

You need macOS 13 or later, [Homebrew](https://brew.sh), and the Xcode Command Line Tools (`xcode-select --install`).

```bash
brew install libgphoto2
git clone https://github.com/estevaofay/canon-webcam.git
cd canon-webcam
make install          # builds and installs to ~/.local/bin/canon-webcam
```

Then pick a virtual camera for it to feed.

### Option A: OBS Virtual Camera (free, no Apple account)

macOS only lets signed Camera Extensions provide virtual cameras. OBS Studio ships one that is already signed. Its input accepts frames from any app, so canon-webcam can feed it directly. OBS itself does not need to be running.

1. Install OBS: `brew install --cask obs`
2. Open OBS once and click **Start Virtual Camera**. macOS will ask you to allow the camera extension: go to **System Settings → General → Login Items & Extensions → Camera Extensions** and switch on **OBS Virtual Camera**. Then quit OBS.
3. Connect the camera over USB, switch it on, and run:

   ```bash
   canon-webcam
   ```

   The first time, macOS asks whether your terminal app (Terminal, iTerm, …) may use the camera. Click **Allow**: feeding a virtual camera counts as camera access, and without it macOS silently drops every frame.

4. In Zoom, Meet or FaceTime, choose **OBS Virtual Camera**.

To confirm the whole path works without opening a video app, run `canon-webcam check`. It feeds the virtual camera and reads it back the way Zoom would, then reports how many of the DSLR's own frames came out.

### Option B: this repo's own "Canon Webcam" camera (needs an Apple Developer account)

The `Extension/` folder contains a native Camera Extension that shows up as **Canon Webcam**, plus a small app that installs it. Camera Extensions are *system extensions*: macOS only installs them when they are signed by a paid Apple Developer team with the System Extension capability, and when the host app is in `/Applications`. A free Apple ID ("Personal Team") cannot get that entitlement. Unsigned builds compile, but macOS refuses to load them while System Integrity Protection is on.

If you have a membership:

1. `brew install xcodegen`, then `cd Extension && xcodegen generate`
2. Open `Extension/CanonWebcam.xcodeproj`. For both targets, set your team and change the `io.github.estevaofay` bundle-id prefix to one you own. Archive or build, then copy `CanonWebcam.app` to `/Applications`.
3. Open it, click **Install camera**, and approve it in System Settings.
4. Run `canon-webcam --camera "Canon Webcam"`. Until frames arrive, apps see a placeholder card with that command.

`make extension` builds an unsigned copy, which is useful for checking that it compiles.

## Usage

```
canon-webcam [run] [--camera NAME] [--fit] [--expose]
    Stream live view into a virtual camera until Ctrl-C.
    --camera NAME  virtual camera to feed (default "OBS Virtual Camera")
    --fit          show the whole 3:2 frame with side bars (default: crop to 16:9)
    --expose       set 1/60s + ISO Auto on every connect (mode dial on M)
canon-webcam check [--camera NAME] [SECONDS]
    Feed the virtual camera and read it back like a video app, to confirm the
    DSLR's frames come out the other side.
canon-webcam peek [--camera NAME] [-o FILE] [SECONDS]
    Watch a virtual camera like a video app (read-only, safe next to a running
    feed) and save the last frame it shows: "what does Zoom see right now?"
canon-webcam cameras          list virtual cameras that accept frames
canon-webcam info             camera model, live-view support, exposure, battery
canon-webcam expose           set webcam-friendly exposure: 1/60s, ISO Auto
canon-webcam snap [FILE]      save one live-view frame as JPEG
canon-webcam bench [SECONDS]  measure the live-view frame rate
```

If the camera is unplugged, switched off or times out, canon-webcam keeps running and reconnects when the camera comes back.

## Camera tips

- **Exposure.** With the mode dial on **M**, live view shows the exposure you set: at 1/4000s it is almost black. Run `canon-webcam expose` once (1/60s, ISO Auto), or use `--expose`. **P** mode also works.
- **Frame rate** depends on the camera, not on canon-webcam. On the T5, live view runs at about 14–18 fps in M mode at 1/60s, but drops to about 10 fps in auto modes in dim light. More light helps.
- **Focus** once, manually or with a half-press, before you start. These bodies have no continuous autofocus in live view.
- **Power.** Live view drains the battery in well under an hour. Use an AC dummy battery: Canon ACK-E8 for the T3i (LP-E8), ACK-E10 for the T5 (LP-E10), or a third-party equivalent.
- **Turn off auto power-off** (camera menu → Auto power off → Disable).
- **Close Photos and Image Capture.** macOS's camera service (`ptpcamerad`) grabs the camera when it is plugged in. canon-webcam stops it right before connecting; it restarts by itself afterwards.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `Could not claim the USB device` | Another app has the camera (Photos, Image Capture, EOS Utility, gphoto2). Quit it and retry. |
| `virtual camera "OBS Virtual Camera" not found` | The OBS camera extension isn't allowed yet: see Option A, step 2. `canon-webcam cameras` lists what is available. |
| `camera access is not allowed for the app running canon-webcam` | Allow your terminal app in **System Settings → Privacy & Security → Camera**. |
| Apps only show the OBS placeholder; `check` reports 0 DSLR frames | The camera extension can get stuck if something fed it without camera permission. Restart it: switch **OBS Virtual Camera** off and on in System Settings → General → Login Items & Extensions → Camera Extensions (or run `sudo killall com.obsproject.obs-studio.mac-camera-extension`; macOS relaunches it). |
| `peek` shows the DSLR, but Meet/Zoom shows something else | The app is holding an old connection: pick another camera and switch back, or reload the tab or app. If it shows an OBS scene, the OBS app's own **Start Virtual Camera** is on and competing for the camera: stop it in OBS. Browsers also need camera access in System Settings → Privacy & Security → Camera. |
| The image is black or very dark | Shutter speed is too fast for live view; run `canon-webcam expose`. |
| `waiting: no camera found` | Check the USB cable and that the camera is on. Some bodies need the mode dial off the full-auto green square. |
| Video freezes for a moment | The camera is busy (metering or autofocus); it recovers by itself. |

## How it works

- `Sources/CanonCapture` wraps libgphoto2: it connects (after stopping `ptpcamerad`), calls `gp_camera_capture_preview` in a loop to get live-view JPEGs, and reads and writes settings such as `shutterspeed` and `iso`.
- `Sources/VirtualCamera` decodes each JPEG with Core Image into a 1920×1080 BGRA `CVPixelBuffer`, then finds the target camera through CoreMediaIO. It opens the camera's *sink* stream (`CMIOStreamCopyBufferQueue` + `CMIODeviceStartStream`) and enqueues each frame as a `CMSampleBuffer`. The Camera Extension forwards those frames to its *source* stream, which is what video apps read.
- `Extension/` is a Camera Extension with exactly that sink → source design, written from scratch for this project.
- `scripts/t5cam.sh` is the original shell prototype, using the `gphoto2` command-line tool and ffmpeg. It is kept as a dependency-light fallback.

## License

MIT; see [LICENSE](LICENSE). libgphoto2 is LGPL-2.1 and is linked dynamically from your Homebrew install. Not affiliated with Canon or OBS Studio.
