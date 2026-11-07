import Foundation
import Security
import SwiftData
import SwiftUI

enum AnalyzeModel: String, CaseIterable, Identifiable {
    case opus = "Opus 5.5"
    case grok = "Grok 4.7"
    case gpt = "GPT 6.1"

    var id: String { rawValue }

    var providerAccount: String {
        switch self {
        case .opus: "anthropic"
        case .grok: "xai"
        case .gpt: "openai"
        }
    }

    var apiModelID: String {
        switch self {
        case .opus: "claude-opus-5-5"
        case .grok: "grok-4.7"
        case .gpt: "gpt-6.1-sol"
        }
    }

    var keyLabel: String {
        switch self {
        case .opus: "Anthropic key"
        case .grok: "xAI key"
        case .gpt: "OpenAI key"
        }
    }
}

enum AnalyzeKeychain {
    private static let service = "fully-tracked-analyze"

    static func load(_ account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    static func save(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

struct AnalyzeView: View {
    @Query private var entries: [JournalEntry]
    @State private var question = ""
    @State private var model: AnalyzeModel = .opus
    @State private var anthropicKey = ""
    @State private var xaiKey = ""
    @State private var openAIKey = ""
    @State private var result = ""
    @State private var failure = ""
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Analyze")
                    .font(Theme.font(28))
                    .foregroundStyle(Theme.ink)
                TextField("Question", text: $question, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.roundedBorder)
                Picker("Model", selection: $model) {
                    ForEach(AnalyzeModel.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                SecureField("Anthropic key", text: $anthropicKey)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: anthropicKey) { value in
                        AnalyzeKeychain.save(value, account: AnalyzeModel.opus.providerAccount)
                    }
                SecureField("xAI key", text: $xaiKey)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: xaiKey) { value in
                        AnalyzeKeychain.save(value, account: AnalyzeModel.grok.providerAccount)
                    }
                SecureField("OpenAI key", text: $openAIKey)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: openAIKey) { value in
                        AnalyzeKeychain.save(value, account: AnalyzeModel.gpt.providerAccount)
                    }
                Button(busy ? "Analyzing" : "Analyze") {
                    Task { await ask() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
                if !failure.isEmpty {
                    Text(failure)
                        .font(Theme.font(15))
                        .foregroundStyle(.red)
                }
                if !result.isEmpty {
                    Text(result)
                        .font(Theme.font(17))
                        .foregroundStyle(Theme.ink)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            anthropicKey = AnalyzeKeychain.load(AnalyzeModel.opus.providerAccount)
            xaiKey = AnalyzeKeychain.load(AnalyzeModel.grok.providerAccount)
            openAIKey = AnalyzeKeychain.load(AnalyzeModel.gpt.providerAccount)
        }
    }

    private var selectedKey: String {
        switch model {
        case .opus: anthropicKey
        case .grok: xaiKey
        case .gpt: openAIKey
        }
    }

    private func ask() async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = selectedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            failure = "Enter a question."
            result = ""
            return
        }
        guard !key.isEmpty else {
            failure = "Add your key for \(model.rawValue)."
            result = ""
            return
        }
        busy = true
        failure = ""
        result = ""
        defer { busy = false }
        do {
            result = try await AnalyzeClient.ask(model: model, apiKey: key, question: trimmed, entries: entries)
        } catch {
            failure = error.localizedDescription
        }
    }
}

enum AnalyzeClient {
    static func ask(model: AnalyzeModel, apiKey: String, question: String, entries: [JournalEntry]) async throws -> String {
        let locations = entries
            .filter { $0.entryType == .location && $0.latitude != nil && $0.longitude != nil }
            .map { entry -> [String: Any] in
                var item: [String: Any] = [
                    "latitude": entry.latitude ?? 0,
                    "longitude": entry.longitude ?? 0,
                    "time": ISO8601DateFormatter().string(from: entry.occurredAt),
                ]
                if let accuracy = entry.accuracyMeters { item["accuracy"] = accuracy }
                else { item["accuracy"] = NSNull() }
                if let altitude = entry.altitude { item["altitude"] = altitude }
                else { item["altitude"] = NSNull() }
                return item
            }
        let rows = try JSONSerialization.data(withJSONObject: locations)
        let list = String(data: rows, encoding: .utf8) ?? "[]"
        let prompt = "Answer the question using only these location check-ins. Each item has latitude, longitude, accuracy in meters, time, and altitude in meters or null.\n\nQuestion: \(question)\n\nLocations:\n\(list)"
        switch model {
        case .opus:
            return try await anthropic(apiKey: apiKey, modelID: model.apiModelID, prompt: prompt)
        case .grok:
            return try await grok(apiKey: apiKey, modelID: model.apiModelID, prompt: prompt)
        case .gpt:
            return try await chat(url: URL(string: "https://api.openai.com/v1/chat/completions")!, apiKey: apiKey, modelID: model.apiModelID, prompt: prompt)
        }
    }

    private static func anthropic(apiKey: String, modelID: String, prompt: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelID,
            "max_tokens": 2048,
            "messages": [["role": "user", "content": prompt]],
        ])
        let payload = try await send(request, apiKey: apiKey)
        let blocks = payload["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw AnalyzeError.empty }
        return text
    }

    private static func grok(apiKey: String, modelID: String, prompt: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelID,
            "input": prompt,
            "store": false,
        ])
        let payload = try await send(request, apiKey: apiKey)
        if let text = payload["output_text"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let output = payload["output"] as? [[String: Any]] ?? []
        let text = output.flatMap { item -> [String] in
            let content = item["content"] as? [[String: Any]] ?? []
            return content.compactMap { part in
                guard part["type"] as? String == "output_text" else { return nil }
                return part["text"] as? String
            }
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw AnalyzeError.empty }
        return text
    }

    private static func chat(url: URL, apiKey: String, modelID: String, prompt: String) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelID,
            "messages": [["role": "user", "content": prompt]],
        ])
        let payload = try await send(request, apiKey: apiKey)
        let choices = payload["choices"] as? [[String: Any]] ?? []
        let message = choices.first?["message"] as? [String: Any]
        let content = message?["content"]
        let text: String
        if let content = content as? String {
            text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let parts = content as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            text = ""
        }
        if text.isEmpty { throw AnalyzeError.empty }
        return text
    }

    private static func send(_ request: URLRequest, apiKey: String) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let raw = ((payload["error"] as? [String: Any])?["message"] as? String) ?? "The provider rejected the request."
            let message = raw.contains(apiKey) ? "The provider rejected the request." : String(raw.prefix(500))
            throw AnalyzeError.rejected(message)
        }
        return payload
    }
}

enum AnalyzeError: LocalizedError {
    case empty
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .empty: "The provider returned no text."
        case .rejected(let message): message
        }
    }
}
