// Offline checks of the firmware question Meta is asked and how its answer is read. No network.
// swiftc -module-cache-path /private/tmp/runes-swift-module-cache RunesIOS/Session/Models.swift RunesIOS/Protocol/Wire.swift RunesIOS/Persistence/IdentityStore.swift RunesIOS/Firmware/FirmwareOffer.swift Tests/FirmwareOfferTests.swift -o /private/tmp/runes-firmware-offer-tests && /private/tmp/runes-firmware-offer-tests
// The answer shapes are the ones in the public band-core project's own checks.
import Foundation

@main
struct FirmwareOfferTests {
    static func main() throws {
        // The questions: the stored question's number, and the band named by serial and version.
        for question in FirmwareOffer.Question.allCases {
            let form = question.form(serial: "SERIAL1", version: "770435744", session: "s-1")
            let fields = Dictionary(uniqueKeysWithValues: form)
            precondition(form.map(\.0) == ["method", "pretty", "format", "server_timestamps", "locale", "purpose", "fb_api_req_friendly_name", "client_doc_id", "variables"])
            precondition(fields["fb_api_req_friendly_name"] == question.name && fields["client_doc_id"] == question.document)
            let variables = try JSONSerialization.jsonObject(with: Data(fields["variables"]!.utf8)) as! [String: Any]
            let request = variables["fetch_request"] as! [String: Any]
            switch question {
            case .system:
                let band = (request["topology_fetch_update_info"] as! [[String: Any]])[0]
                precondition(band["device_serial_number"] as? String == "SERIAL1" && band["fw_version"] as? String == "770435744")
                precondition(band["device_type"] as? String == "ota.ceres_p1.user" && band["full_update_only"] as? Bool == true)
                precondition(question.document == "29744781653741296994778085945")
            case .constellation:
                let band = (request["constellation_updates_request_info"] as! [[String: Any]])[0]
                precondition(band["device_serial"] as? String == "SERIAL1" && band["device_firmware_version"] as? String == "770435744")
                precondition(band["device_type"] as? String == "ota.ceres.user" && band["device_ota_session_id"] as? String == "s-1")
                precondition(band["constellation_device_serial"] is NSNull && question.document == "155904535318377635033579516369")
            }
        }

        // Answers. The offer is found wherever it sits, with numbers as text or as numbers.
        let older = #"{"data":{"xar_fetch_constellation_system_updates":{"fetch_update_info_list":[{"fetch_update_response":{"file_uri":"https://example.invalid/ota.zip?sig=abc","target_version":"1054928927","base_version":"0","build_number_display_name":"70","file_size":"4928512","file_checksum":"ab12","kek_id":20,"release_notes_cms":"<p>Notes</p>"}}]}}}"#
        guard case .offer(let first) = FirmwareOffer.read(Data(older.utf8)) else { preconditionFailure("The older answer holds an offer") }
        precondition(first.target == "1054928927" && first.build == "70" && first.size == 4928512 && first.key == 20 && first.checksum == "ab12")
        precondition(first.link?.host == "example.invalid")
        precondition(first.summary == "build 70 (1054928927), 4813 KB, needs key 20" && !first.summary.contains("example"))
        let newer = #"for (;;);{"data":{"xar_constellation_updates":{"constellation_updates_response_info":[{"device_serial":"SERIAL1","firmware_update_info":{"file_uri":"https://example.invalid/u","target_version":1003366292,"base_version":770435744}}]}}}"#
        guard case .offer(let second) = FirmwareOffer.read(Data(newer.utf8)) else { preconditionFailure("The newer answer holds an offer") }
        precondition(second.target == "1003366292" && second.summary == "version 1003366292, over 770435744" && !second.summary.contains("SERIAL1"))
        // A link that is not https is not kept.
        guard case .offer(let plain) = FirmwareOffer.read(Data(#"{"a":{"file_uri":"http://example.invalid/u","target_version":"9"}}"#.utf8)) else { preconditionFailure() }
        precondition(plain.link == nil && plain.target == "9")
        // Nothing offered, a refusal with Meta's numbers and none of its text, and what cannot be read.
        precondition(FirmwareOffer.read(Data(#"{"data":{"xar_fetch_constellation_system_updates":{"fetch_update_info_list":[]}}}"#.utf8)) == .nothing)
        let refused = FirmwareOffer.read(Data(#"{"errors":[{"message":"Token for SERIAL1 is not allowed","code":1675030,"severity":"CRITICAL"}],"error":{"message":"private","code":190,"error_subcode":460}}"#.utf8))
        precondition(refused == .refused("code 1675030 severity CRITICAL; code 190 error_subcode 460"))
        for odd in ["", "<html>", "[1,2]", "for (;;);"] {
            let reply = FirmwareOffer.read(Data(odd.utf8))
            precondition(reply == .unreadable || reply == .nothing, odd)
        }
        precondition(FirmwareOffer.read(Data("[1,2]".utf8)) == .unreadable)
        // Text that is not a short number or word is left out of an offer.
        guard case .offer(let odd) = FirmwareOffer.read(Data(#"{"file_uri":"https://example.invalid/u","target_version":"12","build_number_display_name":"70 <b>new</b>","kek_id":"x y"}"#.utf8)) else { preconditionFailure() }
        precondition(odd.build == nil && odd.key == nil)

        // The band's serial number and software version come from its device information.
        let info = PB.field(2, Data("79a235830f7f".utf8)) + PB.field(3, Data("770435744".utf8)) + PB.field(6, Data("2Q9ABC123XYZ".utf8))
        let identity = BandInfo.identity(PB.field(1, 1) + PB.field(2, 1) + PB.field(4, info))
        precondition(identity?.serial == "2Q9ABC123XYZ" && identity?.software == "770435744")
        precondition(BandInfo.identity(PB.field(4, PB.field(3, Data("1".utf8)) + PB.field(6, Data("a b".utf8)))) == nil)
        precondition(BandInfo.identity(PB.field(4, PB.field(6, Data("SERIAL1".utf8)))) == nil && BandInfo.identity(Data()) == nil)
        // What is journalled about the band's software still leaves the serial number out.
        precondition(BandInfo.describe(PB.field(4, info))?.contains("2Q9ABC123XYZ") == false)
        print("Firmware offer checks passed: both questions, offers in either answer, refusals without Meta's text, and the band's identity.")
    }
}
