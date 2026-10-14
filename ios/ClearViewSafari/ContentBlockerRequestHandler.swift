import Foundation

final class ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let shared = SafariRulesFile.url
        let source = shared.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? Bundle.main.url(forResource: "rules", withExtension: "json")
        guard let source, let provider = NSItemProvider(contentsOf: source) else {
            context.cancelRequest(withError: NSError(domain: "ClearViewSafari", code: 1, userInfo: [NSLocalizedDescriptionKey: "Safari rules are unavailable. Open ClearView to refresh website protection."]))
            return
        }
        let item = NSExtensionItem()
        item.attachments = [provider]
        context.completeRequest(returningItems: [item])
    }
}
