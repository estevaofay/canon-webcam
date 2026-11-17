import Foundation

/// macOS runs `ptpcamerad`, which grabs every PTP camera as soon as it is
/// plugged in (for Photos / Image Capture) and respawns when killed. libgphoto2
/// can only claim the USB interface in the short window after it is killed.
public enum MacOSCameraDaemon {
    public static func release() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-9", "-f", "/usr/libexec/ptpcamerad"]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        try? pkill.run()
        pkill.waitUntilExit()
    }
}
