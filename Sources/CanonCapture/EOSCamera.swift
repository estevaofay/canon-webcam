import CanonUSB
import CGPhoto2
import Foundation

public struct CameraError: Error, CustomStringConvertible {
    public let code: Int32
    public let action: String

    public var description: String {
        "\(action) failed: \(String(cString: gp_result_as_string(code))) (\(code))"
    }

    /// The camera is gone (unplugged, switched off, auto power-off).
    public var isDisconnect: Bool {
        code == GP_ERROR_IO_USB_FIND || code == GP_ERROR_IO || code == GP_ERROR_IO_READ
            || code == GP_ERROR_IO_WRITE || code == GP_ERROR_MODEL_NOT_FOUND || code == GP_ERROR_IO_USB_CLAIM
    }
}

extension CameraError: CameraConnectionError {
    public var isNoCamera: Bool { code == GP_ERROR_MODEL_NOT_FOUND }
    public var isUnsupported: Bool { code == GP_ERROR_NOT_SUPPORTED }
    /// Another app (Photos, Image Capture, EOS Utility…) has the camera.
    public var isInUse: Bool { code == GP_ERROR_IO_USB_CLAIM }
}

@inline(__always)
func check(_ result: Int32, _ action: @autoclosure () -> String) throws {
    if result < GP_OK { throw CameraError(code: result, action: action()) }
}

/// A Canon EOS (or any libgphoto2 camera with live view) connected over USB.
/// Not thread-safe: use one instance from one thread.
public final class EOSCamera {
    private var camera: UnsafeMutablePointer<Camera>?
    private let context: OpaquePointer?
    private var previewFile: OpaquePointer?

    /// libgphoto2's model name, e.g. "Canon EOS 1200D" (Rebel T5) or "Canon EOS 600D" (Rebel T3i).
    public private(set) var model = ""
    /// Whether libgphoto2 can stream live view from this model.
    public private(set) var supportsLiveView = false

    /// Connects to the first camera found.
    public init() throws {
        context = gp_context_new()
        var cam: UnsafeMutablePointer<Camera>?
        try check(gp_camera_new(&cam), "create camera")
        camera = cam

        var result: Int32 = GP_OK
        for _ in 0..<5 {
            MacOSCameraDaemon.release()
            result = gp_camera_init(camera, context)
            if result != GP_ERROR_IO_USB_CLAIM { break }
            usleep(200_000)
        }
        if result < GP_OK {
            gp_camera_unref(camera)
            camera = nil
            gp_context_unref(context)
            throw CameraError(code: result, action: "connect to camera")
        }

        var abilities = CameraAbilities()
        if gp_camera_get_abilities(camera, &abilities) >= GP_OK {
            model = withUnsafeBytes(of: abilities.model) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            supportsLiveView = abilities.operations.rawValue & GP_OPERATION_CAPTURE_PREVIEW.rawValue != 0
        }
    }

    deinit { close() }

    /// Leaves live view (mirror down) and releases the USB connection.
    public func close() {
        if let file = previewFile { gp_file_unref(file); previewFile = nil }
        if let cam = camera {
            gp_camera_exit(cam, context)
            gp_camera_unref(cam)
            camera = nil
            gp_context_unref(context)
        }
    }

    /// Grabs one live-view frame (a JPEG, 1056x704 on Rebel T3i/T5).
    /// The first call raises the mirror and starts live view.
    public func capturePreview() throws -> Data {
        if previewFile == nil {
            var file: OpaquePointer?
            try check(gp_file_new(&file), "allocate frame")
            previewFile = file
        }
        try check(gp_camera_capture_preview(camera, previewFile, context), "capture live-view frame")
        var bytes: UnsafePointer<CChar>?
        var size: UInt = 0
        try check(gp_file_get_data_and_size(previewFile, &bytes, &size), "read live-view frame")
        guard let bytes, size > 0 else { throw CameraError(code: GP_ERROR_CORRUPTED_DATA, action: "read live-view frame") }
        return Data(bytes: bytes, count: Int(size))
    }

    /// Reads a setting by its libgphoto2 name ("shutterspeed", "iso", "aperture", ...).
    public func setting(_ name: String) throws -> String {
        var widget: OpaquePointer?
        try check(gp_camera_get_single_config(camera, name, &widget, context), "read \(name)")
        defer { gp_widget_free(widget) }

        var type = CameraWidgetType(0)
        gp_widget_get_type(widget, &type)
        switch type {
        case GP_WIDGET_RANGE:
            var value: Float = 0
            try check(gp_widget_get_value(widget, &value), "read \(name)")
            return String(value)
        case GP_WIDGET_TOGGLE, GP_WIDGET_DATE:
            var value: Int32 = 0
            try check(gp_widget_get_value(widget, &value), "read \(name)")
            return String(value)
        default:
            var value: UnsafePointer<CChar>?
            try check(gp_widget_get_value(widget, &value), "read \(name)")
            return value.map { String(cString: $0) } ?? ""
        }
    }

    /// Changes a text/choice setting, e.g. `setSetting("shutterspeed", "1/60")`.
    public func setSetting(_ name: String, _ value: String) throws {
        var widget: OpaquePointer?
        try check(gp_camera_get_single_config(camera, name, &widget, context), "read \(name)")
        defer { gp_widget_free(widget) }
        try value.withCString { try check(gp_widget_set_value(widget, $0), "set \(name) to \(value)") }
        try check(gp_camera_set_single_config(camera, name, widget, context), "set \(name) to \(value)")
    }
}
