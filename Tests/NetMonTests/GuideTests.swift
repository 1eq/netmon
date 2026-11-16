import XCTest
@testable import NetMon

final class GuideTests: XCTestCase {
    func testParsesEachBlockKind() {
        let blocks = MarkdownBlock.parse("""
        # Title

        A paragraph
        over two lines.

        - one
        - two

        1. first
        2. second

        | A | B |
        |---|---|
        | `x\\|y` | 2 |

        ```
        code here
        ```
        """)
        guard blocks.count == 6 else { return XCTFail("got \(blocks.count) blocks: \(blocks)") }
        if case .heading(1, "Title", "title") = blocks[0] {} else { XCTFail("heading: \(blocks[0])") }
        if case .paragraph("A paragraph over two lines.") = blocks[1] {} else { XCTFail("paragraph: \(blocks[1])") }
        if case .list(["one", "two"], false) = blocks[2] {} else { XCTFail("bullets: \(blocks[2])") }
        if case .list(["first", "second"], true) = blocks[3] {} else { XCTFail("numbered: \(blocks[3])") }
        if case .table(["A", "B"], [["`x|y`", "2"]]) = blocks[4] {} else { XCTFail("table: \(blocks[4])") }
        if case .code("code here") = blocks[5] {} else { XCTFail("code: \(blocks[5])") }
    }

    func testSlugMatchesGitHubAnchors() {
        XCTAssertEqual(MarkdownBlock.slug("How bad hops are identified"), "how-bad-hops-are-identified")
        XCTAssertEqual(MarkdownBlock.slug("Claude, MCP and the CLI"), "claude-mcp-and-the-cli")
    }

    /// Every in-page link in the shipped guide must point at a heading that exists.
    func testGuideInPageLinksResolve() throws {
        let text = GuideDocument.load()
        XCTAssertFalse(text.hasPrefix("# Guide unavailable"), "docs/HOW-IT-WORKS.md not found")
        let anchors = Set(MarkdownBlock.parse(text).compactMap { block -> String? in
            if case .heading(_, _, let anchor) = block { return anchor }
            return nil
        })
        let regex = try NSRegularExpression(pattern: #"\]\(#([^)]+)\)"#)
        let links = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .map { String(text[Range($0.range(at: 1), in: text)!]) }
        XCTAssertFalse(links.isEmpty)
        for link in links { XCTAssertTrue(anchors.contains(link), "dead link #\(link)") }
    }
}
