import AppKit

@MainActor
final class ClipboardGuard {
    struct SavedItem {
        let data: [(NSPasteboard.PasteboardType, Data)]
    }
    struct Snapshot {
        let items: [SavedItem]
        let count: Int
    }
    struct Ownership {
        let count: Int
        let token: String
    }
    private let pasteboard: NSPasteboard
    private let maximumBytes: Int
    private let ownershipType = NSPasteboard.PasteboardType("com.itsadamdag.TypoBouncer.temporary")

    init(pasteboard: NSPasteboard = .general, maximumBytes: Int = 256 * 1_024 * 1_024) {
        self.pasteboard = pasteboard
        self.maximumBytes = maximumBytes
    }

    func snapshot() throws -> Snapshot {
        let count = pasteboard.changeCount
        var total = 0
        let items = try (pasteboard.pasteboardItems ?? []).map { item in
            let saved = try item.types.map { type -> (NSPasteboard.PasteboardType, Data) in
                guard let data = item.data(forType: type) else { throw AppFailure.clipboardUnavailable }
                guard data.count <= maximumBytes - total else { throw AppFailure.clipboardTooLarge }
                total += data.count
                return (type, data)
            }
            return SavedItem(data: saved)
        }
        guard pasteboard.changeCount == count else { throw AppFailure.clipboardChanged }
        return Snapshot(items: items, count: count)
    }

    func writeTemporary(_ text: String, rtf: Data? = nil, after snapshot: Snapshot) throws -> Ownership {
        guard pasteboard.changeCount == snapshot.count else { throw AppFailure.clipboardChanged }
        let token = UUID().uuidString
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if let rtf { item.setData(rtf, forType: .rtf) }
        item.setString(token, forType: ownershipType)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            // Nothing was committed by us; only restore if the clipboard is still empty.
            if pasteboard.pasteboardItems?.isEmpty != false { restore(snapshot) }
            throw AppFailure.clipboardUnavailable
        }
        let ownership = Ownership(count: pasteboard.changeCount, token: token)
        guard owns(ownership) else { throw AppFailure.clipboardChanged }
        return ownership
    }

    func owns(_ ownership: Ownership) -> Bool {
        pasteboard.changeCount == ownership.count && pasteboard.string(forType: ownershipType) == ownership.token
    }

    func restore(_ snapshot: Snapshot, ifOwned ownership: Ownership) {
        guard owns(ownership) else { return }
        restore(snapshot)
    }

    private func restore(_ snapshot: Snapshot) {
        let items = snapshot.items.map { saved in
            let item = NSPasteboardItem()
            for (type, data) in saved.data { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
