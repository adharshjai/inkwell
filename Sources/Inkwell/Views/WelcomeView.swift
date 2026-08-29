import SwiftUI

/// Empty state: open, drop, start from paper, or reopen something recent.
struct WelcomeView: View {
    let appState: AppState

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 10) {
                Image(systemName: "pencil.and.outline")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(.tint)
                Text("Inkwell")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Fill out, work through, and turn in your problem sets.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            GlassEffectContainer(spacing: 16) {
                HStack(spacing: 12) {
                    Button {
                        appState.openViaPanel()
                    } label: {
                        Label("Open PDF…", systemImage: "folder")
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut("o")

                    Button {
                        appState.newNotesFlow()
                    } label: {
                        Label("New Notes", systemImage: "scribble.variable")
                            .frame(minWidth: 104)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: .capsule)
                    .keyboardShortcut("n")

                    Menu {
                        ForEach(PaperTemplate.allCases) { template in
                            Button {
                                appState.newDocument(template: template)
                            } label: {
                                Label(template.displayName, systemImage: template.systemImage)
                            }
                        }
                    } label: {
                        Label("New From Paper", systemImage: "doc.badge.plus")
                            .frame(minWidth: 124)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .contentShape(Capsule())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: .capsule)
                }
            }

            Text("…or drop a PDF anywhere in this window. In Notes: hold F and glide to draw, S snaps shapes clean, W routes wires.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            if !appState.recents.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(appState.recents.prefix(5), id: \.path) { url in
                        Button {
                            appState.openDocument(at: url)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.richtext")
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(url.deletingPathExtension().lastPathComponent)
                                        .font(.callout)
                                        .lineLimit(1)
                                    Text(url.deletingLastPathComponent().path)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .frame(width: 380)
            }

            Spacer()
            Spacer()

            Text("Inkwell \(AppInfo.version)")
                .font(.caption2)
                .foregroundStyle(.quaternary)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowBackgroundShapeStyle.windowBackground)
    }
}

enum AppInfo {
    static let version = "2.10"
}
