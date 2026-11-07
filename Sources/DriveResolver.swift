import Foundation
import SQLite3

/// Resolves Google Drive file/folder IDs to local paths inside Google Drive for Desktop's
/// File Provider mounts (~/Library/CloudStorage/GoogleDrive-<email>/…), using the
/// DriveFS metadata database that Drive for Desktop keeps on disk.
enum DriveResolver {
    enum Failure: LocalizedError {
        case noID
        case noDriveFS
        case notFound(String)
        case notOnDisk(String, [String])

        var errorDescription: String? {
            switch self {
            case .noID:
                return "That doesn't look like a Google Drive link."
            case .noDriveFS:
                return "Google Drive for Desktop data wasn't found on this Mac."
            case .notFound(let id):
                return "No synced item with ID \(id) in any signed-in Drive account."
            case .notOnDisk(let title, _):
                return "Found “\(title)”, but it isn't reachable in Finder (shared with you without a shortcut, or not synced yet)."
            }
        }
    }

    struct Result {
        let url: URL
        let account: String
    }

    static let driveFSDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Google/DriveFS")
    static let cloudStorageDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/CloudStorage")

    // MARK: - Link parsing

    /// Pulls the Drive item ID out of the common link shapes, or accepts a bare ID.
    static func extractID(from raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let idChars = "[A-Za-z0-9_-]{10,}"
        let patterns = [
            "/(?:file|document|spreadsheets|presentation|forms|drawings)/(?:u/\\d+/)?d/(?:e/)?(\(idChars))",
            "/folders/(\(idChars))",
            "[?&]id=(\(idChars))",
        ]
        for p in patterns {
            if let r = s.range(of: p, options: .regularExpression) {
                let match = String(s[r])
                if let idr = match.range(of: idChars + "$", options: .regularExpression) {
                    return String(match[idr])
                }
            }
        }
        // Bare ID pasted on its own.
        if s.range(of: "^\(idChars)$", options: .regularExpression) != nil, !s.contains(".") {
            return s
        }
        return nil
    }

    static func looksLikeDriveLink(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t.contains("drive.google.com") || t.contains("docs.google.com")) && extractID(from: t) != nil
    }

    // MARK: - Resolution

    static func resolve(_ input: String) throws -> Result {
        guard let id = extractID(from: input) else { throw Failure.noID }
        let accounts = accountDirectories()
        guard !accounts.isEmpty else { throw Failure.noDriveFS }

        let mounts = mountsByAccount()
        var foundTitle: String?
        var triedPaths: [String] = []

        for account in accounts {
            let dbURL = account.appendingPathComponent("metadata_sqlite_db")
            guard let db = Database(url: dbURL) else { continue }
            guard let item = db.item(id: id) else { continue }
            foundTitle = item.title

            let accountID = account.lastPathComponent
            guard let mount = mounts[accountID] else { continue }

            for components in db.paths(for: item.stableID) {
                let url = components.reduce(mount) { $0.appendingPathComponent($1) }
                triedPaths.append(url.path)
                if FileManager.default.fileExists(atPath: url.path) {
                    return Result(url: url, account: mount.lastPathComponent.replacingOccurrences(of: "GoogleDrive-", with: ""))
                }
            }
        }

        if let title = foundTitle { throw Failure.notOnDisk(title, triedPaths) }
        throw Failure.notFound(id)
    }

    /// Numeric folders under DriveFS are per-account data directories.
    static func accountDirectories() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: driveFSDir, includingPropertiesForKeys: nil)) ?? []
        return items.filter {
            $0.lastPathComponent.allSatisfy(\.isNumber)
                && FileManager.default.fileExists(atPath: $0.appendingPathComponent("metadata_sqlite_db").path)
        }
    }

    /// Maps DriveFS account IDs to their CloudStorage mount via the File Provider domain xattr
    /// (value looks like "com.google.drivefs.fpext/gdrive-<accountID>").
    static func mountsByAccount() -> [String: URL] {
        var result: [String: URL] = [:]
        let items = (try? FileManager.default.contentsOfDirectory(at: cloudStorageDir, includingPropertiesForKeys: nil)) ?? []
        for url in items where url.lastPathComponent.hasPrefix("GoogleDrive-") {
            guard let value = xattr(url.path, "com.apple.file-provider-domain-id"),
                  let r = value.range(of: "gdrive-") else { continue }
            let accountID = String(value[r.upperBound...]).trimmingCharacters(in: .controlCharacters)
            // Prefer the live mount over stale "(date)" copies left behind by migrations.
            if result[accountID] == nil || !url.lastPathComponent.contains("(") {
                result[accountID] = url
            }
        }
        return result
    }

    static func xattr(_ path: String, _ name: String) -> String? {
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard getxattr(path, name, &buf, size, 0, 0) == size else { return nil }
        return String(decoding: buf, as: UTF8.self)
    }
}

// MARK: - DriveFS metadata database

private final class Database {
    struct Item {
        let stableID: Int64
        let id: String
        let title: String
        let teamDriveStableID: Int64?
    }

    private var db: OpaquePointer?
    private let myDriveRootID: String?

    init?(url: URL) {
        var handle: OpaquePointer?
        let uri = "file:\(url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path)?mode=ro"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        db = handle
        sqlite3_busy_timeout(handle, 2000)
        myDriveRootID = Database.queryString(handle, "SELECT CAST(value AS TEXT) FROM properties WHERE property='root_id'")
    }

    deinit { sqlite3_close(db) }

    func item(id: String) -> Item? {
        rows("SELECT stable_id, id, local_title, team_drive_stable_id FROM items WHERE id=? AND trashed=0 AND is_tombstone=0", .text(id)).first
    }

    func item(stableID: Int64) -> Item? {
        rows("SELECT stable_id, id, local_title, team_drive_stable_id FROM items WHERE stable_id=?", .int(stableID)).first
    }

    /// All plausible relative paths (from the mount root) for an item, best guesses first.
    /// Follows real parents first, then Drive shortcuts pointing at the item or its ancestors.
    func paths(for stableID: Int64) -> [[String]] {
        var visited = Set<Int64>()
        return paths(stableID, &visited, depth: 0)
    }

    private func paths(_ stableID: Int64, _ visited: inout Set<Int64>, depth: Int) -> [[String]] {
        guard depth < 64, !visited.contains(stableID), let item = item(stableID: stableID) else { return [] }
        visited.insert(stableID)
        defer { visited.remove(stableID) }

        if item.id == myDriveRootID { return [["My Drive"]] }
        if item.teamDriveStableID == item.stableID { return [["Shared drives", item.title]] }

        var results: [[String]] = []
        for parent in ints("SELECT parent_stable_id FROM stable_parents WHERE item_stable_id=?", stableID) {
            for p in paths(parent, &visited, depth: depth + 1) { results.append(p + [item.title]) }
        }
        // Shortcuts: the item appears in Finder under the shortcut's name and location.
        for shortcut in ints("SELECT shortcut_stable_id FROM shortcut_details WHERE target_stable_id=?", stableID) {
            guard let s = self.item(stableID: shortcut) else { continue }
            for parent in ints("SELECT parent_stable_id FROM stable_parents WHERE item_stable_id=?", shortcut) {
                for p in paths(parent, &visited, depth: depth + 1) { results.append(p + [s.title]) }
            }
        }
        return results
    }

    // MARK: SQLite helpers

    private enum Bind { case text(String), int(Int64) }

    private func prepare(_ sql: String, _ bind: Bind) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        switch bind {
        case .text(let s): sqlite3_bind_text(stmt, 1, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        case .int(let i): sqlite3_bind_int64(stmt, 1, i)
        }
        return stmt
    }

    private func rows(_ sql: String, _ bind: Bind) -> [Item] {
        guard let stmt = prepare(sql, bind) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [Item] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let td: Int64? = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 3)
            out.append(Item(
                stableID: sqlite3_column_int64(stmt, 0),
                id: String(cString: sqlite3_column_text(stmt, 1)),
                title: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "",
                teamDriveStableID: td))
        }
        return out
    }

    private func ints(_ sql: String, _ value: Int64) -> [Int64] {
        guard let stmt = prepare(sql, .int(value)) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(sqlite3_column_int64(stmt, 0)) }
        return out
    }

    private static func queryString(_ db: OpaquePointer?, _ sql: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }
}
