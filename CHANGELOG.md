# Changelog

Each release's notes on GitHub are its section here. Versions follow
[semantic versioning](https://semver.org).

## 1.0.0

The first release: use an old Canon EOS DSLR as a webcam on a Mac, from the menu bar.

- **Menu bar app.** Plug in the camera and it shows up in Zoom, Meet, FaceTime and other apps through OBS Virtual Camera. The panel shows a live preview of what apps see, the frame rate actually sent, the output format and the camera's battery. It also has a main switch, a switch for showing the picture on the camera's own screen, and Open at login.
- **Fast USB live view.** canon-webcam talks to the camera over USB directly and passes each frame on as it arrives: about 30 fps from a Rebel T3i and 28 from a Rebel T5.
- **Camera settings put back.** Auto Lighting Optimizer, which slows live view down, is switched off while streaming and restored afterwards, even after a crash or an unplugged cable.
- **Clear status.** The app says when no camera is connected, when another app holds it, when OBS Virtual Camera is missing, or when camera access is needed. It reconnects by itself when the camera comes back.
- **Command-line tool** (`make install`) with `check`, `peek`, `bench`, `snap`, `info` and `expose` for testing and troubleshooting, and libgphoto2 support for other cameras.

Tested with the EOS Rebel T3i (600D) and Rebel T5 (1200D).
