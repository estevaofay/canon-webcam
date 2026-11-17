import CanonUSB
import SwiftUI
import WebcamFeed

/// The panel under the menu bar icon (Paper: "1 · Streaming", "2 · Waiting
/// for camera").
struct PanelView: View {
    @ObservedObject var model: AppModel

    private static let tally = Color(red: 0xE5 / 255, green: 0x32 / 255, blue: 0x2D / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            previewArea
            if isLive { figures }
            Divider().padding(.horizontal, 4).padding(.top, isLive ? 0 : 10)
            cameraScreenRow.padding(.vertical, 6)
            Divider().padding(.horizontal, 4)
            VStack(spacing: 0) {
                MenuRow(title: "Open at login", trailing: model.openAtLogin ? .checkmark : .none) {
                    model.setOpenAtLogin(!model.openAtLogin)
                }
                MenuRow(title: "Quit canon-webcam", trailing: .shortcut("⌘Q")) {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(.vertical, 6)
        }
        .padding(6)
        .frame(width: 330)
        .onAppear { model.panelAppeared() }
        .onDisappear { model.panelDisappeared() }
    }

    private var isLive: Bool {
        if case .live = model.status { return true }
        return false
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(isLive ? Self.tally : Color.secondary.opacity(0.6))
                        .frame(width: 7, height: 7)
                        .shadow(color: isLive ? Self.tally.opacity(0.35) : .clear, radius: 2)
                    Text(statusLine)
                        .font(.system(size: 12, weight: isLive ? .medium : .regular))
                        .foregroundStyle(isLive ? .primary : .secondary)
                }
            }
            Spacer(minLength: 0)
            Toggle("Stream", isOn: $model.isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var title: String {
        switch model.status {
        case let .live(name): return name
        case .stopped, .problem: return model.lastModel ?? "canon-webcam"
        case .waitingForCamera: return "No camera connected"
        }
    }

    private var statusLine: String {
        switch model.status {
        case .live: return "Live"
        case .stopped: return "Off"
        case .waitingForCamera: return "Waiting for a Canon on USB"
        case .problem: return "Not streaming"
        }
    }

    // MARK: Preview

    @ViewBuilder private var previewArea: some View {
        if isLive, let image = model.preview {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(16 / 9, contentMode: .fill)
                .frame(width: 318, height: 179)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(alignment: .topLeading) {
                    Text("What apps see")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                }
        } else if isLive {
            card { ProgressView().controlSize(.small) }
        } else {
            card { message }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10) { content() }
            .padding(.horizontal, 28)
            .frame(width: 318, height: 179)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    @ViewBuilder private var message: some View {
        switch model.status {
        case .problem(.virtualCameraMissing):
            cardText(symbol: "video.slash", title: "No virtual camera",
                     detail: "Install OBS and allow its camera extension once.")
            Button("Get OBS") { NSWorkspace.shared.open(URL(string: "https://obsproject.com/download")!) }
                .controlSize(.small)
        case .problem(.cameraAccessDenied):
            cardText(symbol: "lock", title: "Camera access needed",
                     detail: "canon-webcam needs camera access to feed the virtual camera.")
            Button("Open Privacy Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
            }
            .controlSize(.small)
        case .problem(.cameraInUse):
            cardText(symbol: "camera", title: "Camera busy",
                     detail: "Another app is using the camera (Photos, Image Capture, EOS Utility…).")
        case .stopped:
            cardText(symbol: "camera", title: "Streaming is off", detail: "Switch it on to send your camera to video apps.")
        default:
            cardText(symbol: "camera", title: "Connect your camera",
                     detail: "Plug it in over USB and switch it on, with the mode dial on P or M.")
        }
    }

    private func cardText(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Figures

    private var figures: some View {
        HStack(alignment: .bottom, spacing: 22) {
            figure(value: "\(Int(model.sentFPS.rounded()))", unit: " fps", caption: "to video apps")
            figure(value: "1080p", unit: "", caption: "1920×1080 · 16:9")
            Spacer(minLength: 0)
            if let battery = model.battery {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: batterySymbol(battery))
                            .foregroundStyle(battery == .low ? Color.red : Color.primary)
                        Text(battery.text).font(.system(size: 13, weight: .semibold))
                    }
                    .frame(height: 30)
                    Text("camera battery").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private func figure(value: String, unit: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            (Text(value).font(.system(size: 26, weight: .bold)).tracking(-0.6)
                + Text(unit).font(.system(size: 13, weight: .medium)).foregroundColor(.secondary))
                .frame(height: 30, alignment: .bottom)
            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func batterySymbol(_ level: BatteryLevel) -> String {
        switch level {
        case .low: return "battery.0"
        case .quarter: return "battery.25"
        case .half: return "battery.50"
        case .threeQuarters: return "battery.75"
        case .full: return "battery.100"
        }
    }

    // MARK: Rows

    private var cameraScreenRow: some View {
        HStack {
            Text("Show on the camera's screen too").font(.system(size: 13))
            Spacer()
            Toggle("Show on the camera's screen too", isOn: $model.showOnCameraScreen)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }
}

/// A plain menu-style row: highlights on hover like a menu item.
struct MenuRow: View {
    enum Trailing { case none, checkmark, shortcut(String) }

    let title: String
    var trailing: Trailing = .none
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                switch trailing {
                case .none: EmptyView()
                case .checkmark: Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                case let .shortcut(keys): Text(keys).font(.system(size: 13)).foregroundStyle(hovering ? .primary : .secondary)
                }
            }
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background(hovering ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
