import Foundation

/// What Meta offers a band as its next firmware, and how it is asked. The two questions are
/// the ones the Meta app asks, as the public band-core project wrote them down.
struct FirmwareOffer: Equatable {
    /// The version the package installs, and the one it must be installed over, if any.
    let target: String
    let base: String?
    /// The short build number the Meta app shows, such as 70.
    let build: String?
    let size: Int?
    /// The key the band needs to read this package.
    let key: Int?
    /// Where the package is and its SHA-256. Kept in memory, never written to the journal.
    let link: URL?
    let checksum: String?

    /// Versions and sizes only, for the page and the journal.
    var summary: String {
        var parts = [build.map { "build \($0) (\(target))" } ?? "version \(target)"]
        if let base, !base.isEmpty, base != "0" { parts.append("over \(base)") }
        if let size { parts.append("\(size / 1024) KB") }
        if let key { parts.append("needs key \(key)") }
        return parts.joined(separator: ", ")
    }

    enum Question: CaseIterable {
        case system, constellation

        var name: String { self == .system ? "FetchSystemUpdates" : "FetchConstellationUpdates" }
        /// The number Meta's own app sends to name the stored question.
        var document: String { self == .system ? "29744781653741296994778085945" : "155904535318377635033579516369" }

        /// What the question says about the band: its serial number and the version it runs.
        func variables(serial: String, version: String, session: String) -> [String: Any] {
            switch self {
            case .system:
                return ["fetch_request": ["topology_fetch_update_info": [[
                    "custom_ota_fetch_type": "CERES_USER_INSIGHTS_NO_DEVICE_IDENTITY", "full_update_only": true,
                    "device_serial_number": serial, "device_type": "ota.ceres_p1.user", "fw_version": version]]]]
            case .constellation:
                return ["fetch_request": ["constellation_updates_request_info": [[
                    "device_type": "ota.ceres.user", "device_serial": serial, "device_ota_session_id": session,
                    "device_firmware_version": version, "device_feature_list": [String](), "device_artifact_list": [String](),
                    "device_firmware_full_update_only": true, "device_firmware_rollout_token": NSNull(),
                    "device_manage_mode": NSNull(), "constellation_device_type": NSNull(),
                    "constellation_device_firmware_version": NSNull(), "constellation_device_serial": NSNull(),
                    "supports_firmware_manifest_v1": true]]]]
            }
        }

        /// The fields of the request, in the order they are sent.
        func form(serial: String, version: String, session: String) -> [(String, String)] {
            FirmwareOffer.form(name: name, document: document, variables: variables(serial: serial, version: version, session: session))
        }
    }

    /// The question that asks for the key a package needs, wrapped for one band.
    static let keyName = "FetchEncryptedKEKInfoByKEKId"
    static func keyForm(serial: String, key: Int) -> [(String, String)] {
        form(name: keyName, document: "313699925716490204858433749875", variables: ["request": ["device_serial_number": serial, "kek_id": key]])
    }

    private static func form(name: String, document: String, variables: [String: Any]) -> [(String, String)] {
        let variables = (try? JSONSerialization.data(withJSONObject: variables, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return [("method", "post"), ("pretty", "false"), ("format", "json"), ("server_timestamps", "true"), ("locale", "en_US"),
                ("purpose", "fetch"), ("fb_api_req_friendly_name", name), ("client_doc_id", document), ("variables", variables)]
    }

    enum Reply: Equatable {
        case offer(FirmwareOffer)
        /// Meta answered and offered nothing.
        case nothing
        /// Meta refused. The codes are Meta's own numbers, with no text from the answer.
        case refused(String)
        case unreadable
    }

    /// Reads Meta's answer. The offer is the object that holds a link, wherever it sits.
    static func read(_ data: Data) -> Reply {
        var text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("for (;;);") { text.removeFirst(9) }
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return .unreadable }
        if let found = offer(in: json, depth: 0) { return .offer(found) }
        guard let object = json as? [String: Any] else { return .unreadable }
        let errors = (object["errors"] as? [[String: Any]] ?? []) + [object["error"] as? [String: Any]].compactMap { $0 }
        guard !errors.isEmpty else { return .nothing }
        let codes = errors.map { error in
            ["code", "error_subcode", "api_error_code", "severity"].compactMap { key in plain(error[key]).map { "\(key) \($0)" } }.joined(separator: " ")
        }
        return .refused(codes.filter { !$0.isEmpty }.joined(separator: "; "))
    }

    private static func offer(in json: Any, depth: Int) -> FirmwareOffer? {
        guard depth < 12 else { return nil }
        if let object = json as? [String: Any] {
            if let link = object["file_uri"] as? String, let target = plain(object["target_version"]) {
                return FirmwareOffer(target: target, base: plain(object["base_version"]), build: plain(object["build_number_display_name"]),
                                     size: plain(object["file_size"]).flatMap(Int.init), key: plain(object["kek_id"]).flatMap(Int.init),
                                     link: URL(string: link).flatMap { $0.scheme == "https" ? $0 : nil }, checksum: plain(object["file_checksum"]))
            }
            for key in object.keys.sorted() { if let found = offer(in: object[key] as Any, depth: depth + 1) { return found } }
        }
        if let list = json as? [Any] { for item in list { if let found = offer(in: item, depth: depth + 1) { return found } } }
        return nil
    }

    /// A short number or word from an answer. Anything else is left out.
    private static func plain(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty, text.count <= 40, text.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) { return text }
        // A JSON true or false is a number too, and is told apart by its type.
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        return nil
    }
}

extension BandInfo {
    /// The band's serial number and software version from its device information, for asking
    /// Meta about it. Held in memory only.
    static func identity(_ reply: Data) -> (serial: String, software: String)? {
        guard let info = try? Fields(Fields(reply).bytes(4)),
              let serial = BandSettings.text(info, 6), (4...64).contains(serial.count), serial.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              let software = BandSettings.text(info, 3), !software.isEmpty else { return nil }
        return (serial, software)
    }
}
