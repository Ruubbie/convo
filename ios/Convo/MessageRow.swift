import SwiftUI

struct MessageRow: View {
    let message: Message
    let chat: Chat
    /// First and last of a run of messages from the same person: the name goes on the first,
    /// the picture and the bubble's tail on the last.
    let firstOfRun: Bool
    let lastOfRun: Bool

    @Environment(AppModel.self) private var model
    @State private var viewingPhoto = false

    private static let quickReactions = ["❤️", "👍", "😂", "😮", "😢", "🙏"]
    private var time: String { When.time(message.date) }
    private var myReaction: String? { message.reactions?.first(where: \.fromMe)?.emoji }
    private var photoPath: String { "/api/media/\(Bridge.escape(message.id))" }
    private var inGroup: Bool { chat.isGroup && !message.fromMe }
    private var name: String { model.senderName(message) }
    private var nameColor: Color { .forName(message.senderId.flatMap { $0.isEmpty ? nil : $0 } ?? message.sender) }
    private var showsName: Bool { inGroup && firstOfRun && !name.isEmpty }
    private var shape: BubbleShape { BubbleShape(tail: lastOfRun ? (message.fromMe ? .right : .left) : nil) }
    private var fill: Color { message.fromMe ? .mine : .soft }
    private var textColor: Color { message.fromMe ? .mineText : .ink }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.fromMe { Spacer(minLength: 60) }
            if inGroup {
                SenderAvatar(message: message, name: name, color: nameColor, size: 34).opacity(lastOfRun ? 1 : 0)
            }
            bubbleWithReactions
            if !message.fromMe { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 6)
        .padding(.top, firstOfRun ? 8 : 0)
    }

    /// Reactions sit on the bubble's bottom edge; long-press the bubble to react.
    private var bubbleWithReactions: some View {
        VStack(alignment: message.fromMe ? .trailing : .leading, spacing: -6) {
            bubble
                .contentShape(.contextMenuPreview, shape)
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

    private var nameLabel: Text {
        Text(name).font(.system(size: 15, weight: .semibold)).foregroundStyle(nameColor)
    }

    @ViewBuilder private var bubble: some View {
        if let poll = message.poll {
            PollCard(message: message, poll: poll, time: time, header: showsName ? nameLabel : nil, shape: shape)
        } else if message.isImage {
            VStack(alignment: .leading, spacing: 0) {
                if showsName { nameLabel.lineLimit(1).padding(.horizontal, 11).padding(.top, 7).padding(.bottom, 5) }
                PhotoThumbnail(path: photoPath)
                    .overlay(alignment: .bottomTrailing) {
                        if message.text.isEmpty {
                            Text(time).font(.system(size: 12)).foregroundStyle(.white).monospacedDigit()
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(.black.opacity(0.35), in: Capsule()).padding(8)
                        }
                    }
                    .onTapGesture { viewingPhoto = true }
                    .accessibilityAddTraits(.isButton)
                    .fullScreenCover(isPresented: $viewingPhoto) { PhotoViewer(path: photoPath) }
                if !message.text.isEmpty { textContent.padding(.horizontal, 11).padding(.vertical, 7) }
            }
            .padding(3)
            .foregroundStyle(textColor)
            .background(fill, in: shape)
        } else if message.text.isEmojiOnly {
            VStack(alignment: .leading, spacing: 2) {
                if showsName { nameLabel.lineLimit(1) }
                Text(message.text).font(.system(size: 40))
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                if showsName { nameLabel.lineLimit(1) }
                textContent
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(textColor)
            .background(fill, in: shape)
        }
    }

    /// The time sits in the bubble's bottom corner: on the text's last line when it fits, below it when not.
    /// An invisible copy of it at the end of the text makes that room.
    private var textContent: some View {
        let stamp = Text(time).font(.system(size: 12)).monospacedDigit()
        return (Text(message.text).font(.system(size: 17)) + Text("    ") + stamp.foregroundStyle(.clear))
            .overlay(alignment: .bottomTrailing) { stamp.foregroundStyle(textColor.opacity(0.55)).padding(.bottom, -3) }
    }
}

/// A rounded bubble, with a small tail at the bottom corner on the last message of a run.
struct BubbleShape: Shape {
    enum Tail { case left, right }
    let tail: Tail?

    func path(in rect: CGRect) -> Path {
        let bubble = Path(roundedRect: rect, cornerRadius: 18, style: .continuous)
        guard let tail else { return bubble }
        var t = Path()
        t.move(to: CGPoint(x: rect.minX, y: rect.maxY - 16))
        t.addQuadCurve(to: CGPoint(x: rect.minX - 6, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY - 2))
        t.addLine(to: CGPoint(x: rect.minX + 18, y: rect.maxY))
        t.addLine(to: CGPoint(x: rect.minX + 18, y: rect.maxY - 16))
        t.closeSubpath()
        if tail == .right {
            // Mirror around the bubble's vertical center line.
            t = t.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.minX + rect.maxX, ty: 0))
        }
        return bubble.union(t)
    }
}

/// A group member's picture, or their initials on their name color.
struct SenderAvatar: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let name: String
    let color: Color
    let size: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(color)
                Text(name.initials).font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: message.senderId) {
            guard let id = message.senderId, !id.isEmpty else { return }
            image = await model.image("/api/people/\(Bridge.escape(id))/avatar")
        }
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
    /// The sender's name, in groups.
    var header: Text? = nil
    var shape = BubbleShape(tail: nil)

    @Environment(AppModel.self) private var model

    var body: some View {
        let total = poll.options.reduce(0) { $0 + $1.votes }
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if let header { header.lineLimit(1).padding(.bottom, 3) }
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
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 9)
        .frame(width: 270)
        .foregroundStyle(message.fromMe ? Color.mineText : Color.ink)
        .background(message.fromMe ? Color.mine : Color.soft, in: shape)
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
