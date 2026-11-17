import Foundation
import Security

struct BridgeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Talks to the self-hosted Convo bridge (see bridge/ in this repo).
struct Bridge {
    let baseURL: String
    let token: String

    init?(server: String, token: String) {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !token.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.host != nil, ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        s = url.scheme!.lowercased() + s.drop { $0 != ":" }
        baseURL = s
        self.token = token
    }

    /// Chat and message ids contain characters like "/", "@" and "+", so encode them as one path segment.
    static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) -> URLRequest {
        var req = URLRequest(url: URL(string: baseURL + path)!)
        req.httpMethod = method
        req.timeoutInterval = 60
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    func data(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request(path, method: method, body: body))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw BridgeError(message: message ?? "The bridge answered with HTTP \(code)")
        }
        return data
    }

    func call<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        try JSONDecoder().decode(T.self, from: await data(path, method: method, body: body))
    }

    func eventsSocket() -> URLSessionWebSocketTask {
        let wsBase = baseURL.hasPrefix("https://") ? "wss://" + baseURL.dropFirst(8) : "ws://" + baseURL.dropFirst(7)
        var req = URLRequest(url: URL(string: wsBase + "/api/events")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return URLSession.shared.webSocketTask(with: req)
    }
}

/// The bridge token is a password, so it lives in the Keychain rather than UserDefaults.
enum Keychain {
    private static let service = "convo.bridge"

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String, _ value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
