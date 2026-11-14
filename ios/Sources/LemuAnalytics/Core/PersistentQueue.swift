import Foundation

/// One queued message plus the bookkeeping the SDK needs to send it.
struct QueuedMessage: Codable, Equatable {
    /// The message's `messageId`.
    let id: String
    /// When the brand's code made the call.
    let queuedAt: Date
    /// `Purchase` messages are the last to be dropped when the queue is full.
    let isPurchase: Bool
    /// First time a request carrying this message was sent. Retries stop 20 hours after it.
    var firstAttemptAt: Date?
    /// The message exactly as it goes on the wire.
    let message: JSONValue
}

/// The message queue, kept on disk as one JSON object per line so adding a
/// message appends instead of rewriting the file.
///
/// Not thread safe: the client only touches it from its serial queue.
final class PersistentQueue {
    private(set) var items: [QueuedMessage] = []
    let fileURL: URL
    private let logger: LemuLogger

    init(fileURL: URL, logger: LemuLogger) {
        self.fileURL = fileURL
        self.logger = logger
    }

    var count: Int { return items.count }

    /// Reads the file. Lines that can't be decoded (for example a write cut
    /// short by a crash) are skipped and the file is rewritten without them.
    func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            items = []
            return
        }
        var loaded: [QueuedMessage] = []
        var skipped = 0
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            if let item = JSON.decode(QueuedMessage.self, from: Data(line)) {
                loaded.append(item)
            } else {
                skipped += 1
            }
        }
        items = loaded
        if skipped > 0 {
            logger.debug("skipped \(skipped) unreadable queued message(s)")
            rewrite()
        }
    }

    func append(_ item: QueuedMessage) {
        items.append(item)
        guard var line = JSON.encode(item) else { return }
        line.append(UInt8(ascii: "\n"))
        guard ensureDirectory() else { return }
        // OutputStream reports errors through its return value instead of
        // raising an Objective-C exception the way FileHandle.write does.
        guard let stream = OutputStream(url: fileURL, append: true) else { return }
        stream.open()
        defer { stream.close() }
        let written = line.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return stream.write(base, maxLength: buffer.count)
        }
        if written != line.count {
            logger.debug("could not append to the queue file; rewriting it")
            rewrite()
        }
    }

    func remove(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let before = items.count
        items.removeAll { ids.contains($0.id) }
        if items.count != before { rewrite() }
    }

    func removeAll() {
        items.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Drops messages queued before `cutoff`. Returns how many.
    @discardableResult
    func removeOlderThan(_ cutoff: Date) -> Int {
        let before = items.count
        items.removeAll { $0.queuedAt < cutoff }
        let removed = before - items.count
        if removed > 0 { rewrite() }
        return removed
    }

    /// Keeps at most `maxSize` messages, dropping the oldest non-Purchase
    /// message first (the oldest message if every one is a Purchase).
    @discardableResult
    func enforceLimit(_ maxSize: Int) -> Int {
        let limit = max(1, maxSize)
        guard items.count > limit else { return 0 }
        var dropped = 0
        while items.count > limit {
            if let index = items.firstIndex(where: { !$0.isPurchase }) {
                items.remove(at: index)
            } else {
                items.removeFirst()
            }
            dropped += 1
        }
        rewrite()
        return dropped
    }

    func setFirstAttempt(_ date: Date, ids: Set<String>) {
        for index in items.indices where ids.contains(items[index].id) && items[index].firstAttemptAt == nil {
            items[index].firstAttemptAt = date
        }
    }

    /// Writes the whole queue (atomically).
    func rewrite() {
        if items.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard ensureDirectory() else { return }
        var data = Data()
        for item in items {
            if let line = JSON.encode(item) {
                data.append(line)
                data.append(UInt8(ascii: "\n"))
            }
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.debug("could not write the queue file: \(error.localizedDescription)")
        }
    }

    private func ensureDirectory() -> Bool {
        let directory = fileURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) { return true }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = directory
            try? mutable.setResourceValues(values)
            return true
        } catch {
            logger.debug("could not create \(directory.path): \(error.localizedDescription)")
            return false
        }
    }

    /// `Application Support/Lemu`, excluded from iCloud and iTunes backup.
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Lemu", isDirectory: true)
    }

    static func fileName(writeKey: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let safe = String(writeKey.unicodeScalars.filter { allowed.contains($0) }.prefix(64).map(Character.init))
        return "queue-\(safe.isEmpty ? "default" : safe).jsonl"
    }
}
