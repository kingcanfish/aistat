import Foundation

/// Resolves a status page's own icon.
///
/// Status APIs don't publish a logo, so the icon is read out of the page's HTML
/// `<link rel="...icon...">`. Statuspage and FlashDuty both point these at the
/// brand's uploaded logo, which is what makes each row recognizable.
///
/// Hand-rolled rather than parsed. `XMLParser` refuses real-world status pages
/// (they are HTML, not XHTML), and a third-party HTML parser would be the only
/// dependency in the package — for one attribute on one tag. The scanner below
/// works on UTF-8 bytes with an ASCII-lowercased shadow copy, so offsets in the
/// two always agree and a multi-byte character is never sliced through.
public enum IconResolver {
    /// Upper bound on how much of a page we search.
    ///
    /// Deliberately not "up to `</head>`": framework-rendered status pages
    /// (DeepSeek's is a Next.js app) emit their icon `<link>` well into the
    /// body, long after the head closes.
    public static let maxScan = 512 * 1024

    /// Finds the `href` of the first `<link>` whose `rel` mentions "icon",
    /// preferring an `apple-touch-icon` when one is present because those are
    /// guaranteed to be raster and reasonably large.
    public static func extractIconHref(_ html: String) -> String? {
        let bytes = Array(html.utf8.prefix(maxScan))
        let lower = asciiLowercased(bytes)
        var best: String?

        for tag in linkTags(bytes: bytes, lower: lower) {
            guard let rel = attribute("rel", inTag: tag.bytes, lower: tag.lower) else { continue }
            let relLower = rel.lowercased()
            guard relLower.contains("icon") else { continue }
            guard let href = attribute("href", inTag: tag.bytes, lower: tag.lower),
                !href.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            if relLower.contains("apple-touch-icon") { return href }
            if best == nil { best = href }
        }
        return best
    }

    private struct Tag {
        var bytes: ArraySlice<UInt8>
        var lower: ArraySlice<UInt8>
    }

    /// Yields every `<link ...>` tag body, guarding against `<linkedin` and
    /// friends by requiring whitespace or `/` right after the element name.
    private static func linkTags(bytes: [UInt8], lower: [UInt8]) -> [Tag] {
        let needle = Array("<link".utf8)
        var out: [Tag] = []
        var from = lower.startIndex
        while let start = find(needle, in: lower, from: from) {
            let afterIndex = start + needle.count
            let after: UInt8 = afterIndex < lower.count ? lower[afterIndex] : UInt8(ascii: " ")
            guard let end = find([UInt8(ascii: ">")], in: lower, from: start) else { break }
            from = end + 1
            if isASCIIWhitespace(after) || after == UInt8(ascii: "/") {
                out.append(Tag(bytes: bytes[start..<end], lower: lower[start..<end]))
            }
        }
        return out
    }

    /// Reads `name="value"` / `name='value'` / `name=value` out of a tag body.
    private static func attribute(
        _ name: String, inTag tag: ArraySlice<UInt8>, lower: ArraySlice<UInt8>
    ) -> String? {
        let needle = Array(name.utf8)
        var from = lower.startIndex
        while let at = find(needle, in: lower, from: from) {
            from = at + needle.count

            // Must be a standalone attribute name followed by `=`.
            let beforeOK =
                at == lower.startIndex || isASCIIWhitespace(lower[at - 1])
                || lower[at - 1] == UInt8(ascii: "\"")
            var cursor = from
            while cursor < lower.endIndex, isASCIIWhitespace(lower[cursor]) { cursor += 1 }
            guard beforeOK, cursor < lower.endIndex, lower[cursor] == UInt8(ascii: "=") else {
                continue
            }

            var value = cursor + 1
            while value < tag.endIndex, isASCIIWhitespace(tag[value]) { value += 1 }
            guard value < tag.endIndex else { return nil }

            let quote = tag[value]
            if quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") {
                guard let close = find([quote], in: tag, from: value + 1) else { return nil }
                return decode(tag[(value + 1)..<close])
            }
            var end = value
            while end < tag.endIndex, !isASCIIWhitespace(tag[end]), tag[end] != UInt8(ascii: ">") {
                end += 1
            }
            return decode(tag[value..<end])
        }
        return nil
    }

    /// Undoes the HTML escaping applied to attribute values. Statuspage hosts
    /// frequently point at an image proxy with query parameters, so `&amp;` in
    /// an href is common and would otherwise produce a broken URL.
    static func unescapeEntities(_ s: String) -> String {
        var out = s
        for (entity, replacement) in [
            ("&amp;", "&"), ("&#38;", "&"), ("&quot;", "\""), ("&#39;", "'"),
            ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"),
        ] {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        return out
    }

    /// Turns a possibly relative icon href into an absolute URL.
    public static func absolutize(base: String, href rawHref: String) -> String? {
        let href = unescapeEntities(rawHref).trimmingCharacters(in: .whitespacesAndNewlines)
        let base = base.trimmedTrailingSlash

        if href.hasPrefix("http://") || href.hasPrefix("https://") { return href }
        if href.hasPrefix("data:") { return href }
        // Protocol-relative, e.g. `//cdn.example.com/logo.png`.
        if href.hasPrefix("//") { return "https://" + href.dropFirst(2) }
        if href.hasPrefix("/") {
            guard let origin = origin(of: base) else { return nil }
            return origin + href
        }
        if href.isEmpty { return nil }
        return "\(base)/\(href)"
    }

    static func origin(of url: String) -> String? {
        guard let schemeEnd = url.range(of: "://") else { return nil }
        let rest = url[schemeEnd.upperBound...]
        let host = rest.prefix { $0 != "/" }
        return String(url[url.startIndex..<schemeEnd.upperBound]) + String(host)
    }

    /// Fetches `pageURL` and resolves its icon to an absolute URL.
    ///
    /// A missing icon only costs a blank row, so failures log rather than
    /// propagate — but they log, because "why is this row iconless" is
    /// otherwise unanswerable.
    public static func fetchIconURL(client: HTTPClient, pageURL: String) async -> String? {
        let html: String
        do {
            html = try await client.fetchText(pageURL)
        } catch {
            Log.icon.debug(
                "\(pageURL): icon lookup could not fetch the page: \(error.description, privacy: .public)"
            )
            return nil
        }
        guard let href = extractIconHref(html) else {
            Log.icon.debug("\(pageURL): no <link rel=icon> in the first \(maxScan) bytes")
            return nil
        }
        return absolutize(base: pageURL, href: href)
    }

    // MARK: - byte helpers

    private static func asciiLowercased(_ bytes: [UInt8]) -> [UInt8] {
        bytes.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
    }

    private static func isASCIIWhitespace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0B || b == 0x0C
    }

    private static func decode(_ slice: ArraySlice<UInt8>) -> String {
        String(decoding: slice, as: UTF8.self)
    }

    private static func find<C: Collection>(
        _ needle: [UInt8], in haystack: C, from: C.Index
    ) -> C.Index? where C.Element == UInt8, C.Index == Int {
        guard !needle.isEmpty, from >= haystack.startIndex else { return nil }
        let limit = haystack.endIndex - needle.count
        guard limit >= from else { return nil }
        var i = from
        while i <= limit {
            var match = true
            for k in 0..<needle.count where haystack[i + k] != needle[k] {
                match = false
                break
            }
            if match { return i }
            i += 1
        }
        return nil
    }
}
