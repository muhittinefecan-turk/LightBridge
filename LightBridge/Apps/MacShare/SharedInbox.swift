import Foundation

/// Paylaş eklentisi ile ana uygulama arasındaki "gelen kutusu" (App Group klasörü).
enum SharedInbox {
    static let groupID = "group.com.lightbridge.app"   // Xcode'da Signing & Capabilities → App Groups
    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("Inbox", isDirectory: true)
    }
}
