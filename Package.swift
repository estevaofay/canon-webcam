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
        // Talks to the camera: connect, live view frames, exposure settings.
        .target(name: "CanonCapture", dependencies: ["CGPhoto2"]),
        // Turns live-view JPEGs into 1920x1080 frames and pushes them into a
        // CoreMediaIO virtual camera's sink stream.
        .target(name: "VirtualCamera"),
        .executableTarget(name: "canon-webcam", dependencies: ["CanonCapture", "VirtualCamera"]),
    ]
)
