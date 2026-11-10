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

/// Light or dark for the whole app: every window, menu and panel.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }

    static let key = "appAppearance"

    var name: String {
        switch self {
        case .system: "Sistem"
        case .light: "Açık"
        case .dark: "Koyu"
        }
    }

    /// nil follows macOS.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

private struct AppearanceFollower: ViewModifier {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system
    @AppStorage(ReaderTheme.key) private var theme: ReaderTheme = .auto

    func body(content: Content) -> some View {
        content
            .onChange(of: appearance, initial: true) { apply() }
            .onChange(of: theme) { apply() }
    }

    /// A chosen color theme sets light or dark for the whole app; "Otomatik" leaves it to the setting.
    private func apply() {
        NSApp.appearance = theme == .auto
            ? appearance.nsAppearance
            : NSAppearance(named: theme.palette(dark: false).dark ? .darkAqua : .aqua)
    }
}

/// Paints a part of the window in the color theme: its background, and text in the theme's ink.
private struct ThemedSurface: ViewModifier {
    let surface: ReaderTheme.Surface
    @AppStorage(ReaderTheme.key) private var theme: ReaderTheme = .auto
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let palette = theme.palette(dark: colorScheme == .dark)
        content
            .scrollContentBackground(.hidden)
            .foregroundStyle(ThemeInk(color: Color(hex: palette.fg)))
            .background(Color(hex: palette.color(for: surface)).ignoresSafeArea())
    }
}

/// The theme's text color, white on a selected row so it stays readable on the highlight.
private struct ThemeInk: ShapeStyle {
    let color: Color

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        (environment.backgroundProminence == .increased ? Color.white : color).resolve(in: environment)
    }
}

extension View {
    /// Keeps the app's appearance in step with the setting while this view is on screen.
    func followsAppAppearance() -> some View { modifier(AppearanceFollower()) }

    /// Gives this part of the window the color theme's background and text color.
    func themed(_ surface: ReaderTheme.Surface) -> some View { modifier(ThemedSurface(surface: surface)) }
}

enum ReaderTheme: String, CaseIterable, Identifiable {
    case auto, paper, white, sepia, night
    var id: Self { self }

    static let key = "readerTheme"

    /// The parts of the window, each a shade of the theme: the page lightest, the sidebar deepest.
    enum Surface { case sidebar, list, page }

    struct Palette: Equatable {
        let bg, fg, muted, link: String
        let dark: Bool
        /// Backgrounds of the middle list and the sidebar.
        let list, side: String

        func color(for surface: Surface) -> String {
            switch surface {
            case .sidebar: side
            case .list: list
            case .page: bg
            }
        }
    }

    var name: String {
        switch self {
        case .auto: "Otomatik"
        case .paper: "Kâğıt"
        case .white: "Beyaz"
        case .sepia: "Sepya"
        case .night: "Gece"
        }
    }

    func palette(dark: Bool) -> Palette {
        switch self {
        case .auto: (dark ? ReaderTheme.night : .paper).palette(dark: dark)
        case .paper: Palette(bg: "#F7F3EB", fg: "#2B2825", muted: "#8C857A", link: "#2F5FAF", dark: false,
                             list: "#F2EDE3", side: "#E9E2D5")
        case .white: Palette(bg: "#FFFFFF", fg: "#1D1D1F", muted: "#8A8A8E", link: "#2463C4", dark: false,
                             list: "#FAFAFA", side: "#F0F0F2")
        case .sepia: Palette(bg: "#F1E5CC", fg: "#4A3A28", muted: "#94806A", link: "#36598F", dark: false,
                             list: "#ECDFC3", side: "#E2D1B0")
        case .night: Palette(bg: "#1C1B1A", fg: "#D9D4CC", muted: "#8A857D", link: "#8AB4F8", dark: true,
                             list: "#21201E", side: "#171615")
        }
    }
}

struct ReaderStyle: Equatable {
    var font: ReaderFont
    var size: Int
    var theme: ReaderTheme
    /// Whether the window is dark; decides what the "Otomatik" theme shows.
    var windowDark: Bool

    var palette: ReaderTheme.Palette { theme.palette(dark: windowDark) }
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

    /// Calm blue behind controls such as switches and prominent buttons.
    static let okmTint = Color(red: 0.18, green: 0.42, blue: 0.85)

    /// The same blue for text and small marks, lighter on dark backgrounds to stay readable.
    static let okmAccent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.45, green: 0.66, blue: 1, alpha: 1)
            : NSColor(srgbRed: 0.18, green: 0.42, blue: 0.85, alpha: 1)
    })
}

/// "2 gün önce", through one shared formatter: rows ask for this while scrolling.
enum RelativeDate {
    @MainActor private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.dateTimeStyle = .named
        f.unitsStyle = .full
        return f
    }()

    @MainActor static func string(_ date: Date) -> String {
        formatter.localizedString(for: date, relativeTo: Date())
    }
}

extension Notification.Name {
    static let okmHighlight = Notification.Name("okmHighlight")
    static let okmNote = Notification.Name("okmNote")
    static let okmFind = Notification.Name("okmFind")
    static let okmSearch = Notification.Name("okmSearch")
    static let okmPanel = Notification.Name("okmPanel")
    static let okmFocus = Notification.Name("okmFocus")
}
