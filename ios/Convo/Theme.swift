import SwiftUI
import CoreImage.CIFilterBuiltins

// MARK: Colors (taken from the HTML example, plus a dark variant)

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
    static let bg = Color(light: 0xF5F3F2, dark: 0x111111)
    static let soft = Color(light: 0xE9E6E4, dark: 0x262524)
    static let field = Color(light: 0xFAF9F8, dark: 0x1E1D1C)
    static let muted = Color(light: 0x6F6C6A, dark: 0x9A9794)
    static let ink = Color(light: 0x111111, dark: 0xF2F0EF)
    static let mine = Color(light: 0x1C1C1C, dark: 0xF2F0EF)
    static let mineText = Color(light: 0xFFFFFF, dark: 0x111111)

    /// Group members' names get one of these, always the same for the same person.
    private static let names: [Color] = [
        Color(light: 0xD43F4F, dark: 0xFF7A85), Color(light: 0x1E88C7, dark: 0x5CC2F2),
        Color(light: 0x109A84, dark: 0x3ED3B5), Color(light: 0xC9730E, dark: 0xF6AD4E),
        Color(light: 0x7E57D6, dark: 0xB792F7), Color(light: 0x3E9A2A, dark: 0x7DD15C),
        Color(light: 0xC2408F, dark: 0xF08BCB),
    ]
    static func forName(_ key: String) -> Color {
        // String.hashValue changes every launch, so sum the characters instead.
        names[key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFFFF } % names.count]
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Network {
    var color: Color { self == .whatsapp ? Color(light: 0x25D366, dark: 0x25D366) : Color(light: 0x3A76F0, dark: 0x3A76F0) }
}

// MARK: Dates

enum When {
    /// "9:41 AM", "Yesterday", "Tuesday", "Mar 4"
    static func short(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: .now)).day ?? 99
        if days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func day(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// One to three emoji and nothing else: shown large, without a bubble.
    var isEmojiOnly: Bool {
        let t = trimmed
        return !t.isEmpty && t.count <= 3 && t.allSatisfy { ch in
            guard let first = ch.unicodeScalars.first else { return false }
            return first.properties.isEmoji && (first.value > 0x238C || ch.unicodeScalars.count > 1)
        }
    }

    var initials: String {
        let words = split(separator: " ").filter { $0.first?.isLetter == true }
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
}

// MARK: Avatars and images

struct Avatar: View {
    @Environment(AppModel.self) private var model
    let chat: Chat
    var size: CGFloat = 66
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Initials(name: chat.name, size: size, group: chat.isGroup)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: chat.id) { image = await model.image("/api/chats/\(Bridge.escape(chat.id))/avatar") }
    }
}

struct Initials: View {
    let name: String
    var size: CGFloat = 34
    var group = false

    var body: some View {
        ZStack {
            Circle().fill(Color.soft)
            if group || name.initials.isEmpty {
                Image(systemName: group ? "person.2.fill" : "person.fill")
                    .font(.system(size: size * 0.4)).foregroundStyle(Color.muted)
            } else {
                Text(name.initials).font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(Color.ink)
            }
        }
        .frame(width: size, height: size)
    }
}

/// A photo in a chat: 250 pt wide and as tall as its shape needs, within limits.
struct PhotoThumbnail: View {
    @Environment(AppModel.self) private var model
    let path: String
    @State private var image: UIImage?
    @State private var failed = false

    private var height: CGFloat {
        guard let image, image.size.width > 0 else { return 170 }
        return min(max(250 * image.size.height / image.size.width, 140), 330)
    }

    var body: some View {
        ZStack {
            Color.soft
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if failed {
                Image(systemName: "photo").font(.system(size: 28)).foregroundStyle(Color.muted)
            } else {
                ProgressView()
            }
        }
        .frame(width: 250, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .task(id: path) {
            image = await model.image(path)
            failed = image == nil
        }
    }
}

/// Full-screen photo: pinch to zoom, share or save it, close with the button.
struct PhotoViewer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let path: String
    @State private var image: UIImage?
    @State private var zoom: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .scaleEffect(zoom)
                    .gesture(MagnifyGesture()
                        .onChanged { zoom = max(1, $0.magnification) }
                        .onEnded { _ in withAnimation(.spring(duration: 0.3)) { zoom = 1 } })
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .top) {
            HStack {
                Button { dismiss() } label: { overlayIcon("xmark") }.accessibilityLabel("Close")
                Spacer()
                if let image {
                    let photo = Image(uiImage: image)
                    ShareLink(item: photo, preview: SharePreview("Photo", image: photo)) { overlayIcon("square.and.arrow.up") }
                        .accessibilityLabel("Share")
                }
            }
            .padding(16)
        }
        .task { image = await model.image(path) }
    }

    private func overlayIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
            .frame(width: 44, height: 44).background(.white.opacity(0.18), in: Circle())
    }
}

func qrCode(_ text: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
          let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
    return UIImage(cgImage: cg)
}

extension UIImage {
    /// Photos go to the bridge as JPEG, at most 1600 px on the long side.
    func jpegForSending() -> Data? {
        let scale = min(1, 1600 / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format)
            .image { _ in draw(in: CGRect(origin: .zero, size: target)) }
            .jpegData(compressionQuality: 0.8)
    }
}

// MARK: Buttons

struct RoundIcon: View {
    let systemName: String
    var dark = false
    var size: CGFloat = 48

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.4, weight: .semibold))
            .frame(width: size, height: size)
            .foregroundStyle(dark ? Color.mineText : Color.ink)
            .background(dark ? Color.mine : Color.soft, in: Circle())
    }
}

struct PillButtonStyle: ButtonStyle {
    var primary = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .foregroundStyle(primary ? Color.mineText : Color.ink)
            .background(primary ? Color.mine : Color.soft, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
    }
}
