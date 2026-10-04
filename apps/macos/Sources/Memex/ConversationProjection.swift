import Foundation

/// Projects the runtime's display subset. Its complete persisted catalog is evidence,
/// not an additional timeline: rendering both would duplicate the active turn.
enum ConversationProjection {
    static func conversation(in json: String, sessionID: String) throws -> RawTranscriptJSON? {
        let value = try JSONDecoder().decode(RawTranscriptJSON.self, from: Data(json.utf8))
        if value["conversation"]["session_id"].string == sessionID { return value["conversation"] }
        return value["conversations"].array.first { $0["session_id"].string == sessionID }
    }

    static func snapshot(_ conversation: RawTranscriptJSON, thread: RawTranscriptJSON = .null,
                         operations: RawTranscriptJSON = .array([]), ready: Bool, canCancel: Bool,
                         sentPromptIDs: Set<String> = []) -> ConversationSnapshot {
        let pendingIDs = Set(conversation["state"]["pending_interactions"].array.compactMap(\.string))
        let pending = thread["pendingRequests"].array.filter { pendingIDs.contains($0["requestId"].string ?? "") }
        let approvals = pending.filter { $0["kind"].string == "approval" }.compactMap { request -> ConversationApproval? in
            guard let id = request["requestId"].string else { return nil }
            let payload = request["payload"]
            return ConversationApproval(id: id, title: payload["title"].string ?? "Approval required",
                detail: payload["rawInputJSON"].string, options: payload["options"].array.compactMap {
                    guard let id = $0["id"].string else { return nil }
                    return .init(id: id, title: $0["name"].string ?? id, kind: $0["kind"].string ?? "")
                })
        }
        let questions = pending.filter { $0["kind"].string == "user_input" }.compactMap { request -> ConversationQuestion? in
            guard let id = request["requestId"].string else { return nil }
            let payload = request["payload"]
            return ConversationQuestion(id: id, title: payload["title"].string, prompt: payload["prompt"].string ?? "Your input is needed",
                placeholder: payload["placeholder"].string, choices: payload["choices"].array.compactMap {
                    guard let id = $0["id"].string, let title = $0["title"].string else { return nil }
                    return .init(id: id, title: title, value: $0["value"].string ?? title)
                })
        }
        let pendingPrompts = operations.array.filter {
            ["thread.turn.start", "thread.turn.steer"].contains($0["command"]["type"].string ?? "")
                && !["completed", "failed"].contains($0["status"].string ?? "")
        }
        let running = conversation["state"]["running"].bool ?? false
        // A command sent by this connection is ordinary work, even before the
        // provider reports a running turn. Only recovered operations need review.
        let recoveredPrompt = pendingPrompts.contains {
            !sentPromptIDs.contains($0["command"]["commandId"].string ?? "")
        }
        var renderer = Renderer(conversation: conversation)
        return ConversationSnapshot(records: renderer.render(), connected: conversation["connected"].bool ?? false,
            ready: ready, running: running, pendingPrompt: !pendingPrompts.isEmpty,
            canCancel: canCancel, approvals: approvals, questions: questions,
            warning: recoveredPrompt && !running
                ? "A previous prompt has no confirmed outcome. It will not be sent again automatically. Check the native session before continuing."
                : nil)
    }

    private struct Renderer {
        let persisted: [RawTranscriptJSON]
        let live: [RawTranscriptJSON]
        var entities: [String: RawTranscriptJSON] = [:]
        var liveTools: [String: RawTranscriptJSON] = [:]
        var liveResults: [String: RawTranscriptJSON] = [:]
        var emitted: Set<String> = []
        var records: [TranscriptRecord] = []

        init(conversation: RawTranscriptJSON) {
            persisted = conversation["presentation"].array
            live = conversation["ephemeral"].array.sorted { $0["source_order"].integer < $1["source_order"].integer }
            for entity in persisted {
                if let id = entity["entity_id"].string { entities[id] = entity }
            }
            for entity in live {
                if let id = entity["item_id"].string { entities[id] = entity }
                if entity["body"]["kind"].string == "tool_invocation", let call = entity["body"]["data"]["native_call_id"].string {
                    liveTools[call] = entity
                }
                if entity["body"]["kind"].string == "tool_result", let call = entity["body"]["data"]["native_correlation_key"].string {
                    liveResults[call] = entity
                }
            }
        }

        mutating func render() -> [TranscriptRecord] {
            let entries = persisted.filter { $0["body"]["kind"].string == "entry" }
                .sorted { $0["body"]["data"]["source_order"].integer < $1["body"]["data"]["source_order"].integer }
            for entry in entries {
                let data = entry["body"]["data"]
                guard data["display"].bool != false else { continue }
                let payload = data["payload"]
                if payload["type"].string == "entity" {
                    if let id = payload["data"]["entity_id"].string, let entity = entities[id] { emit(entity) }
                } else if payload["type"].string == "branch_summary", let summary = payload["data"]["summary"].string {
                    append(entry, suffix: "summary", role: "system", text: summary, context: "Conversation summary")
                } else if payload["type"].string == "model_change", let model = payload["data"]["model"].string {
                    append(entry, suffix: "model", role: "system", text: model, context: "Model")
                }
            }
            for entity in live { emit(entity) }
            return records
        }

        mutating func emit(_ original: RawTranscriptJSON) {
            let kind = original["body"]["kind"].string ?? ""
            let originalData = original["body"]["data"]
            let entity: RawTranscriptJSON
            let nativeKey: String?
            switch kind {
            case "tool_invocation":
                nativeKey = originalData["native_call_id"].string
                entity = nativeKey.flatMap { liveTools[$0] } ?? original
            case "tool_result":
                nativeKey = originalData["native_correlation_key"].string
                entity = nativeKey.flatMap { liveResults[$0] } ?? original
            default:
                nativeKey = nil
                entity = original
            }
            guard let id = entity["entity_id"].string ?? entity["item_id"].string else { return }
            let identity = nativeKey.map { "\(kind):\($0)" } ?? "entity:\(id)"
            guard emitted.insert(identity).inserted else { return }
            let data = entity["body"]["data"]
            switch kind {
            case "message":
                let role = data["role"].string ?? "assistant"
                let initialCount = records.count
                for (index, part) in data["parts"].array.enumerated() {
                    switch part["type"].string {
                    case "text", "reasoning":
                        append(entity, suffix: "part-\(index)", role: part["type"].string == "reasoning" ? "reasoning" : role,
                               text: part["data"].string ?? "", nativeID: data["native_message_id"].string)
                    case "tool_call":
                        if let ref = part["data"]["invocation_id"].string, let tool = entities[ref] { emit(tool) }
                    case "tool_result":
                        if let ref = part["data"]["result_id"].string, let result = entities[ref] { emit(result) }
                    case "artifact":
                        if let ref = part["data"]["entity_id"].string, let artifact = entities[ref] {
                            appendArtifact(artifact, owner: entity, suffix: "part-\(index)", role: role)
                        }
                    case "opaque":
                        let value = part["data"]["value"]
                        // Opaque is not a text format. Only recognized media blocks
                        // enter the existing attachment renderer; encrypted reasoning
                        // and transport metadata remain in the raw source record.
                        let sourceContent = RawTranscriptJSON.array([value]).jsonText
                        let media = Message(role: role, text: "", toolName: nil, toolInput: nil, toolOutput: nil,
                                            sourceContent: sourceContent)
                        if !SourceContent.blocks(media).isEmpty {
                            append(entity, suffix: "part-\(index)", role: role, text: "", sourceContent: sourceContent)
                        }
                    default: break
                    }
                }
                if records.count == initialCount {
                    append(entity, suffix: "raw", role: role, text: "", rawOnly: true)
                }
            case "tool_invocation":
                append(entity, suffix: "call", role: "tool_use", text: "", nativeID: data["native_call_id"].string,
                       toolName: data["name"].string, input: data["raw_arguments"].string ?? data["decoded_arguments"].jsonText,
                       parentTool: data["parent_invocation_id"].string)
            case "tool_result":
                let text = data["parts"].array.compactMap { part -> String? in
                    if ["text", "reasoning"].contains(part["type"].string ?? "") { return part["data"].string }
                    if part["type"].string == "structured" { return part["data"]["value"].jsonText }
                    return nil
                }.joined(separator: "\n")
                append(entity, suffix: "result", role: "tool_result", text: "", output: text,
                       parentTool: data["native_correlation_key"].string, isError: data["outcome"].string == "error")
            case "artifact":
                appendArtifact(entity, owner: entity, suffix: "artifact", role: "assistant")
            case "context_boundary":
                if let summary = data["summary"]["entity_id"].string, let value = entities[summary] { emit(value) }
            default: break
            }
        }

        mutating func appendArtifact(_ entity: RawTranscriptJSON, owner: RawTranscriptJSON, suffix: String, role: String) {
            let data = entity["body"]["data"]
            let location = data["content"]["data"]["uri"].string ?? data["native_locations"].array.first?.string
            if let location {
                let isImage = data["media_type"].string?.hasPrefix("image/") == true || location.hasPrefix("data:image/")
                let content = RawTranscriptJSON.array([.object([
                    "type": .string(isImage ? "image" : "attachment"), "url": .string(location), "path": .string(location)
                ])]).jsonText
                append(owner, suffix: suffix, role: role, text: "", sourceContent: content)
            } else {
                append(owner, suffix: suffix, role: role, text: "Attachment preview unavailable")
            }
        }

        mutating func append(_ entity: RawTranscriptJSON, suffix: String, role: String, text: String,
                             nativeID: String? = nil, toolName: String? = nil, input: String? = nil,
                             output: String? = nil, parentTool: String? = nil, isError: Bool? = nil, context: String? = nil,
                             sourceContent: String? = nil, rawOnly: Bool = false) {
            guard let identity = entity["entity_id"].string ?? entity["item_id"].string else { return }
            let message = Message(role: role, text: text, toolName: toolName, toolInput: input, toolOutput: output,
                eventID: nativeID, parentToolUseID: parentTool, sourceTurnID: entity["native_turn_id"].string,
                sourceRecordType: entity["item_id"].string == nil ? "agent_history" : "agent_live",
                sourceContent: sourceContent,
                toolResultIsError: isError, contextLabel: context)
            records.append(TranscriptRecord(recordID: "runtime:\(identity):\(suffix)", record: message,
                                            rawJSON: try? entity.prettyPrinted(), isRawOnly: rawOnly))
        }
    }
}

extension RawTranscriptJSON {
    subscript(_ key: String) -> Self {
        if case .object(let object) = self { return object[key] ?? .null }
        return .null
    }
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var array: [Self] { if case .array(let value) = self { return value }; return [] }
    var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    var integer: Int { if case .number(let value) = self { return NSDecimalNumber(decimal: value).intValue }; return 0 }
    var jsonText: String? { if case .null = self { return nil }; return try? prettyPrinted() }
}
