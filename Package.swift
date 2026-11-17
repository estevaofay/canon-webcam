// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "canon-webcam",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "canon-webcam", targets: ["canon-webcam"]),
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
        .executableTarget(name: "canon-webcam", dependencies: ["CanonCapture", "VirtualCamera"]),
        .testTarget(name: "CanonUSBTests", dependencies: ["CanonUSB"]),
    ]
)
