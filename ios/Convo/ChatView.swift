import SwiftUI
import PhotosUI

struct ChatView: View {
    let chatId: String

    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var sending = false
    @State private var photo: PhotosPickerItem?

    private var chat: Chat? { model.chats.first { $0.id == chatId } }
    private var messages: [Message] { model.messages[chatId] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if model.hasEarlier.contains(chatId) {
                            Button("Load earlier messages") { Task { await model.loadMessages(chatId, earlier: true) } }
                                .font(.footnote.weight(.semibold)).foregroundStyle(Color.muted).padding(.vertical, 6)
                        }
                        if let chat {
                            ForEach(Array(messages.enumerated()), id: \.element.id) { i, message in
                                let previous = i > 0 ? messages[i - 1] : nil
                                if previous.map({ !Calendar.current.isDate($0.date, inSameDayAs: message.date) }) ?? true {
                                    Text(When.day(message.date)).font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.muted).padding(.top, 6)
                                }
                                MessageRow(message: message, chat: chat,
                                           firstOfRun: previous?.fromMe != message.fromMe || previous?.sender != message.sender)
                                    .id(message.id)
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.last?.id) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
            composer
        }
        .background(Color.bg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.bg, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let chat {
                    HStack(spacing: 10) {
                        Avatar(chat: chat, size: 36, badge: false)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(chat.name).font(.system(size: 17, weight: .bold)).lineLimit(1)
                            Text(chat.isGroup ? "\(chat.network.title) group" : chat.network.title)
                                .font(.system(size: 13)).foregroundStyle(Color.muted)
                        }
                    }
                }
            }
        }
        .task {
            model.openChatId = chatId
            await model.loadMessages(chatId)
            await model.markRead(chatId)
        }
        .onDisappear { if model.openChatId == chatId { model.openChatId = nil } }
        .onChange(of: photo) { _, item in
            if let item { Task { await sendPhoto(item) } }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            PhotosPicker(selection: $photo, matching: .images) { RoundIcon(systemName: "plus", size: 50) }
                .accessibilityLabel("Send a photo")
                .disabled(sending)
            TextField("Type a message...", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(Color.field, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            Button { Task { await sendText() } } label: {
                if sending {
                    ProgressView().tint(Color.mineText).frame(width: 50, height: 50).background(Color.mine, in: Circle())
                } else {
                    RoundIcon(systemName: "arrow.up", dark: true, size: 50)
                }
            }
            .accessibilityLabel("Send")
            .disabled(text.trimmed.isEmpty || sending)
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
    }

    private func sendText() async {
        let body = text.trimmed
        guard !body.isEmpty else { return }
        sending = true
        if await model.send(body, to: chatId) { text = "" }
        sending = false
    }

    private func sendPhoto(_ item: PhotosPickerItem) async {
        photo = nil
        guard let data = try? await item.loadTransferable(type: Data.self),
              let jpeg = UIImage(data: data)?.jpegForSending() else {
            model.lastError = "Couldn't read that photo."
            return
        }
        sending = true
        if await model.send(text.trimmed, image: jpeg, to: chatId) { text = "" }
        sending = false
    }
}

struct MessageRow: View {
    let message: Message
    let chat: Chat
    let firstOfRun: Bool

    private var time: String { When.time(message.date) }

    var body: some View {
        if message.fromMe {
            HStack {
                Spacer(minLength: 60)
                bubble
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if chat.isGroup && firstOfRun && !message.sender.isEmpty {
                    Text(message.sender).font(.system(size: 13.5)).foregroundStyle(Color.muted).padding(.leading, 46).padding(.top, 6)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    Group {
                        if chat.isGroup { Initials(name: message.sender, size: 36) } else { Avatar(chat: chat, size: 36, badge: false) }
                    }
                    .opacity(firstOfRun ? 1 : 0)
                    bubble
                    if !message.isImage {
                        Text(time).font(.system(size: 12)).foregroundStyle(Color.muted).monospacedDigit().padding(.bottom, 12)
                    }
                    Spacer(minLength: 30)
                }
            }
        }
    }

    @ViewBuilder private var bubble: some View {
        if message.isImage {
            VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 6) {
                RemoteImage(path: "/api/media/\(Bridge.escape(message.id))")
                    .frame(width: 250, height: 170)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        Text(time).font(.system(size: 13)).foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 3).padding(.horizontal, 14).padding(.vertical, 10)
                    }
                if !message.text.isEmpty { textBubble }
            }
        } else if message.text.isEmojiOnly {
            Text(message.text).font(.system(size: 40))
        } else {
            textBubble
        }
    }

    private var textBubble: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            Text(message.text).font(.system(size: 16.5)).textSelection(.enabled)
            if message.fromMe && !message.isImage {
                Text(time).font(.system(size: 12)).opacity(0.75).monospacedDigit()
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .foregroundStyle(message.fromMe ? Color.mineText : Color.ink)
        .background(message.fromMe ? Color.mine : Color.soft, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}
