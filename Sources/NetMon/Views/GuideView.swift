import SwiftUI

/// Renders docs/HOW-IT-WORKS.md, bundled into the app by scripts/build-app.sh.
struct GuideView: View {
    private static let blocks = MarkdownBlock.parse(GuideDocument.load())

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Self.blocks) { BlockView(block: $0) }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            // In-page links ("#section") scroll to that heading; everything else opens normally.
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == nil, let anchor = url.fragment ?? url.absoluteString.split(separator: "#").last.map(String.init)
                else { return .systemAction }
                withAnimation { proxy.scrollTo(anchor, anchor: .top) }
                return .handled
            })
        }
    }
}

enum GuideDocument {
    static func load() -> String {
        let candidates = [
            Bundle.main.url(forResource: "HOW-IT-WORKS", withExtension: "md"),
            // `swift run` / tests: read straight from the repo.
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../../docs/HOW-IT-WORKS.md").standardized,
        ]
        for case let url? in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        }
        return "# Guide unavailable\n\nThe guide wasn't bundled with this build. See `docs/HOW-IT-WORKS.md` in the repo."
    }
}

/// The subset of Markdown the guide uses: headings, paragraphs, flat lists, tables, code blocks.
enum MarkdownBlock: Identifiable {
    case heading(level: Int, text: String, anchor: String)
    case paragraph(String)
    case list(items: [String], numbered: Bool)
    case table(header: [String], rows: [[String]])
    case code(String)

    // Block positions are stable because the document never changes at runtime.
    var id: String {
        switch self {
        case .heading(_, _, let anchor): "h-\(anchor)"
        case .paragraph(let t): "p-\(t.hashValue)"
        case .list(let items, _): "l-\(items.hashValue)"
        case .table(let header, let rows): "t-\(header.hashValue)-\(rows.hashValue)"
        case .code(let t): "c-\(t.hashValue)"
        }
    }

    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var i = 0
        func isBlockStart(_ line: String) -> Bool {
            line.hasPrefix("#") || line.hasPrefix("|") || line.hasPrefix("```") || listItem(line) != nil
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                i += 1
            } else if trimmed.hasPrefix("```") {
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].hasPrefix("```") { code.append(lines[i]); i += 1 }
                i += 1
                blocks.append(.code(code.joined(separator: "\n")))
            } else if let level = trimmed.firstIndex(where: { $0 != "#" }).map({ trimmed.distance(from: trimmed.startIndex, to: $0) }),
                      level > 0, level <= 6, trimmed.dropFirst(level).first == " " {
                let title = String(trimmed.dropFirst(level + 1))
                blocks.append(.heading(level: level, text: title, anchor: slug(title)))
                i += 1
            } else if trimmed.hasPrefix("|") {
                var rows: [[String]] = []
                while i < lines.count, lines[i].hasPrefix("|") {
                    let cells = cellsOf(lines[i])
                    if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { rows.append(cells) }
                    i += 1
                }
                if let header = rows.first { blocks.append(.table(header: header, rows: Array(rows.dropFirst()))) }
            } else if let first = listItem(line) {
                var items = [first.text]
                i += 1
                while i < lines.count, let next = listItem(lines[i]), next.numbered == first.numbered {
                    items.append(next.text)
                    i += 1
                }
                blocks.append(.list(items: items, numbered: first.numbered))
            } else {
                var para = [trimmed]
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, !isBlockStart(lines[i]) {
                    para.append(lines[i].trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.paragraph(para.joined(separator: " ")))
            }
        }
        return blocks
    }

    private static func listItem(_ line: String) -> (text: String, numbered: Bool)? {
        if line.hasPrefix("- ") { return (String(line.dropFirst(2)), false) }
        if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
           line[line.index(after: dot)...].hasPrefix(" ") {
            return (String(line[line.index(dot, offsetBy: 2)...]), true)
        }
        return nil
    }

    /// Splits a table row on unescaped pipes; `\|` stays a literal pipe.
    private static func cellsOf(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in line {
            if escaped { if ch != "|" { current.append("\\") }; current.append(ch); escaped = false }
            else if ch == "\\" { escaped = true }
            else if ch == "|" { cells.append(current); current = "" }
            else { current.append(ch) }
        }
        cells.append(current)
        // Drop the empty cells outside the leading and trailing pipes.
        return Array(cells.dropFirst().dropLast()).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// GitHub-style heading anchor: lowercase, spaces to hyphens, punctuation dropped.
    static func slug(_ title: String) -> String {
        title.lowercased().compactMap { ch -> Character? in
            if ch.isLetter || ch.isNumber || ch == "-" { return ch }
            if ch == " " { return "-" }
            return nil
        }.reduce(into: "") { $0.append($1) }
    }
}

private struct BlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text, let anchor):
            inline(text)
                .font(level == 1 ? .largeTitle.bold() : level == 2 ? .title2.bold() : .title3.weight(.semibold))
                .padding(.top, level == 1 ? 0 : level == 2 ? 14 : 6)
                .id(anchor)
        case .paragraph(let text):
            inline(text).fixedSize(horizontal: false, vertical: true)
        case .list(let items, let numbered):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { n, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(numbered ? "\(n + 1)." : "•").monospacedDigit().foregroundStyle(.secondary)
                            .frame(minWidth: 16, alignment: .trailing)
                        inline(item).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .table(let header, let rows):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { ForEach(Array(header.enumerated()), id: \.offset) { inline($0.element).bold() } }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) {
                            inline($0.element).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        case .code(let text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func inline(_ markdown: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown))
    }
}
