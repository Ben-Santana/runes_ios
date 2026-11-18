// Offline checks of the band probe against a pretend band. No Bluetooth, no network.
// swiftc -module-cache-path /private/tmp/runes-swift-module-cache RunesIOS/Session/Models.swift RunesIOS/Protocol/Wire.swift RunesIOS/Persistence/IdentityStore.swift RunesIOS/Protocol/BandProbe.swift Tests/BandProbeTests.swift -o /private/tmp/runes-band-probe-tests && /private/tmp/runes-band-probe-tests
import Foundation

@main
struct BandProbeTests {
    /// The stream flags the app has on: gestures alone.
    static let usual = PB.field(2, 0) + PB.field(3, 1) + PB.field(6, 0) + PB.field(8, 0)

    /// The band's answer to a stream request: its status and the switches it says are on.
    static func streams(_ status: UInt64, on: [Int]) -> Data {
        PB.field(1, 9) + PB.field(2, status) + PB.field(5, on.reduce(Data()) { $0 + PB.field($1, 1) })
    }
    static func sent(_ ask: BandProbe.Ask) -> (channel: UInt16, field: Int, payload: Data) {
        guard case .send(let channel, let field, let payload) = ask else { preconditionFailure("expected a request, got \(ask)") }
        return (channel, field, payload)
    }

    static func main() throws {
        // A switch the band takes: asked for, listened to, summarised and turned off again.
        var probe = BandProbe([.streams([5], listen: 2)], usual: usual)
        var ask = sent(probe.next())
        precondition(ask.channel == 5 && ask.field == 4 && ask.payload == usual + PB.field(5, 1))
        precondition(probe.next() == .wait && probe.on == "5 accelerometer")
        probe.answered(streams(1, on: [3, 5]))
        precondition(probe.next() == .listen(2))
        let sample = PB.field(1, 7) + PB.field(2, 123456) + PB.field(3, Data([1, 2, 3, 4, 5, 6]))
        for _ in 0..<256 { probe.heard(kind: 0x0200020e, payload: sample) }
        probe.heard(kind: BandProbe.update, payload: PB.field(3, PB.field(1, Data("[00:01] <inf> imu: started".utf8))))
        ask = sent(probe.next())
        precondition(ask.channel == 5 && ask.field == 4 && ask.payload == usual + PB.field(5, 0))
        // Frames that arrive once the switch is being turned off are not counted.
        probe.heard(kind: 0x0200020e, payload: sample)
        probe.answered(streams(1, on: [3]))
        precondition(probe.on == nil && probe.next() == .done)
        var lines = probe.takeLines()
        precondition(lines == [
            "5 accelerometer: taken, 2 kinds of message arrived.",
            "  256 frames of kind 200020e, about 128 a second, 14 bytes. First: 1=7 2=123456 3=6 bytes 010203040506",
            "  1 log line update (3), 30 bytes. First: 3={1=“00:01 inf imu: started”}",
            "Streams the band took: 5 accelerometer."
        ], "\(lines)")
        precondition(probe.off == PB.field(5, 0) && probe.takeLines().isEmpty)

        // A switch the band does not take is turned off without listening. So are a refusal and silence.
        probe = BandProbe([.streams([7], listen: 2), .streams([9], listen: 2), .streams([10], listen: 2)], usual: usual)
        _ = sent(probe.next())
        probe.answered(streams(1, on: [3]))
        precondition(sent(probe.next()).payload == usual + PB.field(7, 0))
        probe.answered(streams(1, on: [3]))
        precondition(sent(probe.next()).payload == usual + PB.field(9, 1))
        probe.answered(streams(0, on: []))
        precondition(sent(probe.next()).payload == usual + PB.field(9, 0))
        probe.answered(Data())
        precondition(sent(probe.next()).payload == usual + PB.field(10, 1))
        probe.answered(Data())
        _ = sent(probe.next())
        probe.answered(streams(1, on: [3]))
        precondition(probe.next() == .done)
        lines = probe.takeLines()
        precondition(lines == ["7 magnetometer: not taken.", "9 wake status: refused, status 0.", "The band did not confirm turning off 9 wake status.", "10 band log: no answer."], "\(lines)")
        precondition(probe.off == PB.field(7, 0) + PB.field(9, 0) + PB.field(10, 0))

        // Messages that arrive for a switch the band said it did not take are still written down.
        probe = BandProbe([.streams([41], listen: 2)], usual: usual)
        _ = sent(probe.next())
        probe.heard(kind: 0x02000230, payload: Data([0xff]))
        probe.answered(streams(1, on: [3]))
        _ = sent(probe.next())
        precondition(probe.takeLines() == ["41 temperature: not taken.", "41 temperature: not taken, yet 1 kind of message arrived.", "  1 frames of kind 2000230, 1 bytes. First: not a message"])

        // The switches the app runs itself are never named, and several can be on together.
        probe = BandProbe([.streams([2, 3, 4, 6, 8], listen: 2), .streams([3, 16, 38, 99], listen: 30)], usual: usual)
        ask = sent(probe.next())
        precondition(ask.payload == usual + PB.field(16, 1) + PB.field(38, 1))
        probe.answered(streams(1, on: [3, 38]))
        precondition(probe.next() == .listen(30))
        probe.heard(kind: BandProbe.update, payload: PB.field(1, PB.field(1, 2) + PB.field(5, 1)))
        // Stopping ends the listen at once and still turns the switches off.
        probe.stop()
        precondition(sent(probe.next()).payload == usual + PB.field(16, 0) + PB.field(38, 0))
        probe.answered(streams(1, on: [3]))
        precondition(probe.next() == .done)
        lines = probe.takeLines()
        precondition(lines == [
            "Taken: 38 on wrist events. Not taken: 16 device state.",
            "38 on wrist events: taken, 1 kind of message arrived.",
            "  1 device state update (1), 6 bytes. First: 1={1=2 5=1}",
            "Streams the band took: 38 on wrist events."
        ], "\(lines)")

        // Requests go out empty, battery on its own channel, and only the kinds on the list.
        probe = BandProbe([.request(2), .request(26), .request(21), .request(22)], usual: usual)
        ask = sent(probe.next())
        precondition(ask.channel == 8 && ask.field == 2 && ask.payload.isEmpty)
        probe.answered(PB.field(1, 4) + PB.field(2, 1) + PB.field(3, PB.field(1, PB.field(1, 40) + PB.field(2, 1))))
        ask = sent(probe.next())
        precondition(ask.channel == 1 && ask.field == 21 && ask.payload.isEmpty)
        probe.answered(PB.field(1, 5) + PB.field(2, 3))
        precondition(sent(probe.next()).field == 22)
        probe.answered(Data())
        precondition(probe.next() == .done)
        lines = probe.takeLines()
        precondition(lines == ["Request 2 battery: status 1, answer 3={1={1=40 2=1}}.", "Request 21 detector: status 3.", "Request 22 health: no answer.", "Requests the band answered: 2 battery."], "\(lines)")
        precondition(probe.off.isEmpty)

        // Stopping before anything is on ends at once.
        probe = BandProbe(BandProbe.census + BandProbe.sweep, usual: usual)
        precondition(BandProbe.sweep.count == BandProbe.streams.count && BandProbe.census.count == BandProbe.requests.count)
        precondition(BandProbe.events.allSatisfy { BandProbe.streams[$0] != nil } && [2, 3, 4, 6, 8].allSatisfy { BandProbe.streams[$0] == nil })
        probe.stop()
        precondition(probe.next() == .done && probe.takeLines() == ["Stopped."])
        print("Band probe checks passed")
    }
}
