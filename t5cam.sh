#!/usr/bin/env bash
# t5cam.sh — use an old Canon EOS DSLR (Rebel T5 / 1200D, T3i / 600D, ...) as a
# live camera on macOS, with no Canon software. Uses open-source libgphoto2.
#
# Requirements:  brew install gphoto2 ffmpeg
#
# Usage:
#   ./t5cam.sh preview     live window (ffplay) — quick check that it works
#   ./t5cam.sh obs         feed for OBS: add a Media Source with input
#                          udp://127.0.0.1:5000 (uncheck "Local File"), then
#                          press "Start Virtual Camera" — Zoom/Meet/FaceTime
#                          will see it as "OBS Virtual Camera".
#   ./t5cam.sh snap [file] save one live-view frame (default: snap.jpg)
#   ./t5cam.sh expose      set webcam-friendly exposure (1/60s, ISO Auto);
#                          only matters when the mode dial is on M
#   ./t5cam.sh info        show the detected camera and key settings
#
# Camera tips: mode dial on M (then run `expose`) or P; focus manually or with
# a half-press before starting; disable auto power-off; use an AC dummy battery.

set -euo pipefail

PORT="${T5CAM_UDP_PORT:-5000}"

# macOS's own camera service (ptpcamerad) grabs PTP cameras as soon as they
# are plugged in and respawns when killed, so free the camera right before
# every connection.
free_camera() { pkill -9 -f /usr/libexec/ptpcamerad 2>/dev/null || true; }

need() { command -v "$1" >/dev/null || { echo "missing: $1 (brew install $2)" >&2; exit 1; }; }
need gphoto2 gphoto2
need ffmpeg ffmpeg

# Live view as an endless MJPEG stream on stdout. Restarts if the camera
# hiccups or gphoto2 exits, so a long call doesn't die on one glitch.
stream() {
  while true; do
    free_camera
    gphoto2 --capture-movie --stdout 2>/dev/null || true
    echo "t5cam: stream stopped, reconnecting in 1s..." >&2
    sleep 1
  done
}

case "${1:-}" in
  preview)
    need ffplay ffmpeg
    stream | ffplay -loglevel error -fflags nobuffer -flags low_delay \
      -framedrop -f mjpeg -window_title "Canon live view" -i -
    ;;
  obs)
    echo "Streaming to udp://127.0.0.1:${PORT} — add it as an OBS Media Source. Ctrl-C to stop." >&2
    stream | ffmpeg -loglevel error -use_wallclock_as_timestamps 1 -f mjpeg -i - \
      -c:v libx264 -preset ultrafast -tune zerolatency -g 15 -pix_fmt yuv420p \
      -f mpegts "udp://127.0.0.1:${PORT}?pkt_size=1316"
    ;;
  snap)
    out="${2:-snap.jpg}"
    free_camera
    gphoto2 --capture-preview --force-overwrite --filename "$out" >/dev/null
    # gphoto2 prefixes preview files with "thumb_"
    d=$(dirname "$out"); b=$(basename "$out")
    [ -f "$d/thumb_$b" ] && mv -f "$d/thumb_$b" "$out"
    echo "saved $out"
    ;;
  expose)
    free_camera
    gphoto2 --set-config shutterspeed=1/60 --set-config iso=Auto
    free_camera
    gphoto2 --get-config shutterspeed --get-config iso | grep -E "^(Label|Current)"
    ;;
  info)
    free_camera
    gphoto2 --summary | grep -E "^(Manufacturer|Model)|Version:" || true
    for k in autoexposuremode shutterspeed aperture iso focusmode batterylevel; do
      free_camera
      printf "%-17s %s\n" "$k" "$(gphoto2 --get-config "$k" 2>/dev/null | sed -n 's/^Current: //p')"
    done
    ;;
  *)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
