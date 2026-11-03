import AppKit
import SwiftUI

enum ReaderFont: String, CaseIterable, Identifiable {
    case newYork, charter, iowan, georgia, sans, avenir
    var id: Self { self }

    var name: String {
        switch self {
        case .newYork: "New York"
        case .charter: "Charter"
        case .iowan: "Iowan"
        case .georgia: "Georgia"
        case .sans: "San Francisco"
        case .avenir: "Avenir Next"
        }
    }

    var css: String {
        switch self {
        case .newYork: #"ui-serif, "New York", Georgia, serif"#
        case .charter: #"Charter, "Bitstream Charter", Georgia, serif"#
        case .iowan: #""Iowan Old Style", Georgia, serif"#
        case .georgia: "Georgia, serif"
        case .sans: #"-apple-system, "SF Pro Text", sans-serif"#
        case .avenir: #""Avenir Next", Avenir, sans-serif"#
        }
    }

    func font(size: CGFloat) -> Font {
        switch self {
        case .newYork: .system(size: size, design: .serif)
        case .sans: .system(size: size)
        case .charter: .custom("Charter", size: size)
        case .iowan: .custom("Iowan Old Style", size: size)
        case .georgia: .custom("Georgia", size: size)
        case .avenir: .custom("Avenir Next", size: size)
        }
    }
}

enum ReaderTheme: String, CaseIterable, Identifiable {
    case auto, paper, white, sepia, night
    var id: Self { self }

    struct Palette: Equatable {
        let bg, fg, muted, link: String
        let dark: Bool
    }

    var name: String {
        switch self {
        case .auto: "Sistem"
        case .paper: "Kâğıt"
        case .white: "Beyaz"
        case .sepia: "Sepya"
        case .night: "Gece"
        }
    }

    func palette(dark: Bool) -> Palette {
        switch self {
        case .auto: (dark ? ReaderTheme.night : .paper).palette(dark: dark)
        case .paper: Palette(bg: "#F7F3EB", fg: "#2B2825", muted: "#8C857A", link: "#9A3B26", dark: false)
        case .white: Palette(bg: "#FFFFFF", fg: "#1D1D1F", muted: "#8A8A8E", link: "#2463C4", dark: false)
        case .sepia: Palette(bg: "#F1E5CC", fg: "#4A3A28", muted: "#94806A", link: "#8A4B1F", dark: false)
        case .night: Palette(bg: "#1C1B1A", fg: "#D9D4CC", muted: "#8A857D", link: "#E0A27A", dark: true)
        }
    }
}

struct ReaderStyle: Equatable {
    var font: ReaderFont
    var size: Int
    var theme: ReaderTheme
    var systemDark: Bool

    var palette: ReaderTheme.Palette { theme.palette(dark: systemDark) }
    var backgroundColor: NSColor { NSColor(hex: palette.bg) }

    /// Values of the page's `--okm-*` CSS variables.
    var variables: [String: String] {
        let p = palette
        return [
            "bg": p.bg, "fg": p.fg, "muted": p.muted, "link": p.link,
            "font": font.css, "size": "\(size)px",
            "hl": p.dark ? "rgba(255, 196, 61, .30)" : "rgba(255, 210, 60, .55)",
            // Text selection; only text blocks paint it (see ReaderScript.css).
            "sel": p.dark ? "rgba(100, 160, 255, .32)" : "rgba(0, 122, 255, .20)",
        ]
    }

    /// The variables as a CSS rule, for pages built with this style already in place.
    var rootCSS: String {
        ":root{" + variables.sorted { $0.key < $1.key }.map { "--okm-\($0.key):\($0.value)" }.joined(separator: ";") + "}"
    }

    /// JavaScript that pushes this style into the page's CSS variables.
    var script: String {
        let json = (try? JSONSerialization.data(withJSONObject: variables)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "window.__okm && window.__okm.setStyle(\(json));"
    }
}

extension NSColor {
    convenience init(hex: String) {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }
}

extension Color {
    init(hex: String) { self.init(nsColor: NSColor(hex: hex)) }

    /// Muted brick red used for accents throughout the app.
    static let okmAccent = Color(red: 0.69, green: 0.28, blue: 0.20)
}

extension Notification.Name {
    static let okmHighlight = Notification.Name("okmHighlight")
}

/// The "Aa" popover: reader toggle, size, font and background theme.
struct TypographyPanel: View {
    @Binding var reader: Bool
    @Binding var font: ReaderFont
    @Binding var size: Int
    @Binding var theme: ReaderTheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Okuma modu", isOn: $reader)
                .toggleStyle(.switch)
                .controlSize(.small)

            Group {
                HStack(spacing: 0) {
                    sizeButton("A", fontSize: 12) { size = max(13, size - 1) }
                    Divider().frame(height: 16)
                    sizeButton("A", fontSize: 19) { size = min(32, size + 1) }
                }
                .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.6)))

                VStack(spacing: 0) {
                    ForEach(ReaderFont.allCases) { f in
                        Button { font = f } label: {
                            HStack {
                                Text(f.name).font(f.font(size: 14))
                                Spacer()
                                if f == font {
                                    Image(systemName: "checkmark").font(.caption.weight(.semibold))
                                }
                            }
                            .padding(.vertical, 5)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 10) {
                    ForEach(ReaderTheme.allCases) { t in
                        Button { theme = t } label: { swatch(t) }
                            .buttonStyle(.plain)
                            .help(t.name)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(!reader)
            .opacity(reader ? 1 : 0.4)
        }
        .padding(14)
        .frame(width: 230)
    }

    private func sizeButton(_ label: String, fontSize: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: fontSize, design: .serif))
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func swatch(_ t: ReaderTheme) -> some View {
        let p = t.palette(dark: colorScheme == .dark)
        let fill: AnyShapeStyle = t == .auto
            ? AnyShapeStyle(LinearGradient(stops: [
                .init(color: Color(hex: "#F7F3EB"), location: 0.5),
                .init(color: Color(hex: "#1C1B1A"), location: 0.5),
            ], startPoint: .topLeading, endPoint: .bottomTrailing))
            : AnyShapeStyle(Color(hex: p.bg))
        return ZStack {
            Circle().fill(fill)
            Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
            if t != .auto {
                Text("Aa").font(.system(size: 10, design: .serif)).foregroundStyle(Color(hex: p.fg))
            }
        }
        .frame(width: 30, height: 30)
        .padding(2)
        .overlay(Circle().strokeBorder(theme == t ? Color.okmAccent : .clear, lineWidth: 2))
    }
}
