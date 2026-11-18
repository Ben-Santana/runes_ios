import Foundation
import CryptoKit

/// The rules of the band's encrypted link. They changed with its firmware, and the band says
/// which ones it uses when a connection starts, so the app can talk to both.
struct BandLink: Equatable {
    /// The number the band gives these rules in its encryption messages.
    let scheme: UInt64
    /// Whether the record key is derived from a hash of the shared secret or from the secret itself.
    let hashesSecret: Bool
    /// Bytes that every record's check covers before its counter.
    let macPrefix: Data
    /// Whether a record whose frames already fill whole blocks still gets a block of padding.
    let padsEveryRecord: Bool
    /// Where the key for each record's check comes from.
    enum CheckKey: Equatable {
        /// The record key itself.
        case record
        /// A key of its own, derived from the shared secret.
        case derived
        /// A key of its own, derived from a hash of the shared secret.
        case derivedFromHash
    }
    var checkKey = CheckKey.record

    /// Firmware from early 2025, the rules this app has always spoken.
    static let original = BandLink(scheme: 3, hashesSecret: true, macPrefix: Data(), padsEveryRecord: false)
    /// Firmware from late 2026. The public band-core project confirmed these rules on a band
    /// running builds 64 and 70.
    static let revised = BandLink(scheme: 26, hashesSecret: false, macPrefix: Data([2, 2, 0, 0]), padsEveryRecord: true)

    /// Picks the rules from the schemes a band offers in its encryption request. Older firmware
    /// offers exactly 3. Newer firmware offers 27 and then uses 26 whatever the phone names.
    static func offered(_ schemes: UInt64) -> BandLink? { ways(offered: schemes).first }

    /// Every way a band that offers these schemes may make its keys, likeliest first. Older
    /// firmware has one. For newer firmware the rules of scheme 26 are known from other bands,
    /// but a band on build 72 named 27 on 2026-11-17 and nobody has written 27's rules down,
    /// so the app works through these until the band answers a record it can check. The
    /// numbers are sets of switches: 27 is 26 with one more, and 31, which the glasses use
    /// and which is known, is 27 with a key of its own for the check.
    static func ways(offered schemes: UInt64) -> [BandLink] {
        if schemes == 3 { return [.original] }
        guard schemes & 24 != 0 else { return [] }
        let prefix = Data([2, 2, 0, 0])
        func way(_ scheme: UInt64, hashes: Bool, prefixed: Bool, _ check: CheckKey) -> BandLink {
            BandLink(scheme: scheme, hashesSecret: hashes, macPrefix: prefixed ? prefix : Data(), padsEveryRecord: true, checkKey: check)
        }
        // What the phone names back: 26, as the public project does, or the band's own offer.
        let named = schemes == 26 ? [26] : [26, schemes]
        var ways: [BandLink] = []
        for (hashes, prefixed, check) in [(false, true, CheckKey.record), (false, true, .derived), (true, false, .record), (false, false, .record),
                                          (true, true, .record), (false, false, .derived), (true, false, .derivedFromHash), (true, true, .derivedFromHash)] {
            for scheme in named { ways.append(way(scheme, hashes: hashes, prefixed: prefixed, check)) }
        }
        return ways
    }

    /// The key for one direction. The challenge is the receiver's and the seed is the sender's.
    func key(secret: Data, challenge: Data, seed: Data) -> Data {
        if hashesSecret { return BandCrypto.key(secret: secret, challenge: challenge, seed: seed) }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data(SHA256.hash(data: challenge + seed)),
                                         info: Data("AirShield".utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    /// The key for one direction's record checks, given that direction's record key.
    func checkKey(secret: Data, challenge: Data, seed: Data, recordKey: Data) -> Data {
        let hashed = Data(SHA256.hash(data: secret)), label = Data("hmac_derive".utf8)
        let material: Data, salt: Data
        switch checkKey {
        case .record: return recordKey
        case .derived: material = secret; salt = Data(SHA256.hash(data: seed + challenge + label))
        case .derivedFromHash: material = hashed; salt = Data(SHA256.hash(data: seed + challenge + label + hashed))
        }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material), salt: salt, info: Data("AirShield".utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    /// The eight byte check at the front of a record.
    func tag(_ body: Data, counter: UInt32, key: Data) -> Data {
        var count = counter.littleEndian
        let prefix = macPrefix + Swift.withUnsafeBytes(of: &count) { Data($0) }
        return Data(HMAC<SHA256>.authenticationCode(for: prefix + body, using: SymmetricKey(data: key)).prefix(8))
    }

    /// How much plain data fits in one record once its padding is added.
    var recordLimit: Int { padsEveryRecord ? 4080 : 4096 }

    /// Padding bytes for plain data of this length. Each one holds 0xc0 plus the count.
    func padding(for length: Int) -> Int {
        padsEveryRecord ? 16 - length % 16 : (16 - length % 16) % 16
    }

    /// Newer firmware sets extra bits on the channels it answers on, and they change with each
    /// connection. Only the direction bit and the low byte say which channel a frame is for.
    static func route(_ channel: UInt16) -> UInt16 { channel & 0x80ff }

    /// The data channel number the band publishes, low byte first. Bluetooth keeps 0x80 to 0xff
    /// for channels a device assigns itself.
    static func psm(_ value: Data?) -> UInt16? {
        guard let value, value.count == 2 else { return nil }
        let psm = UInt16(value.octet(0)) | UInt16(value.octet(1)) << 8
        return (0x80...0xff).contains(psm) ? psm : nil
    }
}
