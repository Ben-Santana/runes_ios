import Foundation

/// How gestures and motion are asked for. A band reports a protocol version about itself, and
/// from version 2 it wants each kind of message named in a list beside the older switches.
/// The list, its priority and its use case are what the public visor project sends. No band
/// known to this project has reported version 2 yet, so this path is unproven on hardware.
enum BandStreams {
    /// The kinds of gesture message a version 2 band can send.
    static let gestureKinds: [UInt64] = Array(60...70) + Array(100...109) + Array(150...156) + [200]
    private static let gyroKind: UInt64 = 15, orientationKind: UInt64 = 18, inferenceKind: UInt64 = 12

    /// The protocol version in a device information reply. A band that leaves it out is version 1.
    static func version(from reply: Data) -> UInt64 {
        guard let info = try? Fields(Fields(reply).bytes(4)), let version = try? info.integer(15, default: 1) else { return 1 }
        return version
    }

    /// The stream request for a band of this version. Earlier bands get the switches alone, unchanged.
    static func request(_ flags: Data, version: UInt64) -> Data {
        guard version >= 2, let wanted = try? Fields(flags) else { return flags }
        func on(_ field: Int) -> UInt64 { (try? wanted.integer(field, default: 0)) ?? 0 }
        var request = flags + PB.field(35, 90)
        for kind in gestureKinds { request += PB.field(36, PB.field(1, kind) + PB.field(2, on(3))) }
        request += PB.field(36, PB.field(1, gyroKind) + PB.field(2, on(6)))
        request += PB.field(36, PB.field(1, orientationKind) + PB.field(2, on(8)))
        if wanted.values[4] != nil { request += PB.field(36, PB.field(1, inferenceKind) + PB.field(2, on(4))) }
        return request + PB.field(37, Data("GenericC50".utf8))
    }

    /// Whether a message of this type is a gesture. Version 2 sends the kinds above as well as
    /// the single kind earlier bands use, all with the same contents.
    static func isGesture(_ type: UInt32, version: UInt64) -> Bool {
        type == 0x0200020d || (version >= 2 && type & 0xffffff00 == 0x02000200 && (60...200).contains(type & 0xff))
    }
}
