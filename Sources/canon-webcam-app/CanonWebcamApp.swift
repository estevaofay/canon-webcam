import AppKit
import SwiftUI
import WebcamFeed

/// canon-webcam's menu bar app: streams a Canon EOS DSLR into a virtual
/// camera and shows what is happening. No Dock icon, no windows.
@main
struct CanonWebcamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: appDelegate.model)
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if case .live = model.status { MenuBarIcon(live: true) } else { MenuBarIcon(live: false) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A plain executable (not yet bundled) would otherwise get a Dock icon.
        NSApp.setActivationPolicy(.accessory)
        model.launch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}
