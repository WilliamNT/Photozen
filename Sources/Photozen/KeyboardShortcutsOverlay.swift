import SwiftUI

struct KeyboardShortcutsOverlay: View {
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            // Dimming backdrop
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Keyboard Shortcuts")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 16)

                Divider()

                // Shortcut grid
                ScrollView {
                    VStack(spacing: 24) {
                        shortcutSection("Navigation", shortcuts: [
                            ("←  →", "Previous / Next photo"),
                            ("↑  ↓", "Move selection up / down"),
                            ("Space", "Open / close photo viewer"),
                            ("Return", "Open selected photo"),
                            ("Esc", "Close viewer / exit full screen"),
                        ])

                        shortcutSection("Viewing", shortcuts: [
                            ("F", "Toggle full screen (in viewer)"),
                            ("⌃⌘F", "Toggle full screen"),
                            ("⌘I", "Show / hide info panel"),
                            ("⌘+", "Zoom in"),
                            ("⌘−", "Zoom out"),
                            ("⌘0", "Actual size / reset zoom"),
                        ])

                        shortcutSection("Actions", shortcuts: [
                            ("⌘C", "Copy image to clipboard"),
                            ("⌘P", "Print image"),
                            ("⌘F", "Search photos"),
                            ("⌘⇧O", "Add folder to library"),
                            ("⌘R", "Refresh library"),
                            ("⌘⇧R", "Force recreate cache"),
                            ("⌘⌫", "Remove location from library"),
                        ])

                        shortcutSection("Viewer Gestures", shortcuts: [
                            ("Pinch", "Zoom in / out"),
                            ("Double-tap", "Smart zoom toggle"),
                            ("Swipe left / right", "Navigate photos"),
                            ("Drag down", "Dismiss viewer"),
                            ("Drag up", "Open info panel"),
                            ("⌘ / ⌥ + Scroll", "Zoom with mouse wheel"),
                        ])
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                }

                Divider()

                // Footer
                HStack {
                    Spacer()
                    Text("Press **?** to toggle this panel")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.vertical, 12)
            }
            .frame(width: 520, height: 540)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    @ViewBuilder
    private func shortcutSection(_ title: String, shortcuts: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                ForEach(Array(shortcuts.enumerated()), id: \.offset) { index, shortcut in
                    HStack {
                        Text(shortcut.0)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.primary)
                            .frame(width: 140, alignment: .trailing)

                        Text(shortcut.1)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)

                    if index < shortcuts.count - 1 {
                        Divider()
                            .padding(.leading, 152)
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5))
        }
    }
}
