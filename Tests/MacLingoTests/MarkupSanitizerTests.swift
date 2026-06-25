import AppKit
import XCTest

@testable import MacLingo

/// Trust-boundary coverage for `MarkupSanitizer` (spec §5.4): the HTML tokenizer
/// strips remote resources / scripts / disallowed attributes and never fetches;
/// the RTF path drops attachments/links/colors and keeps only allowlisted traits;
/// caps reject pathological input (caller then degrades to plain).
final class MarkupSanitizerTests: XCTestCase {

    // MARK: - HTML: allowlisted styling survives

    func testHTMLExtractsAllowlistedInlineStyles() throws {
        let html = "<p>plain <b>bold</b> <i>italic</i> <u>under</u> <code>mono</code></p>"
        let formatted = try XCTUnwrap(MarkupSanitizer.formattedText(fromHTML: html))
        XCTAssertEqual(formatted.blocks.count, 1)
        let runs = formatted.blocks[0].runs
        XCTAssertEqual(runs.first { $0.text == "bold" }?.style, .bold)
        XCTAssertEqual(runs.first { $0.text == "italic" }?.style, .italic)
        XCTAssertEqual(runs.first { $0.text == "under" }?.style, .underline)
        XCTAssertEqual(runs.first { $0.text == "mono" }?.style, .code)
    }

    func testHTMLNestedStylesCombine() throws {
        let formatted = try XCTUnwrap(MarkupSanitizer.formattedText(fromHTML: "<b><i>x</i></b>"))
        XCTAssertEqual(formatted.blocks[0].runs[0].style, [.bold, .italic])
    }

    func testHTMLStrongAndEmAliasBoldItalic() throws {
        let formatted = try XCTUnwrap(
            MarkupSanitizer.formattedText(fromHTML: "<strong>a</strong><em>b</em>"))
        XCTAssertEqual(formatted.blocks[0].runs.first { $0.text == "a" }?.style, .bold)
        XCTAssertEqual(formatted.blocks[0].runs.first { $0.text == "b" }?.style, .italic)
    }

    // MARK: - HTML: structure

    func testHTMLBlocksAndLineBreaks() throws {
        let formatted = try XCTUnwrap(MarkupSanitizer.formattedText(fromHTML: "<p>one</p><p>two<br>three</p>"))
        XCTAssertEqual(formatted.blocks.map(\.text), ["one", "two", "three"])
    }

    func testHTMLListsCarryLevelAndOrdering() throws {
        let html = "<ul><li>a</li><li>b</li></ul><ol><li>c</li></ol>"
        let formatted = try XCTUnwrap(MarkupSanitizer.formattedText(fromHTML: html))
        XCTAssertEqual(formatted.blocks.map(\.text), ["a", "b", "c"])
        XCTAssertEqual(formatted.blocks[0].kind, .listItem(level: 1, ordered: false))
        XCTAssertEqual(formatted.blocks[2].kind, .listItem(level: 1, ordered: true))
    }

    // MARK: - HTML: trust boundary

    func testHTMLDropsScriptContentEntirely() throws {
        let html = "<p>safe<script>alert('x')</script> tail</p>"
        let formatted = try XCTUnwrap(MarkupSanitizer.formattedText(fromHTML: html))
        XCTAssertFalse(formatted.plainText.contains("alert"))
        XCTAssertTrue(formatted.plainText.contains("safe"))
        XCTAssertTrue(formatted.plainText.contains("tail"))
    }

    func testHTMLStripsRemoteResourcesAndKeepsNoURL() throws {
        let html = """
            <p>see <img src="https://evil.example/x.png"> and \
            <a href="https://evil.example">link</a> <object data="http://x"></object></p>
            """
        let formatted = try XCTUnwrap(MarkupSanitizer.formattedText(fromHTML: html))
        let text = formatted.plainText
        XCTAssertFalse(text.contains("http"), "no remote URL may survive sanitization")
        XCTAssertFalse(text.contains("evil"))
        XCTAssertTrue(text.contains("link"), "anchor text is kept, the href is dropped")
    }

    func testHTMLDropsDisallowedAttributesAndStyle() throws {
        let html = "<p style=\"color:red\" onclick=\"steal()\"><b class=\"x\">hi</b></p>"
        let formatted = try XCTUnwrap(MarkupSanitizer.formattedText(fromHTML: html))
        XCTAssertEqual(formatted.blocks[0].runs[0].text, "hi")
        XCTAssertEqual(formatted.blocks[0].runs[0].style, .bold)
        XCTAssertFalse(formatted.plainText.contains("color"))
        XCTAssertFalse(formatted.plainText.contains("steal"))
    }

    func testHTMLDecodesEntities() throws {
        let formatted = try XCTUnwrap(
            MarkupSanitizer.formattedText(fromHTML: "<p>a &amp; b &lt;tag&gt; &#39;q&#39;</p>"))
        XCTAssertEqual(formatted.plainText, "a & b <tag> 'q'")
    }

    func testHTMLOversizedInputRejected() {
        let huge = String(repeating: "a", count: MarkupSanitizer.maxCharacterCount + 1)
        XCTAssertNil(MarkupSanitizer.formattedText(fromHTML: huge))
    }

    func testHTMLDeeplyNestedRejected() {
        let depth = MarkupSanitizer.maxNestingDepth + 5
        let html = String(repeating: "<b>", count: depth) + "x" + String(repeating: "</b>", count: depth)
        XCTAssertNil(MarkupSanitizer.formattedText(fromHTML: html))
    }

    // MARK: - RTF: attachments/links/colors stripped, traits kept

    func testRTFKeepsBoldItalicDropsColor() throws {
        let attributed = NSMutableAttributedString(string: "normal ")
        let bold = NSMutableAttributedString(
            string: "loud",
            attributes: [
                .font: NSFontManager.shared.convert(
                    NSFont.systemFont(ofSize: 13), toHaveTrait: .boldFontMask),
                .foregroundColor: NSColor.red,
            ])
        attributed.append(bold)
        let data = try XCTUnwrap(
            attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]))

        let formatted = try XCTUnwrap(MarkupSanitizer.formattedText(fromRTF: data))
        XCTAssertEqual(formatted.plainText, "normal loud")
        XCTAssertEqual(formatted.blocks[0].runs.first { $0.text == "loud" }?.style, .bold)
        // Color is not part of the model at all — only the trait survives.
    }

    func testRTFDropsAttachments() throws {
        let attributed = NSMutableAttributedString(string: "before ")
        let attachment = NSTextAttachment()
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        attachment.image = image
        attributed.append(NSAttributedString(attachment: attachment))
        attributed.append(NSAttributedString(string: " after"))
        let data = try XCTUnwrap(
            attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]))

        let formatted = try XCTUnwrap(MarkupSanitizer.formattedText(fromRTF: data))
        // The object-replacement character carried by the attachment must be gone.
        XCTAssertFalse(formatted.plainText.contains("\u{FFFC}"))
        XCTAssertTrue(formatted.plainText.contains("before"))
        XCTAssertTrue(formatted.plainText.contains("after"))
    }

    func testRTFSplitsBlocksOnNewlines() throws {
        let attributed = NSAttributedString(string: "line one\nline two")
        let data = try XCTUnwrap(
            attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]))
        let formatted = try XCTUnwrap(MarkupSanitizer.formattedText(fromRTF: data))
        XCTAssertEqual(formatted.blocks.map(\.text), ["line one", "line two"])
    }
}
