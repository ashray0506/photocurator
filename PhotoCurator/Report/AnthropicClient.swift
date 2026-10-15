import Foundation

/// Shared plumbing for the small number of short, single-turn Anthropic API
/// calls this app makes (trip naming, stamp descriptions) — all opt-in,
/// all behind a user-supplied key, all sending only place names/dates,
/// never photos. One request shape, not worth a generated SDK dependency.
enum AnthropicClient {
    enum ClientError: Error, LocalizedError {
        case noAPIKey
        case requestFailed(String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "Add an Anthropic API key in Settings to use this."
            case .requestFailed(let message):
                return "Request failed: \(message)"
            case .emptyResponse:
                return "The AI returned nothing usable."
            }
        }
    }

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-sonnet-4-5"

    static func complete(prompt: String, maxTokens: Int) async throws -> String {
        guard let apiKey = APIKeyStore.load(), !apiKey.isEmpty else {
            throw ClientError.noAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            model: model,
            max_tokens: maxTokens,
            messages: [RequestBody.Message(role: "user", content: prompt)]
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.requestFailed("HTTP \(status): \(body.prefix(200))")
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard let text = decoded.content.first?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\""))),
            !text.isEmpty else {
            throw ClientError.emptyResponse
        }
        return text
    }

    private struct RequestBody: Encodable {
        var model: String
        var max_tokens: Int
        var messages: [Message]
        struct Message: Encodable { var role: String; var content: String }
    }

    private struct ResponseBody: Decodable {
        var content: [ContentBlock]
        struct ContentBlock: Decodable { var text: String? }
    }
}
