import Foundation

enum SafariRulesFile {
    static let groupID = "group.com.muddassir.clearview"
    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?.appendingPathComponent("safari-rules.json")
    }
}
