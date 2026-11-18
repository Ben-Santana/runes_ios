import Foundation
import Security

/// Keeps the Meta sign-in used for firmware checks in this phone's Keychain, so a check after
/// the app restarts does not ask again. It never leaves the device and is never logged.
enum FirmwareSignIn {
    private static let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                              kSecAttrService as String: "com.runes.ios.firmware-sign-in", kSecAttrAccount as String: "meta"]
    static func load() -> MetaSession? {
        var result: CFTypeRef?
        let query = item.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return MetaSession(accessToken: token)
    }
    static func save(_ session: MetaSession) {
        clear()
        let attributes = item.merging([kSecValueData as String: Data(session.accessToken.utf8),
                                       kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { $1 }
        SecItemAdd(attributes as CFDictionary, nil)
    }
    static func clear() { SecItemDelete(item as CFDictionary) }
}

/// Asks Meta what firmware it offers a band, from this phone, with the sign-in of its owner.
/// Nothing from an answer is logged here, and no cookies or cache are kept.
final class FirmwareService: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let hosts = ["ar-genai.graph.meta.com", "ar.graph.meta.com"]
    /// How the Meta app names itself. Tried only when Meta does not answer a plain request.
    private static let appAgent = "Dalvik/2.1.0 (Linux; U; Android 14) [FBAN/StellaForAndroid;FBAV/295.0.0.37.164;FBPN/com.facebook.stella;FBLC/en_US;FBSN/Android]"
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45
        config.httpCookieStorage = nil; config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func close() { session.invalidateAndCancel() }

    private func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))!
    }

    /// One form to one host. Returns the HTTP status and at most a megabyte of the answer.
    private func post(_ form: [(String, String)], name: String, host: String, token: String, asMetaApp: Bool) async throws -> (status: Int, data: Data?) {
        var request = URLRequest(url: URL(string: "https://\(host)/graphql")!)
        request.httpMethod = "POST"
        request.httpBody = Data(form.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&").utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("OAuth " + token, forHTTPHeaderField: "Authorization")
        request.setValue(name, forHTTPHeaderField: "X-FB-Friendly-Name")
        if asMetaApp { request.setValue(Self.appAgent, forHTTPHeaderField: "User-Agent") }
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1 << 20 else { return ((response as? HTTPURLResponse)?.statusCode ?? 0, nil) }
            data.append(byte)
        }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// One question to one host. Returns the HTTP status and what the answer held.
    func ask(_ question: FirmwareOffer.Question, host: String, serial: String, version: String, token: String, asMetaApp: Bool) async throws -> (status: Int, reply: FirmwareOffer.Reply) {
        let form = question.form(serial: serial, version: version, session: UUID().uuidString.lowercased())
        let answer = try await post(form, name: question.name, host: host, token: token, asMetaApp: asMetaApp)
        return (answer.status, answer.data.map(FirmwareOffer.read) ?? .unreadable)
    }

    /// Asks for the key a package needs, wrapped by Meta for this one band.
    func key(_ number: Int, host: String, serial: String, token: String, asMetaApp: Bool) async throws -> (status: Int, key: Data?) {
        let answer = try await post(FirmwareOffer.keyForm(serial: serial, key: number), name: FirmwareOffer.keyName, host: host, token: token, asMetaApp: asMetaApp)
        return (answer.status, answer.data.flatMap(FirmwarePackage.wrappedKey))
    }

    /// Fetches a package from the link in an offer. The link is not logged.
    func download(_ link: URL) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: link)
        request.timeoutInterval = 60
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 900; config.httpCookieStorage = nil; config.urlCache = nil
        let fetcher = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { fetcher.finishTasksAndInvalidate() }
        let (file, response) = try await fetcher.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard status == 200, size <= Zip.limit else { return (status == 200 ? 0 : status, Data()) }
        return (status, try Data(contentsOf: file))
    }
}
