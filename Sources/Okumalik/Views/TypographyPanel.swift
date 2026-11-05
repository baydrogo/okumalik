import SwiftUI

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
