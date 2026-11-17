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
    let isGroup: Bool
    var unread: Int
    var lastTs: Double
    var lastText: String
    var lastSender: String
    var lastFromMe: Bool

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

    var date: Date { Date(timeIntervalSince1970: ts / 1000) }
    var isImage: Bool { media?.hasPrefix("image/") == true }
}

struct BridgeStatus: Codable {
    struct WhatsApp: Codable { var state: String; var qr: String?; var me: String? }
    struct Signal: Codable { var state: String; var number: String? }
    var whatsapp: WhatsApp
    var signal: Signal
}

/// Pushed by the bridge over the WebSocket: "message", "chat", "status" or "reload".
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
