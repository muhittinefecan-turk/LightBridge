import SwiftUI

@main
struct LightBridgeMacApp: App {
    @StateObject private var model = SenderModel()

    var body: some Scene {
        WindowGroup {
            SenderView()
                .environmentObject(model)
                .frame(minWidth: 640, minHeight: 760)
                // Finder → Paylaş → LightBridge   ya da   lightbridge://send
                .onOpenURL { _ in model.loadFromInbox() }
                .onAppear { model.loadFromInbox() }
        }
        .handlesExternalEvents(matching: ["*"])
    }
}
