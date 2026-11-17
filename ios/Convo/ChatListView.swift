import SwiftUI

/// The inbox (all chats, newest first) and the contacts tab (people, A–Z) share this screen.
struct ChatListView: View {
    enum Mode { case messages, contacts }
    let mode: Mode

    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var contactsPath: [String] = []
    @State private var showNewChat = false

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: mode == .messages ? $model.messagesPath : $contactsPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    search
                    if let banner { Text(banner).font(.footnote).foregroundStyle(Color.muted).padding(.horizontal, 32).padding(.bottom, 8) }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if mode == .messages { inbox } else { contacts }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .refreshable { await model.refresh() }
            .background(Color.bg)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { ChatView(chatId: $0) }
            .sheet(isPresented: $showNewChat) {
                NewChatSheet { chat in
                    if mode == .messages { model.messagesPath = [chat.id] } else { contactsPath = [chat.id] }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(mode == .messages ? "Messages" : "Contacts")
                .font(.system(size: 40, weight: .heavy)).tracking(-1.4)
            Spacer()
            Button { showNewChat = true } label: { RoundIcon(systemName: "plus") }
                .accessibilityLabel("New chat")
                .disabled(!model.isConfigured)
        }
        .padding(.leading, 32).padding(.trailing, 22).padding(.top, 16)
    }

    private var search: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .semibold))
            TextField("Search conversations...", text: $query).autocorrectionDisabled()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(Color.soft, in: Capsule())
        .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 12)
    }

    private var banner: String? {
        if !model.isConfigured { return nil }
        if let problem = model.connectionProblem { return "Can't reach your bridge: \(problem)" }
        return model.live ? nil : "Connecting…"
    }

    private func matches(_ chat: Chat) -> Bool {
        let q = query.trimmed
        return q.isEmpty || chat.name.localizedCaseInsensitiveContains(q) || chat.lastText.localizedCaseInsensitiveContains(q)
    }

    @ViewBuilder private var inbox: some View {
        let rows = model.chats.filter(matches)
        if rows.isEmpty {
            empty
        } else {
            ForEach(rows) { chat in
                NavigationLink(value: chat.id) { ChatRow(chat: chat) }.buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var contacts: some View {
        let people = model.chats.filter { !$0.isGroup && matches($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let groups = Dictionary(grouping: people) { String($0.name.prefix(1)).uppercased() }
        if people.isEmpty {
            empty
        } else {
            ForEach(groups.keys.sorted(), id: \.self) { letter in
                Text(letter).font(.system(size: 13, weight: .bold)).foregroundStyle(Color.muted)
                    .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
                ForEach(groups[letter]!) { chat in
                    NavigationLink(value: chat.id) {
                        HStack(spacing: 16) {
                            Avatar(chat: chat, size: 46)
                            Text(chat.name).font(.system(size: 17.5, weight: .semibold)).lineLimit(1)
                            Spacer()
                        }
                        .padding(.vertical, 8).padding(.horizontal, 10).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var empty: some View {
        Text(!model.isConfigured ? "Connect your bridge in Settings to see your chats."
             : !query.trimmed.isEmpty ? "Nothing matches “\(query.trimmed)”."
             : "No chats yet. Link WhatsApp or Signal in Settings, or start a new chat with +.")
            .font(.subheadline).foregroundStyle(Color.muted).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(.horizontal, 20).padding(.vertical, 40)
    }
}

struct ChatRow: View {
    let chat: Chat

    var body: some View {
        HStack(spacing: 16) {
            Avatar(chat: chat)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(chat.name).font(.system(size: 17.5, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if let date = chat.lastDate {
                        Text(When.short(date)).font(.system(size: 14)).foregroundStyle(Color.muted).monospacedDigit()
                    }
                }
                HStack(spacing: 8) {
                    Text(chat.preview).font(.system(size: 15.5)).foregroundStyle(Color.muted).lineLimit(1)
                    Spacer(minLength: 0)
                    if chat.unread > 0 {
                        Text("\(chat.unread)")
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Color.mineText)
                            .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
                            .background(Color.mine, in: Capsule())
                    }
                }
                .frame(minHeight: 20)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .contentShape(Rectangle())
    }
}

struct NewChatSheet: View {
    let onOpen: (Chat) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var network: Network = .whatsapp
    @State private var phone = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New chat").font(.system(size: 24, weight: .heavy))
            Picker("Network", selection: $network) {
                ForEach(Network.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField("Phone number, e.g. +31 6 1234 5678", text: $phone)
                .keyboardType(.phonePad).textContentType(.telephoneNumber)
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(Color.soft, in: Capsule())
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            Button {
                Task { await start() }
            } label: {
                if busy { ProgressView().tint(Color.mineText) } else { Text("Start chat") }
            }
            .buttonStyle(PillButtonStyle())
            .disabled(phone.trimmed.isEmpty || busy)
        }
        .padding(24)
        .presentationDetents([.height(330)])
        .presentationBackground(Color.bg)
    }

    private func start() async {
        busy = true
        defer { busy = false }
        do {
            let chat = try await model.startChat(network: network, phone: phone)
            dismiss()
            onOpen(chat)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
