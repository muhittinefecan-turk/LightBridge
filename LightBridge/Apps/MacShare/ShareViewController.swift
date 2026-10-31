import Cocoa
import UniformTypeIdentifiers

/// Finder'da sağ tık → Paylaş → LightBridge. Dosyayı App Group gelen kutusuna kopyalar, ana uygulamayı açar.
final class ShareViewController: NSViewController {
    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1)) }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let items = extensionContext?.inputItems as? [NSExtensionItem],
              let provider = items.flatMap({ $0.attachments ?? [] })
                .first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            extensionContext?.cancelRequest(withError: NSError(domain: "LightBridge", code: 1)); return
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { [weak self] item, _ in
            var url: URL?
            if let u = item as? URL { url = u }
            else if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
            guard let src = url, let inbox = SharedInbox.folder else { self?.finish(); return }
            try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let dst = inbox.appendingPathComponent(src.lastPathComponent)
            try? FileManager.default.removeItem(at: dst)
            _ = src.startAccessingSecurityScopedResource()
            try? FileManager.default.copyItem(at: src, to: dst)
            src.stopAccessingSecurityScopedResource()
            DispatchQueue.main.async {
                if let appURL = URL(string: "lightbridge://send") { NSWorkspace.shared.open(appURL) }
                self?.finish()
            }
        }
    }

    private func finish() { extensionContext?.completeRequest(returningItems: nil) }
}
