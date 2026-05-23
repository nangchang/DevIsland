import SwiftUI
import Textual

struct MarkdownView: View {
    let text: String

    var body: some View {
        StructuredText(markdown: text)
            .textual.imageAttachmentLoader(BlockedAttachmentLoader())
            .textual.emojiAttachmentLoader(BlockedAttachmentLoader())
            .environment(\.openURL, OpenURLAction { _ in .discarded })
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

// Blocks all remote image/emoji loading from untrusted hook payloads.
private struct BlockedAttachmentLoader: AttachmentLoader {
    struct NoAttachment: Textual.Attachment {
        typealias Body = EmptyView
        var description: String { "" }
        var body: EmptyView { EmptyView() }
        func sizeThatFits(_: ProposedViewSize, in _: TextEnvironmentValues) -> CGSize { .zero }
    }

    func attachment(for _: URL, text _: String, environment _: ColorEnvironmentValues) async throws -> NoAttachment {
        throw URLError(.unsupportedURL)
    }
}
