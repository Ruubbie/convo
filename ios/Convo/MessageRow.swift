import SwiftUI

struct MessageRow: View {
    let message: Message
    let chat: Chat
    let firstOfRun: Bool

    @Environment(AppModel.self) private var model
    @State private var viewingPhoto = false

    private static let quickReactions = ["❤️", "👍", "😂", "😮", "😢", "🙏"]
    private var time: String { When.time(message.date) }
    private var myReaction: String? { message.reactions?.first(where: \.fromMe)?.emoji }
    private var photoPath: String { "/api/media/\(Bridge.escape(message.id))" }

    var body: some View {
        if message.fromMe {
            HStack {
                Spacer(minLength: 60)
                bubbleWithReactions
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if chat.isGroup && firstOfRun && !message.sender.isEmpty {
                    Text(message.sender).font(.system(size: 13.5)).foregroundStyle(Color.muted).padding(.leading, 46).padding(.top, 6)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    Group {
                        if chat.isGroup { Initials(name: message.sender, size: 36) } else { Avatar(chat: chat, size: 36) }
                    }
                    .opacity(firstOfRun ? 1 : 0)
                    bubbleWithReactions
                    if !message.isImage && message.poll == nil {
                        Text(time).font(.system(size: 12)).foregroundStyle(Color.muted).monospacedDigit().padding(.bottom, 12)
                    }
                    Spacer(minLength: 30)
                }
            }
        }
    }

    /// Reactions sit on the bubble's bottom edge; long-press the bubble to react.
    private var bubbleWithReactions: some View {
        VStack(alignment: message.fromMe ? .trailing : .leading, spacing: -6) {
            bubble
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 26, style: .continuous))
                .contextMenu { menu }
            if let reactions = message.reactions, !reactions.isEmpty {
                ReactionsBadge(reactions: reactions).padding(.horizontal, 12)
            }
        }
    }

    @ViewBuilder private var menu: some View {
        ForEach(Self.quickReactions, id: \.self) { emoji in
            Button(emoji == myReaction ? "\(emoji)  ✓" : emoji) {
                Task { await model.react(emoji == myReaction ? "" : emoji, to: message) }
            }
        }
        if !message.text.isEmpty {
            Divider()
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
        }
    }

    @ViewBuilder private var bubble: some View {
        if let poll = message.poll {
            PollCard(message: message, poll: poll, time: time)
        } else if message.isImage {
            VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 6) {
                PhotoThumbnail(path: photoPath)
                    .overlay(alignment: .bottomTrailing) {
                        Text(time).font(.system(size: 13)).foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 3).padding(.horizontal, 14).padding(.vertical, 10)
                    }
                    .onTapGesture { viewingPhoto = true }
                    .accessibilityAddTraits(.isButton)
                    .fullScreenCover(isPresented: $viewingPhoto) { PhotoViewer(path: photoPath) }
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
            Text(message.text).font(.system(size: 16.5))
            if message.fromMe && !message.isImage {
                Text(time).font(.system(size: 12)).opacity(0.75).monospacedDigit()
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .foregroundStyle(message.fromMe ? Color.mineText : Color.ink)
        .background(message.fromMe ? Color.mine : Color.soft, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

struct ReactionsBadge: View {
    let reactions: [Reaction]

    var body: some View {
        // Most used first; a count only when several people picked the same emoji.
        let counts = Dictionary(grouping: reactions, by: \.emoji).map { (emoji: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.emoji < $1.emoji }
        HStack(spacing: 3) {
            ForEach(counts, id: \.emoji) { item in
                Text(item.emoji).font(.system(size: 14))
                if item.count > 1 { Text("\(item.count)").font(.system(size: 12, weight: .semibold)).monospacedDigit() }
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .foregroundStyle(Color.ink)
        .background(Color.field, in: Capsule())
        .overlay(Capsule().stroke(Color.bg, lineWidth: 2))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reactions: " + reactions.map(\.emoji).joined(separator: " "))
    }
}

/// Tap an option to vote; tap your pick again to take it back.
struct PollCard: View {
    let message: Message
    let poll: Poll
    let time: String

    @Environment(AppModel.self) private var model

    var body: some View {
        let total = poll.options.reduce(0) { $0 + $1.votes }
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(poll.question).font(.system(size: 16.5, weight: .semibold))
                Text(poll.multi ? "Select one or more" : "Select one").font(.system(size: 13)).opacity(0.7)
            }
            ForEach(poll.options, id: \.name) { option in
                Button { Task { await model.vote(picked(after: option), on: message) } } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Image(systemName: option.mine ? "checkmark.circle.fill" : "circle").font(.system(size: 19))
                            Text(option.name).font(.system(size: 15.5)).multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Text("\(option.votes)").font(.system(size: 14)).monospacedDigit().opacity(0.8)
                        }
                        ProgressView(value: Double(option.votes), total: Double(max(total, 1)))
                            .tint(message.fromMe ? Color.mineText : Color.ink)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue("\(option.votes) votes" + (option.mine ? ", your pick" : ""))
            }
            Text(time).font(.system(size: 12)).opacity(0.75).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
        .frame(width: 270)
        .foregroundStyle(message.fromMe ? Color.mineText : Color.ink)
        .background(message.fromMe ? Color.mine : Color.soft, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func picked(after option: Poll.Option) -> [String] {
        let mine = poll.options.filter(\.mine).map(\.name)
        if option.mine { return mine.filter { $0 != option.name } }
        return poll.multi ? mine + [option.name] : [option.name]
    }
}

struct NewPollSheet: View {
    let chatId: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var options = ["", ""]
    @State private var multi = false
    @State private var busy = false

    private var filled: [String] { options.map(\.trimmed).filter { !$0.isEmpty } }
    private var ready: Bool { !question.trimmed.isEmpty && filled.count >= 2 && Set(filled).count == filled.count }

    var body: some View {
        NavigationStack {
            Form {
                Section("Question") {
                    TextField("Ask a question", text: $question, axis: .vertical)
                }
                Section("Options") {
                    ForEach(options.indices, id: \.self) { i in
                        TextField("Option \(i + 1)", text: $options[i])
                    }
                    // WhatsApp allows up to 12 options.
                    if options.count < 12 { Button("Add option", systemImage: "plus") { options.append("") } }
                }
                Toggle("Allow multiple answers", isOn: $multi)
            }
            .scrollContentBackground(.hidden)
            .background(Color.bg)
            .navigationTitle("New poll")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Send") { Task { await send() } }.disabled(!ready)
                    }
                }
            }
        }
    }

    private func send() async {
        busy = true
        if await model.sendPoll(question: question.trimmed, options: filled, multi: multi, to: chatId) { dismiss() }
        busy = false
    }
}
