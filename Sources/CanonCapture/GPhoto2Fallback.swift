@_exported import CanonUSB
import CGPhoto2
import Foundation

extension EOSCamera: LiveViewCamera {
    public func nextFrame() throws -> Data { try capturePreview() }
}

extension LiveView {
    /// Adds libgphoto2 to the live-view loop: as the fallback for cameras the
    /// direct USB path doesn't support or, with `preferDirectUSB` false, as the
    /// only path. `onConnect` is applied through libgphoto2 after each
    /// (re)connection, before live view starts (e.g. to set exposure).
    public func useGPhoto2(preferDirectUSB: Bool, onConnect: ((EOSCamera) throws -> Void)? = nil) {
        let gphoto2: (LiveViewOptions) throws -> LiveViewCamera = { [weak self] _ in
            let camera = try EOSCamera()
            guard camera.supportsLiveView else {
                camera.close()
                Thread.sleep(forTimeInterval: 3)
                throw CameraError(code: GP_ERROR_NOT_SUPPORTED, action: "\(camera.model) live view (not supported by libgphoto2)")
            }
            if let onConnect {
                do { try onConnect(camera) } catch { self?.onEvent(.notice("\(error)")) }
            }
            return camera
        }
        guard preferDirectUSB else {
            connect = gphoto2
            connectIsDirect = false
            fallback = nil
            return
        }
        let direct = connect
        connect = { [weak self] options in
            if let onConnect {
                // Apply settings through libgphoto2 first, then hand over.
                let camera = try EOSCamera()
                do { try onConnect(camera) } catch { self?.onEvent(.notice("\(error)")) }
                camera.close()
            }
            return try direct(options)
        }
        connectIsDirect = true
        fallback = gphoto2
    }
}
