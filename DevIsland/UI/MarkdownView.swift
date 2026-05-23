import SwiftUI
import Textual

struct MarkdownView: View {
    let text: String

    var body: some View {
        StructuredText(markdown: text)
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
            .font(.system(size: 13))
    }
}
