import CoreMediaIO
import Foundation

// Entry point of the "Canon Webcam" Camera Extension. macOS launches this
// process on demand; it publishes one virtual camera and runs forever.
let providerSource = ProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
