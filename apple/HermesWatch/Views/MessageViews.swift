import HermesCore
import SwiftUI
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

struct MessageRow: View {
    @EnvironmentObject private var settings: AppSettings
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .User:
            HStack {
                Spacer(minLength: 16)
                Text(message.text)
                    .font(.footnote)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.35)))
            }
        case .Hermes:
            if settings.markdown { MarkdownView(text: message.text) } else { Text(message.text).font(.footnote) }
        case .System:
            Text(message.text)
                .font(.caption2)
                .italic()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
    }
}

/// Block markdown from `WatchMarkdown`, inline styling via `AttributedString(markdown:)`.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(WatchMarkdown.parse(text).enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func inline(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

private struct BlockView: View {
    let block: MdBlock

    var body: some View {
        switch block {
        case .heading(let level, let t):
            Text(inline(t)).font(level <= 2 ? .headline : .subheadline.bold())
        case .paragraph(let t):
            Text(inline(t)).font(.footnote)
        case .bullet(let t, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(indent == 0 ? "•" : "◦")
                Text(inline(t))
            }
            .font(.footnote)
            .padding(.leading, CGFloat(indent) * 8)
        case .numbered(let n, let t):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(n).").monospacedDigit()
                Text(inline(t))
            }
            .font(.footnote)
        case .quote(let t):
            Text(inline(t))
                .font(.footnote.italic())
                .padding(.leading, 6)
                .overlay(alignment: .leading) { Rectangle().fill(.secondary).frame(width: 2) }
        case .code(let lang, let code):
            CodeBlockView(lang: lang, code: code)
        case .mermaid(let code):
            RemoteImageView(source: .mermaid(code), alt: "diagram")
        case .image(let alt, let target):
            RemoteImageView(source: .path(target), alt: alt)
        case .table(let lines):
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in Text(inline(l)).font(.caption2) }
            }
        case .hr:
            Divider()
        }
    }
}

/// Code is collapsed by default — a wall of mono text is unreadable at wrist size.
private struct CodeBlockView: View {
    let lang: String
    let code: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { open.toggle() } label: {
                Label("\(lang.isEmpty ? "code" : lang) · \(code.split(separator: "\n", omittingEmptySubsequences: false).count) lines",
                      systemImage: open ? "chevron.down" : "chevron.right")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            if open {
                ScrollView(.horizontal) {
                    Text(code).font(.system(size: 11, design: .monospaced)).fixedSize()
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.2)))
    }
}

/// Mermaid fences render on watchkit; image lines load through watchkit `/img` (gateway paths)
/// or direct (http URLs). Small in-memory cache so scrolling back doesn't refetch.
struct RemoteImageView: View {
    enum Source: Hashable {
        case mermaid(String)
        case path(String)
    }

    @EnvironmentObject private var settings: AppSettings
    let source: Source
    let alt: String
    @State private var image: PlatformImage?
    @State private var error = ""
    @State private var zoomed = false

    private static let cache = NSCache<NSString, PlatformImage>()

    private var key: String {
        switch source {
        case .mermaid(let c): return "m|\(c)"
        case .path(let p): return "i|\(p)"
        }
    }

    var body: some View {
        Group {
            if let image {
                platformImage(image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { zoomed = true }
            } else if !error.isEmpty {
                Label("\(alt) · \(error)", systemImage: "photo").font(.caption2).foregroundStyle(.secondary)
            } else {
                HStack { ProgressView(); Text(alt).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .task(id: "\(key)|\(settings.watchkitBase)|\(settings.watchkitToken)") { await load() }
        .sheet(isPresented: $zoomed) {
            if let image {
                ScrollView([.horizontal, .vertical]) { platformImage(image) }
            }
        }
    }

    private func platformImage(_ img: PlatformImage) -> Image {
        #if canImport(UIKit)
        Image(uiImage: img)
        #else
        Image(nsImage: img)
        #endif
    }

    private func load() async {
        if let hit = Self.cache.object(forKey: key as NSString) { image = hit; return }
        do {
            let wk = settings.watchkit
            let data: Data
            switch source {
            case .mermaid(let code): data = try await wk.renderMermaid(code)
            case .path(let p): data = try await wk.image(p, width: 400)
            }
            guard let img = PlatformImage(data: data) else { error = "decode failed"; return }
            Self.cache.setObject(img, forKey: key as NSString)
            image = img
            error = ""
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription.map { String($0.prefix(60)) } ?? "unavailable"
        }
    }
}
