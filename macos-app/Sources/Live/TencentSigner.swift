import CryptoKit
import Foundation

enum TencentSignerError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case invalidConfiguration

    var errorDescription: String? {
        "Tencent ASR signing configuration is invalid."
    }

    var description: String { errorDescription ?? "Tencent ASR signing error." }
}

/// Creates authenticated Tencent speaker-mode WebSocket request URLs.
///
/// Tencent signs the host, path, and lexicographically sorted query (without a
/// scheme or `signature`) using HMAC-SHA1. Only the resulting Base64 signature
/// is percent encoded when it is appended to the final URL.
struct TencentSigner: Sendable {
    private static let host = "asr.cloud.tencent.com"
    private static let expirationSeconds = 24 * 60 * 60

    func signedURL(
        configuration: ASRConfiguration,
        timestamp: Int,
        nonce: Int
    ) throws -> URL {
        guard isValid(configuration: configuration),
              timestamp > 0,
              nonce > 0,
              String(nonce).count <= 10
        else {
            throw TencentSignerError.invalidConfiguration
        }

        let (expired, overflow) = timestamp.addingReportingOverflow(Self.expirationSeconds)
        guard !overflow else { throw TencentSignerError.invalidConfiguration }

        let query: [String: String] = [
            "convert_num_mode": "1",
            "emotion_recognition": "0",
            "enable_speaker_context": "0",
            "engine_model_type": configuration.engineModelType,
            "expired": String(expired),
            "language_judgment": "0",
            "needvad": "1",
            "nonce": String(nonce),
            "reinforce_hotword": "0",
            "result_mod": "1",
            "secretid": configuration.secretID,
            "sentence_strategy": "1",
            "speaker_context_id": "",
            "speaker_diarization": "1",
            "timestamp": String(timestamp),
            "voice_format": "1",
            "voice_id": configuration.voiceID,
        ]

        let canonicalQuery = query.sorted { lhs, rhs in
            lhs.key < rhs.key
        }.map { key, value in
            "\(key)=\(value)"
        }.joined(separator: "&")
        let unsignedURL = "\(Self.host)/asr/v2/\(configuration.appID)?\(canonicalQuery)"

        let key = SymmetricKey(data: Data(configuration.secretKey.utf8))
        let authenticationCode = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(unsignedURL.utf8),
            using: key
        )
        let signature = Data(authenticationCode).base64EncodedString()

        guard let encodedSignature = signature.addingPercentEncoding(
            withAllowedCharacters: Self.unreservedCharacters
        ),
        let url = URL(string: "wss://\(unsignedURL)&signature=\(encodedSignature)")
        else {
            throw TencentSignerError.invalidConfiguration
        }

        return url
    }
}

private extension TencentSigner {
    static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    func isValid(configuration: ASRConfiguration) -> Bool {
        !configuration.appID.isEmpty
            && configuration.appID.utf8.allSatisfy { (48...57).contains($0) }
            && isUnreserved(configuration.secretID)
            && !configuration.secretKey.isEmpty
            && isUnreserved(configuration.voiceID)
            && configuration.voiceID.utf8.count <= 128
            && isUnreserved(configuration.engineModelType)
    }

    func isUnreserved(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            Self.unreservedCharacters.contains($0)
        }
    }
}
