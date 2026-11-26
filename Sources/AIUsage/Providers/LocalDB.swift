import Foundation
import SQLite3

/// Reads one value from the key/value table (`ItemTable`) that VS Code–based apps
/// (Cursor, Antigravity) keep in `state.vscdb`. Opened read-only; never written.
enum LocalDB {
    static func value(_ key: String, in path: String) -> Data? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        let uri = "file:\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, 0))
        guard n > 0, let p = sqlite3_column_blob(stmt, 0) else { return nil }
        return Data(bytes: p, count: n)
    }

    static func string(_ key: String, in path: String) -> String? {
        value(key, in: path).map { String(decoding: $0, as: UTF8.self) }
    }

    static func appSupport(_ app: String) -> String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(app).appendingPathComponent("User/globalStorage/state.vscdb").path
    }
}

/// Just enough protobuf wire-format reading to walk Antigravity's cached status.
struct ProtoReader {
    enum Value { case varint(UInt64), fixed64(UInt64), bytes(Data), fixed32(UInt32) }

    static func fields(_ d: Data) -> [(Int, Value)]? {
        let b = [UInt8](d)
        var i = 0, out: [(Int, Value)] = []
        func varint() -> UInt64? {
            var r: UInt64 = 0, s: UInt64 = 0
            while i < b.count, s < 64 {
                let c = b[i]; i += 1
                r |= UInt64(c & 0x7f) << s
                if c < 0x80 { return r }
                s += 7
            }
            return nil
        }
        while i < b.count {
            guard let key = varint() else { return nil }
            let field = Int(key >> 3)
            guard field > 0 else { return nil }
            switch key & 7 {
            case 0: guard let v = varint() else { return nil }; out.append((field, .varint(v)))
            case 1:
                guard i + 8 <= b.count else { return nil }
                out.append((field, .fixed64(b[i..<i+8].enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) })))
                i += 8
            case 2:
                guard let n = varint(), i + Int(n) <= b.count else { return nil }
                out.append((field, .bytes(Data(b[i..<i+Int(n)]))))
                i += Int(n)
            case 5:
                guard i + 4 <= b.count else { return nil }
                out.append((field, .fixed32(b[i..<i+4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) })))
                i += 4
            default: return nil
            }
        }
        return out
    }

    static func bytes(_ f: [(Int, Value)], _ n: Int) -> [Data] {
        f.compactMap { if $0.0 == n, case .bytes(let d) = $0.1 { return d } else { return nil } }
    }
}
