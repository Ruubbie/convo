import Foundation

enum Network: String, Codable, CaseIterable, Identifiable {
    case whatsapp, signal
    var id: String { rawValue }
    var title: String { self == .whatsapp ? "WhatsApp" : "Signal" }
}

struct Chat: Codable, Identifiable, Hashable {
    let id: String
    let network: Network
    var name: String
    /// "+<digits>" for people, used to find their name in the iPhone's contacts.
    let phone: String?
    let isGroup: Bool
    var unread: Int
    var lastTs: Double
    var lastText: String
    var lastSender: String
    var lastFromMe: Bool

    /// `phone`, or for bridges that don't send it, the number in the id ("wa:<digits>@s.whatsapp.net", "sg:+<digits>").
    var number: String? {
        if let phone { return phone }
        let address = id.dropFirst(3)
        if id.hasPrefix("wa:"), address.hasSuffix("@s.whatsapp.net") { return String(address.prefix { $0 != "@" }) }
        if id.hasPrefix("sg:"), address.hasPrefix("+") { return String(address) }
        return nil
    }

    var lastDate: Date? { lastTs > 0 ? Date(timeIntervalSince1970: lastTs / 1000) : nil }
    var preview: String {
        if lastFromMe { return "You: " + lastText }
        if isGroup, let first = lastSender.split(separator: " ").first { return "\(first): \(lastText)" }
        return lastText
    }
}

struct Message: Codable, Identifiable, Hashable {
    let id: String
    let chatId: String
    let fromMe: Bool
    let sender: String
    let text: String
    let ts: Double
    let media: String?
    var reactions: [Reaction]?
    var poll: Poll?

    var date: Date { Date(timeIntervalSince1970: ts / 1000) }
    var isImage: Bool { media?.hasPrefix("image/") == true }
    var summary: String {
        if !text.isEmpty { return text }
        if let poll { return "📊 " + poll.question }
        return isImage ? "📷 Photo" : ""
    }
}

struct Reaction: Codable, Hashable {
    let emoji: String
    let fromMe: Bool
}

struct Poll: Codable, Hashable {
    struct Option: Codable, Hashable {
        let name: String
        let votes: Int
        let mine: Bool
    }
    let question: String
    let multi: Bool
    let options: [Option]
}

struct BridgeStatus: Codable {
    struct WhatsApp: Codable { var state: String; var qr: String?; var me: String? }
    struct Signal: Codable { var state: String; var number: String? }
    var whatsapp: WhatsApp
    var signal: Signal
}

/// Pushed by the bridge over the WebSocket: "message", "update" (reactions, votes), "chat", "status" or "reload".
struct BridgeEvent: Decodable {
    let type: String
    let chat: Chat?
    let message: Message?
    let status: BridgeStatus?
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let chat: Chat
    let message: Message
}
