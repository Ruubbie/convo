import SwiftUI

@main
struct ConvoApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onChange(of: phase) { _, phase in
                    // iOS suspends the WebSocket in the background; catch up when we come back.
                    if phase == .background { model.disconnect() }
                    if phase == .active {
                        model.connectIfNeeded()
                        Task { await model.loadContacts() }
                    }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            ChatListView(mode: .messages)
                .tabItem { Label("Messages", systemImage: "bubble.left.fill") }.tag(0)
            ChatListView(mode: .contacts)
                .tabItem { Label("Contacts", systemImage: "person.2.fill") }.tag(1)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(2)
        }
        .tint(Color.ink)
        .overlay(alignment: .top) {
            if let toast = model.toast {
                ToastView(toast: toast) {
                    model.toast = nil
                    tab = 0
                    model.messagesPath = [toast.chat.id]
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(4.5))
                    if model.toast?.id == toast.id { model.toast = nil }
                }
            }
        }
        .animation(.spring(duration: 0.35), value: model.toast)
        .alert("Something went wrong", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
        .task {
            if !model.isConfigured { tab = 2 }
            // Launch arguments for the screenshot workflow: `-tab 1` and `-open <chatId>`.
            let args = UserDefaults.standard
            if args.object(forKey: "tab") != nil { tab = args.integer(forKey: "tab") }
            if let open = args.string(forKey: "open") { model.messagesPath = [open] }
            model.connectIfNeeded()
            await model.loadContacts()
        }
    }
}

struct ToastView: View {
    let toast: Toast
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Avatar(chat: toast.chat, size: 42, badge: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(toast.chat.isGroup ? "\(toast.message.sender) · \(toast.chat.name)" : toast.chat.name)
                        .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(toast.message.summary)
                        .font(.system(size: 14)).foregroundStyle(Color.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 20, y: 10)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
    }
}
