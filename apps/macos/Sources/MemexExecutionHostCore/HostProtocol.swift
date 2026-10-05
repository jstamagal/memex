import Foundation

public enum HostValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([HostValue]), object([String: HostValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([HostValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: HostValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public subscript(_ key: String) -> HostValue {
        if case .object(let value) = self { return value[key] ?? .null }; return .null
    }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public var array: [HostValue] { if case .array(let v) = self { return v }; return [] }
    public var object: [String: HostValue] { if case .object(let v) = self { return v }; return [:] }
    public static func encoded<T: Encodable>(_ value: T) throws -> HostValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(Self.self, from: encoder.encode(value))
    }
}

public struct HostRequest: Codable, Sendable {
    public var id: HostValue
    public var method: String
    public var params: [String: HostValue]
    public init(id: HostValue = .null, method: String, params: [String: HostValue] = [:]) {
        self.id = id; self.method = method; self.params = params
    }
}

public struct HostResponse: Codable, Sendable {
    public var id: HostValue
    public var result: HostValue?
    public var error: HostFailure?
    public init(id: HostValue, result: HostValue? = nil, error: HostFailure? = nil) {
        self.id = id; self.result = result; self.error = error
    }
}

public struct HostFailure: Error, Codable, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public var errorDescription: String? { message }
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

public struct HostedConversation: Codable, Equatable, Sendable {
    public var id: String
    public var nativeSessionID: String
    public var provider: String
    public var providerInstanceID: String
    public var workspaceID: String
    public var cwd: String
    public var transcriptPath: String?
    public var title: String
    public var parentID: String?
    public var createdAt: String
}

public struct HostedCommand: Codable, Equatable, Sendable {
    public var id: String
    public var issuedAt: String
    public var conversationID: String
    public var action: String
    public var text: String
    public var optionID: String?
    public var requestID: String?
    public var promptContent: HostValue?
}

/// Process execution stays in SQACPHost. Test implementations supply provider events,
/// not a second implementation of native protocol behavior.
public protocol ExecutionProvider: AnyObject {
    var providers: [String] { get }
    func create(id: String, provider: String, workspaceID: String, cwd: String, title: String) throws -> HostedConversation
    func resume(_ conversation: HostedConversation) throws
    func importConversation(id: String, provider: String, nativeSessionID: String, sourcePath: String,
                            workspaceID: String, cwd: String, title: String) throws -> HostedConversation
    func read(_ conversation: HostedConversation) throws -> HostValue
    func perform(_ command: HostedCommand) throws -> HostValue
    func isConnected(_ id: String) -> Bool
}

extension ExecutionProvider {
    public func importConversation(id: String, provider: String, nativeSessionID: String, sourcePath: String,
                                   workspaceID: String, cwd: String, title: String) throws -> HostedConversation {
        throw HostFailure("capability_unavailable", "This provider does not support importing native sessions")
    }
}
