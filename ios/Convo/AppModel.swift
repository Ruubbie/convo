import SwiftUI
import Observation

@MainActor @Observable
final class AppModel {
    private(set) var server = UserDefaults.standard.string(forKey: "server") ?? ""
    // The UserDefaults fallback picks up a `-token` launch argument (used by the screenshot workflow).
    private(set) var token = Keychain.read("token") ?? UserDefaults.standard.string(forKey: "token") ?? ""

    var chats: [Chat] = []
    var messages: [String: [Message]] = [:]
    var hasEarlier: Set<String> = []
    var status: BridgeStatus?
    var live = false
    var connectionProblem: String?
    var lastError: String?
    var toast: Toast?
    var openChatId: String?
    var messagesPath: [String] = []

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let images = NSCache<NSString, UIImage>()
    @ObservationIgnored private var missingImages: Set<String> = []

    private let pageSize = 60

    var bridge: Bridge? { Bridge(server: server, token: token) }
    var isConfigured: Bool { bridge != nil }

    // MARK: Connection

    func saveSettings(server: String, token: String) {
        self.server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(self.server, forKey: "server")
        Keychain.save("token", self.token)
        chats = []; messages = [:]; status = nil; messagesPath = []
        images.removeAllObjects(); missingImages = []
        connect()
    }

    func connectIfNeeded() {
        if socket == nil { connect() }
    }

    func connect() {
        disconnect()
        guard let bridge else { return }
        let gen = generation
        let task = bridge.eventsSocket()
        socket = task
        task.resume()
        Task { await refresh() }
        Task { await listen(task, gen) }
    }

    func disconnect() {
        generation += 1
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        live = false
    }

    private func listen(_ task: URLSessionWebSocketTask, _ gen: Int) async {
        while gen == generation {
            do {
                let frame = try await task.receive()
                live = true
                connectionProblem = nil
                if case .string(let text) = frame,
                   let event = try? JSONDecoder().decode(BridgeEvent.self, from: Data(text.utf8)) {
                    handle(event)
                }
            } catch {
                guard gen == generation else { return }
                live = false
                try? await Task.sleep(for: .seconds(3))
                if gen == generation { connect() }
                return
            }
        }
    }

    private func handle(_ event: BridgeEvent) {
        switch event.type {
        case "message":
            guard let chat = event.chat, let message = event.message else { return }
            upsert(chat)
            if messages[chat.id] != nil, !messages[chat.id]!.contains(where: { $0.id == message.id }) {
                messages[chat.id]!.append(message)
                messages[chat.id]!.sort { $0.ts < $1.ts }
            }
            if openChatId == chat.id {
                if !message.fromMe { Task { await markRead(chat.id) } }
            } else if !message.fromMe {
                toast = Toast(chat: chat, message: message)
            }
        case "chat":
            if let chat = event.chat { upsert(chat) }
        case "status":
            status = event.status
        case "reload":
            Task { await refresh() }
        default:
            break
        }
    }

    private func upsert(_ chat: Chat) {
        if let i = chats.firstIndex(where: { $0.id == chat.id }) { chats[i] = chat } else { chats.append(chat) }
        chats.sort { $0.lastTs > $1.lastTs }
    }

    func refresh() async {
        guard let bridge else { return }
        do {
            let newChats: [Chat] = try await bridge.call("/api/chats")
            let newStatus: BridgeStatus = try await bridge.call("/api/status")
            chats = newChats
            status = newStatus
            connectionProblem = nil
            if let open = openChatId { await loadMessages(open) }
        } catch {
            connectionProblem = error.localizedDescription
        }
    }

    // MARK: Chats

    func loadMessages(_ chatId: String, earlier: Bool = false) async {
        guard let bridge else { return }
        var path = "/api/chats/\(Bridge.escape(chatId))/messages"
        if earlier, let first = messages[chatId]?.first { path += "?before=\(Int64(first.ts))" }
        do {
            let page: [Message] = try await bridge.call(path)
            messages[chatId] = earlier ? page + (messages[chatId] ?? []) : page
            if page.count >= pageSize { hasEarlier.insert(chatId) } else { hasEarlier.remove(chatId) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func markRead(_ chatId: String) async {
        guard let bridge, chats.first(where: { $0.id == chatId })?.unread ?? 0 > 0 else { return }
        if let chat: Chat = try? await bridge.call("/api/chats/\(Bridge.escape(chatId))/read", method: "POST") {
            upsert(chat)
        }
    }

    func send(_ text: String, image: Data? = nil, to chatId: String) async -> Bool {
        guard let bridge else { return false }
        var body: [String: Any] = ["text": text]
        if let image { body["image"] = image.base64EncodedString() }
        do {
            let message: Message = try await bridge.call("/api/chats/\(Bridge.escape(chatId))/messages", method: "POST", body: body)
            if messages[chatId]?.contains(where: { $0.id == message.id }) == false {
                messages[chatId]?.append(message)
            }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func startChat(network: Network, phone: String) async throws -> Chat {
        guard let bridge else { throw BridgeError(message: "Connect to your bridge first") }
        let chat: Chat = try await bridge.call("/api/chats", method: "POST", body: ["network": network.rawValue, "phone": phone])
        upsert(chat)
        return chat
    }

    // MARK: Linking accounts

    func whatsAppPairingCode(phone: String) async throws -> String {
        guard let bridge else { throw BridgeError(message: "Connect to your bridge first") }
        let out: [String: String] = try await bridge.call("/api/whatsapp/pair", method: "POST", body: ["phone": phone])
        return out["code"] ?? ""
    }

    func unlinkWhatsApp() async {
        do { _ = try await bridge?.data("/api/whatsapp/logout", method: "POST") } catch { lastError = error.localizedDescription }
    }

    func signalLinkCode() async throws -> UIImage {
        guard let bridge else { throw BridgeError(message: "Connect to your bridge first") }
        guard let image = UIImage(data: try await bridge.data("/api/signal/qr")) else {
            throw BridgeError(message: "The bridge did not return a QR code")
        }
        return image
    }

    // MARK: Images (avatars and photos need the token, so AsyncImage can't load them)

    func image(_ path: String) async -> UIImage? {
        if let cached = images.object(forKey: path as NSString) { return cached }
        guard let bridge, !missingImages.contains(path) else { return nil }
        guard let data = try? await bridge.data(path), let image = UIImage(data: data) else {
            missingImages.insert(path)
            return nil
        }
        images.setObject(image, forKey: path as NSString)
        return image
    }
}
