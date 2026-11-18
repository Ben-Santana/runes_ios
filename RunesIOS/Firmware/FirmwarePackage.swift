import Foundation
import CryptoKit
import Compression

/// Reads files out of a zip held in memory. It handles what a firmware package uses, files
/// stored as they are or deflated, and refuses the rest.
enum Zip {
    /// No file in a package comes near this size.
    static let limit = 64 << 20

    private static func le16(_ data: Data, _ offset: Int) -> Int { Int(data.octet(offset)) | Int(data.octet(offset + 1)) << 8 }
    private static func le32(_ data: Data, _ offset: Int) -> Int { le16(data, offset) | le16(data, offset + 2) << 16 }
    private static func bad(_ what: String) -> BandError { .storage("The package could not be read: \(what).") }

    static func file(_ name: String, in zip: Data) throws -> Data {
        // The list of files sits at the end, behind a comment of at most 65535 bytes.
        guard zip.count >= 22 else { throw bad("too short") }
        var end = zip.count - 22
        let lowest = max(0, zip.count - 22 - 65535)
        while end >= lowest, le32(zip, end) != 0x06054b50 { end -= 1 }
        guard end >= lowest, end + 22 + le16(zip, end + 20) == zip.count else { throw bad("no file list at its end") }
        let count = le16(zip, end + 10)
        var offset = le32(zip, end + 16)
        guard count != 0xffff, offset != 0xffffffff else { throw bad("it uses large file fields") }
        for _ in 0..<count {
            guard offset + 46 <= zip.count, le32(zip, offset) == 0x02014b50 else { throw bad("a damaged file list") }
            let flags = le16(zip, offset + 8), method = le16(zip, offset + 10)
            let packed = le32(zip, offset + 20), size = le32(zip, offset + 24)
            let nameLength = le16(zip, offset + 28), extra = le16(zip, offset + 30), comment = le16(zip, offset + 32)
            let local = le32(zip, offset + 42)
            guard offset + 46 + nameLength <= zip.count else { throw bad("a damaged file list") }
            let entry = String(decoding: zip.portion((offset + 46)..<(offset + 46 + nameLength)), as: UTF8.self)
            offset += 46 + nameLength + extra + comment
            guard entry == name else { continue }
            guard flags & 1 == 0 else { throw bad("\(name) is encrypted") }
            guard packed != 0xffffffff, size != 0xffffffff, size <= limit else { throw bad("\(name) is too large") }
            guard local + 30 <= zip.count, le32(zip, local) == 0x04034b50 else { throw bad("\(name) is not where the list says") }
            let start = local + 30 + le16(zip, local + 26) + le16(zip, local + 28)
            guard start + packed <= zip.count else { throw bad("\(name) is cut short") }
            let raw = zip.portion(start..<(start + packed))
            switch method {
            case 0:
                guard packed == size else { throw bad("\(name) has two sizes") }
                return raw
            case 8:
                guard size > 0 else { return Data() }
                var out = Data(count: size)
                let written = out.withUnsafeMutableBytes { target in
                    raw.withUnsafeBytes { source in
                        compression_decode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, size,
                                                  source.bindMemory(to: UInt8.self).baseAddress!, packed, nil, COMPRESSION_ZLIB)
                    }
                }
                guard written == size else { throw bad("\(name) does not unpack to its size") }
                return out
            default: throw bad("\(name) is packed in a way this app does not read")
            }
        }
        throw bad("it has no \(name)")
    }
}

/// A firmware package as Meta serves it: a zip with a list of its items, each with a size and
/// a SHA-256, and the number of the key the band needs to read them.
struct FirmwarePackage {
    let version: UInt64
    let keyNumber: UInt64
    /// The firmware first, then the model bundle if there is one.
    let items: [FirmwareUpdate.Item]

    var summary: String {
        "version \(version): " + items.map { "\($0.name) \($0.data.count) bytes" }.joined(separator: ", ") + ", needs key \(keyNumber)"
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func number(_ value: Any?) -> UInt64? {
        // A JSON true or false is a number too, and is told apart by its type.
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return UInt64(exactly: number) }
        return (value as? String).flatMap { UInt64($0) }
    }

    /// Unpacks a package and checks every item against the package's own list.
    static func read(_ zip: Data) throws -> FirmwarePackage {
        func bad(_ what: String) -> BandError { .storage("The package could not be used: \(what).") }
        guard let manifest = try JSONSerialization.jsonObject(with: Zip.file("manifest.json", in: zip)) as? [String: Any],
              let listed = manifest["items"] as? [[String: Any]], !listed.isEmpty else { throw bad("its list of items is missing") }
        guard let keyNumber = number(manifest["kek_version"]) else { throw bad("it does not say which key it needs") }
        var version: UInt64?, firmware: FirmwareUpdate.Item?, model: FirmwareUpdate.Item?
        for entry in listed {
            guard let path = entry["path"] as? String, !path.isEmpty, !path.hasPrefix("/"), !path.contains(".."), !path.contains("\\") else { throw bad("an item has an odd path") }
            let data = try Zip.file(path, in: zip)
            guard number(entry["size"]) == UInt64(data.count) else { throw bad("an item is not the size its list says") }
            guard let digest = entry["digest"] as? String, digest.lowercased() == sha256(data) else { throw bad("an item does not match its checksum") }
            guard let listedVersion = number(entry["version"]), version == nil || version == listedVersion else { throw bad("its items disagree about the version") }
            version = listedVersion
            let md5 = Data(Insecure.MD5.hash(data: data))
            switch number(entry["item_type"]) {
            case 1 where firmware == nil: firmware = FirmwareUpdate.Item(kind: 0, name: "firmware", data: data, md5: md5)
            case 2 where model == nil: model = FirmwareUpdate.Item(kind: 2, name: "model bundle", data: data, md5: md5)
            default: throw bad("it holds an item of a kind this app does not know, or two of one kind")
            }
        }
        guard let version, let firmware else { throw bad("it holds no firmware") }
        return FirmwarePackage(version: version, keyNumber: keyNumber, items: [firmware] + [model].compactMap { $0 })
    }

    /// The key in Meta's answer, still wrapped for the one band it was asked for. Nothing else
    /// from the answer is kept.
    static func wrappedKey(_ reply: Data) -> Data? {
        var text = String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("for (;;);") { text.removeFirst(9) }
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return nil }
        func find(_ value: Any, _ depth: Int) -> [String: Any]? {
            guard depth < 12 else { return nil }
            if let object = value as? [String: Any] {
                if object["encrypted_kek"] is String { return object }
                for key in object.keys.sorted() { if let found = find(object[key] as Any, depth + 1) { return found } }
            }
            if let list = value as? [Any] { for item in list { if let found = find(item, depth + 1) { return found } } }
            return nil
        }
        guard let info = find(json, 0), info["encryption_algo"] as? String == "AES_128",
              let key = (info["encrypted_kek"] as? String).flatMap({ Data(base64Encoded: $0) }), (16...1024).contains(key.count) else { return nil }
        return key
    }

    func plan(_ mode: FirmwareUpdate.Mode, wrappedKey: Data?) -> FirmwareUpdate.Plan {
        FirmwareUpdate.Plan(version: version, items: items, keyNumber: keyNumber, wrappedKey: wrappedKey, mode: mode, forcesRefusedModel: mode == .trial)
    }
}
