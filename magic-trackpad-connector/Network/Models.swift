import Foundation

// Manual Codable implementations (instead of synthesized) so the encode/decode
// methods can be nonisolated, avoiding @MainActor conflicts from the default
// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor project setting.

struct PeerCommand: Sendable {
    let action: String

    enum CodingKeys: String, CodingKey { case action }
}

extension PeerCommand: Encodable {
    nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(action, forKey: .action)
    }
}

extension PeerCommand: Decodable {
    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(String.self, forKey: .action)
    }
}

struct PeerResponse: Sendable {
    let status: String
    let message: String?

    enum CodingKeys: String, CodingKey { case status, message }
}

extension PeerResponse: Encodable {
    nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(message, forKey: .message)
    }
}

extension PeerResponse: Decodable {
    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status)
        message = try c.decodeIfPresent(String.self, forKey: .message)
    }
}
