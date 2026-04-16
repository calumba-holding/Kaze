import Foundation

/// Sends transcription text to cloud AI models via Cloudflare AI Gateway
/// for enhancement or formatting. Supports OpenAI, Google Gemini, and Anthropic
/// models through a unified OpenAI-compatible endpoint.
@MainActor
class CloudEnhancer {

    private static let gatewayURL = URL(
        string: "https://gateway.ai.cloudflare.com/v1/7e259235995e0f3d11b31545743b30a3/kaze/compat/chat/completions"
    )!

    /// Sends a text processing request to the cloud AI model.
    /// - Parameters:
    ///   - text: The transcription text to process.
    ///   - systemPrompt: The system prompt instructing the model how to process the text.
    ///   - userPrompt: The user message wrapping the text (e.g. "Clean up this transcription:\n\n<text>").
    ///   - provider: The cloud AI provider to use.
    ///   - modelID: The model identifier string.
    /// - Returns: The processed text, or the original text if the request fails.
    func process(
        _ text: String,
        systemPrompt: String,
        userPrompt: String,
        provider: CloudAIProvider,
        modelID: String
    ) async throws -> String {
        guard let apiKey = KeychainManager.getAPIKey(for: provider), !apiKey.isEmpty else {
            throw CloudEnhancerError.missingAPIKey(provider)
        }

        let requestBody = ChatCompletionRequest(
            model: modelID,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPrompt),
            ],
            temperature: 0.1,
            reasoning_effort: provider.reasoningEffort
        )

        var request = URLRequest(url: Self.gatewayURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudEnhancerError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CloudEnhancerError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)

        guard let content = decoded.choices.first?.message.content else {
            throw CloudEnhancerError.emptyResponse
        }

        let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? text : result
    }

    /// Convenience: enhance transcription text using the enhancement prompt.
    func enhance(
        _ text: String,
        systemPrompt: String,
        provider: CloudAIProvider,
        modelID: String
    ) async throws -> String {
        try await process(
            text,
            systemPrompt: systemPrompt,
            userPrompt: "Clean up this transcription:\n\n\(text)",
            provider: provider,
            modelID: modelID
        )
    }

    /// Convenience: format transcription text using the smart formatting prompt.
    func format(
        _ text: String,
        provider: CloudAIProvider,
        modelID: String
    ) async throws -> String {
        try await process(
            text,
            systemPrompt: AppPreferenceKey.smartFormattingPrompt,
            userPrompt: "Format this transcription:\n\n\(text)",
            provider: provider,
            modelID: modelID
        )
    }
}

// MARK: - Request / Response Types

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [Message]
    let temperature: Double
    let reasoning_effort: String?

    struct Message: Encodable {
        let role: String
        let content: String
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, reasoning_effort
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encode(temperature, forKey: .temperature)
        // Only include reasoning_effort when non-nil to avoid sending null
        // to providers that don't support it.
        if let effort = reasoning_effort {
            try container.encode(effort, forKey: .reasoning_effort)
        }
    }
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
    }
}

// MARK: - Errors

enum CloudEnhancerError: LocalizedError {
    case missingAPIKey(CloudAIProvider)
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "No API key configured for \(provider.title). Add your key in Settings."
        case .invalidResponse:
            return "Received an invalid response from the AI gateway."
        case .httpError(let statusCode, let body):
            return "AI gateway returned HTTP \(statusCode): \(body)"
        case .emptyResponse:
            return "AI model returned an empty response."
        }
    }
}
