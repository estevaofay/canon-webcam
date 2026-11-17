import AVFoundation
import CanonUSB
import CoreImage
import ServiceManagement
import SwiftUI
import WebcamFeed

/// The app's state: settings the user controls, and what the feed reports.
@MainActor
final class AppModel: ObservableObject {
    /// The main switch: stream whenever a camera is connected.
    @Published var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            defaults.set(isOn, forKey: Keys.streaming)
            isOn ? startFeed() : stopFeed()
        }
    }
    @Published var showOnCameraScreen: Bool {
        didSet {
            guard showOnCameraScreen != oldValue else { return }
            defaults.set(showOnCameraScreen, forKey: Keys.showOnCameraScreen)
            let on = showOnCameraScreen
            work.async { [feed] in feed.setShowOnCameraScreen(on) }
        }
    }
    @Published private(set) var openAtLogin = SMAppService.mainApp.status == .enabled

    @Published private(set) var status = FeedStatus.stopped
    @Published private(set) var battery: BatteryLevel?
    @Published private(set) var sentFPS = 0.0
    @Published private(set) var preview: CGImage?
    /// The last camera seen, so the header keeps its name while switched off.
    @Published private(set) var lastModel: String?

    private enum Keys {
        static let streaming = "streaming"
        static let showOnCameraScreen = "showOnCameraScreen"
    }

    private let defaults = UserDefaults.standard
    private let feed: WebcamFeed
    /// start/stop block while the camera opens or closes: keep them off the main thread.
    private let work = DispatchQueue(label: "canon-webcam.app.feed")
    private let imageContext = CIContext()
    private var previewTimer: Timer?
    /// The frame the preview shows, so an unchanged frame isn't converted again.
    private var previewFrame: CVPixelBuffer?

    init() {
        defaults.register(defaults: [Keys.streaming: true, Keys.showOnCameraScreen: true])
        let cameraScreen = defaults.bool(forKey: Keys.showOnCameraScreen)
        isOn = defaults.bool(forKey: Keys.streaming)
        showOnCameraScreen = cameraScreen
        var settings = FeedSettings()
        settings.liveView.showOnCameraScreen = cameraScreen
        feed = WebcamFeed(settings: settings)
        feed.onChange = { [weak self] in Task { @MainActor in self?.refresh() } }
    }

    /// Asks for camera access the first time (feeding a virtual camera counts
    /// as camera access), then starts streaming if the switch is on.
    func launch() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else {
            if isOn { startFeed() }
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { _ in
            Task { @MainActor [weak self] in
                guard let self, self.isOn else { return }
                self.startFeed()
            }
        }
    }

    /// Stops streaming and restores the camera before the app quits.
    func shutdown() {
        previewTimer?.invalidate()
        work.sync { feed.stop() }
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("canon-webcam: could not change Open at login: \(error)")
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Preview (only while the panel is open)

    func panelAppeared() {
        updatePreview()
        previewTimer?.invalidate()
        // As often as the camera can deliver, so the preview moves like the video.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePreview() }
        }
        // .common keeps it running while the panel is being interacted with.
        RunLoop.main.add(timer, forMode: .common)
        previewTimer = timer
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    func panelDisappeared() {
        previewTimer?.invalidate()
        previewTimer = nil
        preview = nil
        previewFrame = nil
    }

    private func updatePreview() {
        guard let frame = feed.latestFrame() else { preview = nil; previewFrame = nil; return }
        guard frame !== previewFrame else { return }
        previewFrame = frame
        let image = CIImage(cvPixelBuffer: frame)
        let scale = 640 / image.extent.width
        preview = imageContext.createCGImage(image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
                                             from: image.extent.applying(CGAffineTransform(scaleX: scale, y: scale)))
    }

    // MARK: Feed

    private func startFeed() { work.async { [feed] in feed.start() } }
    private func stopFeed() { work.async { [feed] in feed.stop() } }

    private func refresh() {
        status = feed.status
        battery = feed.battery
        sentFPS = feed.sentFPS
        if case let .live(model) = status { lastModel = model }
    }
}
