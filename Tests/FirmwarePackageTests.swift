// Offline checks of how a firmware package and its key are read. No network.
// swiftc -module-cache-path /private/tmp/runes-swift-module-cache RunesIOS/Session/Models.swift RunesIOS/Protocol/Wire.swift RunesIOS/Persistence/IdentityStore.swift RunesIOS/Firmware/FirmwareOffer.swift RunesIOS/Firmware/FirmwareUpdate.swift RunesIOS/Firmware/FirmwarePackage.swift Tests/FirmwarePackageTests.swift -o /private/tmp/runes-firmware-package-tests && /private/tmp/runes-firmware-package-tests
// The package layout is the one the public band-core project's Android app unpacks.
import Foundation
import CryptoKit
import Compression

/// Writes a zip the plain way, so the reader is checked against something it did not write.
struct ZipWriter {
    private var body = Data(), list = Data(), count = 0
    private func le(_ value: Int, _ bytes: Int) -> Data { Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }) }

    mutating func add(_ name: String, _ data: Data, deflated: Bool, flags: Int = 0, method: Int? = nil, extra: Data = Data()) {
        var packed = data
        if deflated {
            var out = Data(count: data.count + 1024)
            let written = out.withUnsafeMutableBytes { target in
                data.withUnsafeBytes { compression_encode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, target.count, $0.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB) }
            }
            precondition(written > 0)
            packed = out.prefix(written)
        }
        let kind = method ?? (deflated ? 8 : 0), offset = body.count
        var sizes = le(0, 4); sizes += le(packed.count, 4); sizes += le(data.count, 4); sizes += le(name.utf8.count, 2)
        var head = le(20, 2); head += le(flags, 2); head += le(kind, 2); head += le(0, 4); head += sizes
        body += le(0x04034b50, 4); body += head; body += le(extra.count, 2); body += Data(name.utf8); body += extra; body += packed
        list += le(0x02014b50, 4); list += le(20, 2); list += head
        // No extra field, no comment, disk 0, no attributes, then where the file starts.
        list += le(0, 2); list += le(0, 2); list += le(0, 2); list += le(0, 2); list += le(0, 4); list += le(offset, 4); list += Data(name.utf8)
        count += 1
    }

    func finished(comment: String = "") -> Data {
        var out = body + list
        out += le(0x06054b50, 4); out += le(0, 4); out += le(count, 2); out += le(count, 2)
        out += le(list.count, 4); out += le(body.count, 4); out += le(comment.utf8.count, 2); out += Data(comment.utf8)
        return out
    }
}

@main
struct FirmwarePackageTests {
    static let firmware = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 / 7) })
    static let model = Data((0..<15_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    static func manifest(_ change: (inout [String: Any]) -> Void = { _ in }) -> Data {
        func item(_ path: String, _ data: Data, _ kind: Int) -> [String: Any] {
            ["path": path, "size": data.count, "digest": FirmwarePackage.sha256(data), "version": 1003366292, "item_type": kind]
        }
        var json: [String: Any] = ["kek_version": 20, "items": [item("images/firmware.bin", firmware, 1), item("models/bundle.bin", model, 2)]]
        change(&json)
        return try! JSONSerialization.data(withJSONObject: json)
    }

    static func package(_ manifest: Data = manifest(), firmware: Data = firmware, deflated: Bool = true) -> Data {
        var zip = ZipWriter()
        zip.add("images/firmware.bin", firmware, deflated: deflated, extra: Data([1, 2, 3, 4]))
        zip.add("manifest.json", manifest, deflated: false)
        zip.add("models/bundle.bin", model, deflated: deflated)
        return zip.finished(comment: "made for a check")
    }

    static func refused(_ zip: Data) -> Bool { (try? FirmwarePackage.read(zip)) == nil }

    static func main() throws {
        // A whole package, packed both ways: the firmware first, each item with its own checksum.
        for deflated in [true, false] {
            let read = try FirmwarePackage.read(package(deflated: deflated))
            precondition(read.version == 1003366292 && read.keyNumber == 20 && read.items.map(\.kind) == [0, 2])
            precondition(read.items[0].data == firmware && read.items[1].data == model)
            precondition(read.items[0].md5 == Data(Insecure.MD5.hash(data: firmware)) && read.items[0].md5.count == 16)
            precondition(read.summary == "version 1003366292: firmware 70000 bytes, model bundle 15000 bytes, needs key 20")
            let plan = read.plan(.trial, wrappedKey: Data([1]))
            precondition(plan.version == read.version && plan.keyNumber == 20 && plan.items.count == 2 && plan.mode == .trial)
        }
        // The known MD5 of a known text, since the band checks each item by it.
        precondition(Data(Insecure.MD5.hash(data: Data("abc".utf8))).map { String(format: "%02x", $0) }.joined() == "900150983cd24fb0d6963f7d28e17f72")
        precondition(FirmwarePackage.sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        // One changed byte in an item, a wrong size, and a list that disagrees with itself.
        var changed = firmware; changed[40_000] ^= 1
        precondition(refused(package(firmware: changed)))
        precondition(refused(package(firmware: firmware + Data([0]))))
        precondition(refused(package(manifest { var items = $0["items"] as! [[String: Any]]; items[1]["version"] = 5; $0["items"] = items })))
        precondition(refused(package(manifest { var items = $0["items"] as! [[String: Any]]; items[1]["item_type"] = 1; $0["items"] = items })))
        precondition(refused(package(manifest { var items = $0["items"] as! [[String: Any]]; items[0]["item_type"] = 3; $0["items"] = items })))
        precondition(refused(package(manifest { var items = $0["items"] as! [[String: Any]]; items.removeFirst(); $0["items"] = items })), "a package with no firmware")
        precondition(refused(package(manifest { $0["kek_version"] = nil })))
        precondition(refused(package(manifest { $0["items"] = [[String: Any]]() })))
        // Paths that point outside the package, and an item the zip lacks.
        for path in ["../firmware.bin", "/images/firmware.bin", "images\\firmware.bin", "images/missing.bin", ""] {
            precondition(refused(package(manifest { var items = $0["items"] as! [[String: Any]]; items[0]["path"] = path; $0["items"] = items })), path)
        }
        // A model bundle is optional.
        do {
            var zip = ZipWriter()
            zip.add("manifest.json", manifest { var items = $0["items"] as! [[String: Any]]; items.removeLast(); $0["items"] = items }, deflated: true)
            zip.add("images/firmware.bin", firmware, deflated: true)
            let alone = try FirmwarePackage.read(zip.finished())
            precondition(alone.items.map(\.name) == ["firmware"])
        }

        // Zips this reader refuses: encrypted, packed another way, cut short, or not a zip.
        do {
            var encrypted = ZipWriter(); encrypted.add("manifest.json", manifest(), deflated: false, flags: 1)
            precondition((try? Zip.file("manifest.json", in: encrypted.finished())) == nil)
            var odd = ZipWriter(); odd.add("manifest.json", manifest(), deflated: false, method: 12)
            precondition((try? Zip.file("manifest.json", in: odd.finished())) == nil)
            let list = manifest(), whole = package(list)
            for cut in [0, 10, 21, 1000, whole.count / 2, whole.count - 1] { precondition(refused(whole.prefix(cut)), "\(cut)") }
            precondition(refused(Data(repeating: 0x50, count: 5000)))
            var torn = whole; torn.replaceSubrange(200..<400, with: Data(repeating: 0, count: 200))
            precondition(refused(torn), "deflated data that no longer unpacks")
            let listed = try Zip.file("manifest.json", in: whole)
            precondition(listed == list)
            precondition((try? Zip.file("absent", in: whole)) == nil)
        }

        // The key question names the band and the key, and the answer gives the wrapped key only.
        do {
            let form = Dictionary(uniqueKeysWithValues: FirmwareOffer.keyForm(serial: "SERIAL1", key: 20))
            precondition(form["fb_api_req_friendly_name"] == "FetchEncryptedKEKInfoByKEKId" && form["client_doc_id"] == "313699925716490204858433749875")
            precondition(form["variables"] == #"{"request":{"device_serial_number":"SERIAL1","kek_id":20}}"#)
            let key = Data((0..<40).map { UInt8($0) })
            func answer(_ algorithm: String, _ text: String) -> Data {
                Data(#"for (;;);{"data":{"xar_fetch_encrypted_kek_info_by_kek_id":{"encryption_algo":"\#(algorithm)","encrypted_kek":"\#(text)"}}}"#.utf8)
            }
            precondition(FirmwarePackage.wrappedKey(answer("AES_128", key.base64EncodedString())) == key)
            precondition(FirmwarePackage.wrappedKey(answer("AES_256", key.base64EncodedString())) == nil)
            precondition(FirmwarePackage.wrappedKey(answer("AES_128", "not base64!")) == nil)
            precondition(FirmwarePackage.wrappedKey(answer("AES_128", Data([1, 2]).base64EncodedString())) == nil)
            precondition(FirmwarePackage.wrappedKey(Data(#"{"errors":[{"code":190}]}"#.utf8)) == nil)
            precondition(FirmwarePackage.wrappedKey(Data("<html>".utf8)) == nil)
        }
        print("FirmwarePackageTests passed")
    }
}
