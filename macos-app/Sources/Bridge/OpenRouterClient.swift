import Foundation
import OSLog

/// Minimal OpenRouter HTTP client used by Settings to verify that a stored
/// API key actually works. Keeps the dependency surface tiny — `URLSession`,
/// `JSONDecoder`, and the single `/auth/key` endpoint.
struct OpenRouterClient {
    private static let logger = Logger(subsystem: "com.callcapture.app", category: "OpenRouter")

    /// Default endpoint base. Matches the worker's `LLM_BASE_URL` default.
    static let defaultBaseURL = URL(string: "https://openrouter.ai/api/v1")!

    let baseURL: URL
    let session: URLSession

    init(baseURL: URL = OpenRouterClient.defaultBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Result of `GET /auth/key` — the field set OpenRouter actually returns.
    struct KeyInfo: Decodable, Sendable {
        let label: String?
        let usage: Double?
        let limit: Double?
        let isFreeTier: Bool?

        enum CodingKeys: String, CodingKey {
            case label
            case usage
            case limit
            case isFreeTier = "is_free_tier"
        }

        /// Human-readable one-line summary.
        var summary: String {
            var parts: [String] = []
            if let label, !label.isEmpty { parts.append(label) }
            if isFreeTier == true {
                parts.append("free tier")
            }
            if let usage, let limit {
                parts.append(String(format: "$%.2f of $%.2f used", usage, limit))
            } else if let usage {
                parts.append(String(format: "$%.2f used", usage))
            }
            return parts.isEmpty ? "key OK" : parts.joined(separator: " · ")
        }
    }

    /// Errors surfaced to the UI.
    enum ClientError: LocalizedError {
        case missingKey
        case invalidKey                                 // 401
        case http(status: Int, body: String)
        case transport(Error)
        case decode(Error)

        var errorDescription: String? {
            switch self {
            case .missingKey: "No API key configured."
            case .invalidKey: "OpenRouter rejected the key (401). Check it on openrouter.ai/keys."
            case .http(let s, let body): "HTTP \(s): \(body.prefix(160))"
            case .transport(let e): "Network error: \(e.localizedDescription)"
            case .decode(let e): "Could not parse OpenRouter response: \(e.localizedDescription)"
            }
        }
    }

    /// `GET /auth/key` — verifies the key and returns label/usage/limit.
    func validate(apiKey: String) async throws -> KeyInfo {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ClientError.missingKey }

        var request = URLRequest(url: baseURL.appendingPathComponent("auth/key"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClientError.transport(error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            do {
                struct Envelope: Decodable { let data: KeyInfo }
                return try JSONDecoder().decode(Envelope.self, from: data).data
            } catch {
                Self.logger.error("decode failed: \(error.localizedDescription)")
                throw ClientError.decode(error)
            }
        case 401:
            throw ClientError.invalidKey
        default:
            let body = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
            throw ClientError.http(status: status, body: body)
        }
    }
}
