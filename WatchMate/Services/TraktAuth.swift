import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

struct OAuthTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let createdAt: Int
    var expiresAt: Date { Date(timeIntervalSince1970: Double(createdAt + expiresIn)) }
}

@MainActor
final class TraktAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var refreshTask: Task<OAuthTokens, Error>?
    var connected: Bool { Keychain.read("trakt.tokens") != nil }
    var clientID: String { Configuration.traktClientID }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    private func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw APIError.message("Could not generate secure sign-in values.")
        }
        return Data(bytes).base64URL
    }
    func signIn() async throws {
        guard !clientID.isEmpty && Configuration.callbackConfigured else {
            throw APIError.message("Trakt sign-in is unavailable in this version of WatchMate. Please contact support.")
        }
        guard session == nil else { throw APIError.message("Sign-in is already in progress.") }
        let verifier = try randomString(), state = try randomString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var url = URLComponents(string: "https://auth.trakt.tv/oauth/authorize")!
        url.queryItems = [URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Configuration.redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")]
        defer { session = nil }
        let callback = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: url.url!,
                callback: .https(host: Configuration.callbackHost, path: Configuration.callbackPath)) { callback, error in
                if let error { continuation.resume(throwing: error) }
                else if let callback { continuation.resume(returning: callback) }
                else { continuation.resume(throwing: APIError.message("No sign-in callback received.")) }
            }
            self.session = session
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: APIError.message("Could not start sign-in."))
            }
        }
        guard callback.scheme == "https", callback.host == Configuration.callbackHost,
              callback.path == Configuration.callbackPath,
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            throw APIError.message("Invalid sign-in callback.")
        }
        let items = components.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw APIError.message("Sign-in was declined or could not be verified.")
        }
        let tokens = try await exchange(["code": code, "client_id": clientID,
            "redirect_uri": Configuration.redirectURI, "grant_type": "authorization_code", "code_verifier": verifier])
        try save(tokens)
    }
    func accessToken() async throws -> String {
        guard let data = Keychain.read("trakt.tokens") else { throw APIError.message("Connect Trakt in Settings first.") }
        let tokens = try JSONDecoder().decode(OAuthTokens.self, from: data)
        if tokens.expiresAt > Date().addingTimeInterval(120) { return tokens.accessToken }
        return try await refresh().accessToken
    }
    func refresh() async throws -> OAuthTokens {
        if let refreshTask { return try await refreshTask.value }
        guard let data = Keychain.read("trakt.tokens") else { throw APIError.message("Connect Trakt first.") }
        let tokens = try JSONDecoder().decode(OAuthTokens.self, from: data)
        let task = Task { @MainActor in
            let replacement = try await self.exchange(["refresh_token": tokens.refreshToken,
                "client_id": self.clientID, "redirect_uri": Configuration.redirectURI, "grant_type": "refresh_token"])
            try self.save(replacement) // Refresh tokens are single-use; persist the replacement immediately.
            return replacement
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }
    private func exchange(_ body: [String: String]) async throws -> OAuthTokens {
        var request = URLRequest(url: URL(string: "https://api.trakt.tv/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await HTTP.decode(OAuthTokens.self, request: request)
    }
    private func save(_ tokens: OAuthTokens) throws { try Keychain.write(JSONEncoder().encode(tokens), key: "trakt.tokens") }
    func disconnect() throws { try Keychain.delete("trakt.tokens") }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
