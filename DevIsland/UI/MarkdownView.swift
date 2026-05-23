import SwiftUI
import Textual

private struct CompactHeadingStyle: StructuredText.HeadingStyle {
    // H1~H6 fontScale — default값(2.35, 1.88, ...)보다 작게 조정
    private static let fontScales: [CGFloat] = [1.3, 1.15, 1.05, 1.0, 1.0, 1.0]

    func makeBody(configuration: Configuration) -> some View {
        let level = min(configuration.headingLevel, 6)
        configuration.label
            .textual.fontScale(Self.fontScales[level - 1])
            .textual.blockSpacing(.fontScaled(top: 1.2, bottom: 0.6))
            .fontWeight(.semibold)
    }
}

struct MarkdownView: View {
    let text: String

    var body: some View {
        StructuredText(markdown: text)
            .textual.imageAttachmentLoader(BlockedAttachmentLoader())
            .textual.emojiAttachmentLoader(BlockedAttachmentLoader())
            .environment(\.openURL, OpenURLAction { _ in .discarded })
            .textual.headingStyle(CompactHeadingStyle())
            .textual.structuredTextStyle(.default)
            .textual.inlineStyle(
                InlineStyle()
                    .strong(.fontWeight(.bold))
                    .emphasis(.italic)
                    .code(.monospaced, .fontScale(0.9))
            )
            .textual.textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.white.opacity(0.9))
            .font(.system(size: 13, weight: .medium))
    }
}

// MARK: - Diff-Aware Markdown View

struct DiffAwareMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parseSegments(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .markdown(let s):
                    MarkdownView(text: s)
                case .diff(let s):
                    DiffBlockView(text: s)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum MessageSegment {
    case markdown(String)
    case diff(String)
}

private func parseSegments(_ text: String) -> [MessageSegment] {
    var result: [MessageSegment] = []
    var remaining = text

    while !remaining.isEmpty {
        if let fenceStart = remaining.range(of: "```diff\n"),
           let fenceEnd = remaining.range(of: "\n```", range: fenceStart.upperBound..<remaining.endIndex) {
            let before = String(remaining[remaining.startIndex..<fenceStart.lowerBound])
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.markdown(before))
            }
            let diffContent = String(remaining[fenceStart.upperBound..<fenceEnd.lowerBound])
            result.append(.diff(diffContent))
            remaining = String(remaining[fenceEnd.upperBound...])
        } else {
            result.append(.markdown(remaining))
            break
        }
    }

    return result.isEmpty ? [.markdown(text)] : result
}

private struct DiffBlockView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                diffLine(line)
            }
        }
        .font(.system(size: 11, weight: .regular, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }

    @ViewBuilder
    private func diffLine(_ line: String) -> some View {
        if line.hasPrefix("+") {
            Text(line)
                .foregroundStyle(Color(red: 0.45, green: 1.0, blue: 0.55))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 1)
                .background(Color.green.opacity(0.12))
        } else if line.hasPrefix("-") {
            Text(line)
                .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.42))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 1)
                .background(Color.red.opacity(0.12))
        } else {
            Text(line.isEmpty ? " " : line)
                .foregroundStyle(Color.white.opacity(0.45))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 1)
                .background(Color.white.opacity(0.03))
        }
    }
}

// Blocks all remote image/emoji loading from untrusted hook payloads.
private struct BlockedAttachmentLoader: AttachmentLoader {
    struct NoAttachment: Textual.Attachment {
        typealias Body = EmptyView
        var description: String { "" }
        var body: EmptyView { EmptyView() }
        func sizeThatFits(_: ProposedViewSize, in _: TextEnvironmentValues) -> CGSize { .zero }
    }

    func attachment(for _: URL, text _: String, environment _: ColorEnvironmentValues) async -> NoAttachment {
        NoAttachment()
    }
}
