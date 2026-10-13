import AppKit

@MainActor public final class VerificationState {
    private let snapshot: URL
    private let domain: String
    public init(clipboard: Bool) {
        Self.requireDisposableEnvironment()
        domain = Bundle.main.bundleIdentifier ?? ""
        guard domain.hasPrefix("local.blank.acceptance.") || domain == "local.blank.resize-ui" else { fatalError("Verification must use an isolated app identity") }
        guard let path = ProcessInfo.processInfo.environment["BLANK_VERIFICATION_STATE"] else { fatalError("Missing verification state snapshot") }
        snapshot = URL(fileURLWithPath:path)
        if !FileManager.default.fileExists(atPath:path) {
            let preferences = UserDefaults.standard.persistentDomain(forName:domain)
            var record: [String:Any] = ["domain":domain,"preferences":preferences ?? [:],"hadPreferences":preferences != nil,"recents":NSDocumentController.shared.recentDocumentURLs.map(\.absoluteString)]
            if clipboard {
                record["clipboard"] = NSPasteboard.general.pasteboardItems?.map { item in
                    Dictionary(uniqueKeysWithValues:item.types.compactMap { type in item.data(forType:type).map { (type.rawValue,$0) } })
                } ?? []
            }
            try! PropertyListSerialization.data(fromPropertyList:record,format:.binary,options:0).write(to:snapshot,options:.atomic)
        }
    }
    public static func requireDisposableEnvironment() {
        for name in ["BLANK_DATA_DIR","BLANK_PACKAGE_CACHE","BLANK_VERIFICATION_STATE"] {
            guard let path = ProcessInfo.processInfo.environment[name], path.hasPrefix("/") else { fatalError("Missing isolated \(name)") }
            let resolved = URL(fileURLWithPath:path).resolvingSymlinksInPath().path
            let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
            guard resolved.hasPrefix("/private/tmp/blank-") || resolved.hasPrefix("/tmp/blank-") || resolved.hasPrefix(temporary+"/blank-") else { fatalError("Verification data must be disposable temporary data (\(name): \(resolved))") }
        }
    }
    public func restore(preferences: Bool = true) {
        let record = try! PropertyListSerialization.propertyList(from:Data(contentsOf:snapshot),options:[],format:nil) as! [String:Any]
        guard record["domain"] as? String == domain else { fatalError("Wrong verification identity") }
        if let items = record["clipboard"] as? [[String:Data]] {
            let restored = items.map { contents -> NSPasteboardItem in
                let item = NSPasteboardItem(); contents.forEach { item.setData($0.value,forType:NSPasteboard.PasteboardType($0.key)) }; return item
            }
            NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(restored)
        }
        NSDocumentController.shared.clearRecentDocuments(nil)
        (record["recents"] as? [String] ?? []).reversed().compactMap(URL.init(string:)).forEach { NSDocumentController.shared.noteNewRecentDocumentURL($0) }
        if preferences {
            if record["hadPreferences"] as? Bool == true { UserDefaults.standard.setPersistentDomain(record["preferences"] as? [String:Any] ?? [:],forName:domain) }
            else { UserDefaults.standard.removePersistentDomain(forName:domain) }
        }
    }
}
