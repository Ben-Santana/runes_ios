import Foundation

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

    /// One question to one host. Returns the HTTP status and what the answer held.
    func ask(_ question: FirmwareOffer.Question, host: String, serial: String, version: String, token: String, asMetaApp: Bool) async throws -> (status: Int, reply: FirmwareOffer.Reply) {
        var request = URLRequest(url: URL(string: "https://\(host)/graphql")!)
        request.httpMethod = "POST"
        request.httpBody = Data(question.form(serial: serial, version: version, session: UUID().uuidString.lowercased())
            .map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&").utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("OAuth " + token, forHTTPHeaderField: "Authorization")
        request.setValue(question.name, forHTTPHeaderField: "X-FB-Friendly-Name")
        if asMetaApp { request.setValue(Self.appAgent, forHTTPHeaderField: "User-Agent") }
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1 << 20 else { return ((response as? HTTPURLResponse)?.statusCode ?? 0, .unreadable) }
            data.append(byte)
        }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, FirmwareOffer.read(data))
    }
}
