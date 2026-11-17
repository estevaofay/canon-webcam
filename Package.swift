// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "canon-webcam",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "canon-webcam", targets: ["canon-webcam"]),
        .executable(name: "canon-webcam-app", targets: ["canon-webcam-app"]),
    ],
    targets: [
        // libgphoto2 (LGPL-2.1), installed with `brew install libgphoto2`, linked dynamically.
        .systemLibrary(
            name: "CGPhoto2",
            path: "Sources/CGPhoto2",
            pkgConfig: "libgphoto2",
            providers: [.brew(["libgphoto2"])]
        ),
        // libusb (LGPL-2.1), installed with libgphoto2. Used for the fast live-view
        // path, which speaks Canon's PTP commands directly.
        .systemLibrary(
            name: "CLibUSB",
            path: "Sources/CLibUSB",
            pkgConfig: "libusb-1.0",
            providers: [.brew(["libusb"])]
        ),
        // Canon EOS live view straight over USB (libusb only, no libgphoto2), and
        // the reconnecting live-view loop. Used by the CLI and the menu bar app.
        .target(name: "CanonUSB", dependencies: ["CLibUSB"]),
        // libgphoto2 on top: info, exposure, snapshots, and live view for
        // cameras the direct path doesn't support. CLI only.
        .target(name: "CanonCapture", dependencies: ["CGPhoto2", "CanonUSB"]),
        // Turns live-view JPEGs into 1920x1080 frames and pushes them into a
        // CoreMediaIO virtual camera's sink stream.
        .target(name: "VirtualCamera"),
        // The streaming loop shared by the CLI and the menu bar app: live view in,
        // frames out to the virtual camera, with reconnects.
        .target(name: "WebcamFeed", dependencies: ["CanonUSB", "VirtualCamera"]),
        .executableTarget(name: "canon-webcam", dependencies: ["CanonCapture", "VirtualCamera", "WebcamFeed"]),
        // The menu bar app (bundled into canon-webcam.app by scripts/make-app.sh).
        // Direct USB only: no libgphoto2 to bundle.
        .executableTarget(name: "canon-webcam-app", dependencies: ["WebcamFeed", "CanonUSB"]),
        .testTarget(name: "CanonUSBTests", dependencies: ["CanonUSB"]),
        .testTarget(name: "WebcamFeedTests", dependencies: ["WebcamFeed", "CanonUSB", "VirtualCamera"]),
    ]
)
