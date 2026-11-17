import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var server = ""
    @State private var token = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.1.10:8080", text: $server)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Bridge token", text: $token)
                    Button(model.isConfigured ? "Save and reconnect" : "Connect") {
                        model.saveSettings(server: server, token: token)
                    }
                    .disabled(Bridge(server: server, token: token) == nil)
                } header: {
                    Text("Bridge")
                } footer: {
                    Text(connectionText)
                }

                if let status = model.status {
                    WhatsAppSection(status: status.whatsapp)
                    SignalSection(status: status.signal)
                }
            }
            .navigationTitle("Settings")
            .scrollContentBackground(.hidden)
            .background(Color.bg)
            .onAppear {
                server = model.server
                token = model.token
            }
        }
    }

    private var connectionText: String {
        if !model.isConfigured { return "The address and BRIDGE_TOKEN of your self-hosted Convo bridge." }
        if let problem = model.connectionProblem { return "Can't reach the bridge: \(problem)" }
        return model.live ? "Connected." : "Connecting…"
    }
}

private struct WhatsAppSection: View {
    let status: BridgeStatus.WhatsApp
    @Environment(AppModel.self) private var model
    @State private var phone = ""
    @State private var code: String?
    @State private var busy = false
    @State private var error: String?
    @State private var confirmUnlink = false

    var body: some View {
        Section {
            switch status.state {
            case "linked":
                LabeledContent("Linked as", value: status.me ?? "—")
                Button("Unlink WhatsApp", role: .destructive) { confirmUnlink = true }
                    .confirmationDialog("Unlink WhatsApp from the bridge?", isPresented: $confirmUnlink, titleVisibility: .visible) {
                        Button("Unlink", role: .destructive) { Task { await model.unlinkWhatsApp() } }
                    }
            case "qr":
                if let qr = status.qr, let image = qrCode(qr) {
                    QRBlock(image: image, caption: "Scan with WhatsApp on another phone: Settings → Linked devices → Link a device.")
                }
                Text("Using WhatsApp on this iPhone? Link with your number instead:").font(.subheadline)
                TextField("Your WhatsApp number, e.g. +31 6 1234 5678", text: $phone)
                    .keyboardType(.phonePad).textContentType(.telephoneNumber)
                Button {
                    Task { await getCode() }
                } label: {
                    if busy { ProgressView() } else { Text("Get pairing code") }
                }
                .disabled(phone.trimmed.isEmpty || busy)
                if let code {
                    VStack(spacing: 8) {
                        Text(code).font(.system(size: 34, weight: .bold, design: .monospaced)).textSelection(.enabled)
                        Text("In WhatsApp: Settings → Linked devices → Link a device → Link with phone number instead, then enter this code.")
                            .font(.footnote).foregroundStyle(Color.muted).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            default:
                HStack { ProgressView(); Text("Connecting to WhatsApp…").foregroundStyle(Color.muted) }
            }
        } header: {
            Label("WhatsApp", systemImage: "circle.fill").foregroundStyle(Network.whatsapp.color)
        }
    }

    private func getCode() async {
        busy = true
        defer { busy = false }
        do {
            let raw = try await model.whatsAppPairingCode(phone: phone)
            code = raw.count == 8 ? "\(raw.prefix(4))-\(raw.suffix(4))" : raw
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct SignalSection: View {
    let status: BridgeStatus.Signal
    @Environment(AppModel.self) private var model
    @State private var image: UIImage?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Section {
            switch status.state {
            case "linked":
                LabeledContent("Linked as", value: status.number ?? "—")
                Text("To unlink, remove “Convo” in Signal → Settings → Linked devices.")
                    .font(.footnote).foregroundStyle(Color.muted)
            case "unlinked":
                if let image {
                    QRBlock(image: image, caption: "Scan in Signal: Settings → Linked devices → Link new device. Signal can't scan its own screen, so share this code to another screen (AirDrop to a Mac or iPad) if Signal is on this iPhone.")
                    ShareLink(item: Image(uiImage: image), preview: SharePreview("Signal link code", image: Image(uiImage: image))) {
                        Label("Share QR code", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    Task { await load() }
                } label: {
                    if busy { ProgressView() } else { Text(image == nil ? "Show link QR code" : "New QR code") }
                }
                .disabled(busy)
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            default:
                HStack { ProgressView(); Text("Waiting for signal-cli…").foregroundStyle(Color.muted) }
            }
        } header: {
            Label("Signal", systemImage: "circle.fill").foregroundStyle(Network.signal.color)
        }
    }

    private func load() async {
        busy = true
        defer { busy = false }
        do {
            image = try await model.signalLinkCode()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct QRBlock: View {
    let image: UIImage
    let caption: String

    var body: some View {
        VStack(spacing: 10) {
            Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                .frame(width: 220, height: 220).padding(10).background(.white, in: RoundedRectangle(cornerRadius: 16))
            Text(caption).font(.footnote).foregroundStyle(Color.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 6)
    }
}
