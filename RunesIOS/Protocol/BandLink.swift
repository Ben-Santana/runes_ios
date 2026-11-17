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

    /// Firmware from early 2025, the rules this app has always spoken.
    static let original = BandLink(scheme: 3, hashesSecret: true, macPrefix: Data(), padsEveryRecord: false)
    /// Firmware from late 2026. The public band-core project confirmed these rules on a band
    /// running builds 64 and 70.
    static let revised = BandLink(scheme: 26, hashesSecret: false, macPrefix: Data([2, 2, 0, 0]), padsEveryRecord: true)

    /// Picks the rules from the schemes a band offers in its encryption request. Older firmware
    /// offers exactly 3. Newer firmware offers 27 and then uses 26 whatever the phone names.
    static func offered(_ schemes: UInt64) -> BandLink? {
        if schemes == 3 { return .original }
        if schemes & 24 != 0 { return .revised }
        return nil
    }

    /// The key for one direction. The challenge is the receiver's and the seed is the sender's.
    func key(secret: Data, challenge: Data, seed: Data) -> Data {
        if hashesSecret { return BandCrypto.key(secret: secret, challenge: challenge, seed: seed) }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data(SHA256.hash(data: challenge + seed)),
                                         info: Data("AirShield".utf8), outputByteCount: 32)
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
