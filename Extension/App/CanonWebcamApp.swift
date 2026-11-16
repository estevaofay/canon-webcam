import SwiftUI
import SystemExtensions

// Host app for the "Canon Webcam" Camera Extension. Its only job is to ask
// macOS to install (activate) or remove the extension. Video itself comes from
// the `canon-webcam` command-line tool.

let extensionIdentifier = "io.github.estevaofay.CanonWebcam.CameraExtension"

@main
struct CanonWebcamApp: App {
    var body: some Scene {
        WindowGroup("Canon Webcam") { ContentView() }
            .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @StateObject private var manager = ExtensionManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Canon Webcam").font(.title2.bold())
            Text("Adds a \"Canon Webcam\" camera to Zoom, Meet, FaceTime and other apps. "
                + "Start the video with `canon-webcam --camera \"Canon Webcam\"` in Terminal.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Install camera") { manager.submit(activate: true) }
                    .keyboardShortcut(.defaultAction)
                Button("Remove camera") { manager.submit(activate: false) }
            }
            Text(manager.status).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 420)
    }
}

final class ExtensionManager: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var status = "Not changed yet."

    func submit(activate: Bool) {
        let request = activate
            ? OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
            : OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        status = activate ? "Installing…" : "Removing…"
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status = "Approve it in System Settings > General > Login Items & Extensions > Camera Extensions."
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        status = result == .completed ? "Done." : "Done, takes effect after a restart."
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        status = "Failed: \(error.localizedDescription)\n"
            + "Camera extensions only install when this app is in /Applications and signed with an "
            + "Apple Developer team (see README)."
    }
}
