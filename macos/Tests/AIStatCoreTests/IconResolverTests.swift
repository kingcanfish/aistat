import Foundation
import Testing

@testable import AIStatCore

@Suite("Icon resolution")
struct IconResolverTests {
    @Test func findsAProtocolRelativeStatuspageIcon() throws {
        let html = """
            <head><link rel="shortcut icon" type="image/x-icon"
              href="//dka575ofm4ao0.cloudfront.net/pages-favicon_logos/original/362807/NEW_spark.png" /></head>
            """
        let href = try #require(IconResolver.extractIconHref(html))
        #expect(
            IconResolver.absolutize(base: "https://status.claude.com", href: href)
                == "https://dka575ofm4ao0.cloudfront.net/pages-favicon_logos/original/362807/NEW_spark.png"
        )
    }

    @Test func findsAnAbsoluteFlashDutyIcon() {
        let html = #"<link rel="icon" href="https://static.flashcat.cloud/statuspage/favicon.png"/>"#
        #expect(
            IconResolver.extractIconHref(html)
                == "https://static.flashcat.cloud/statuspage/favicon.png")
    }

    @Test func resolvesRootRelativeHrefsAgainstTheOrigin() {
        #expect(
            IconResolver.absolutize(base: "https://status.openai.com/some/page", href: "/favicon.ico")
                == "https://status.openai.com/favicon.ico")
    }

    @Test func prefersAppleTouchIcon() {
        let html = """
            <link rel="icon" href="/small.png">
            <link rel="apple-touch-icon" href="/big.png">
            """
        #expect(IconResolver.extractIconHref(html) == "/big.png")
    }

    @Test func ignoresNonIconLinksAndLookalikeTags() {
        let html = """
            <linkedin href="/nope.png">
            <link rel="stylesheet" href="/style.css">
            <link rel="icon" href="/yes.png">
            """
        #expect(IconResolver.extractIconHref(html) == "/yes.png")
    }

    @Test func handlesSingleQuotedAndUnquotedAttributes() {
        #expect(IconResolver.extractIconHref("<link rel='icon' href='/a.png'>") == "/a.png")
        #expect(IconResolver.extractIconHref("<link rel=icon href=/b.png>") == "/b.png")
    }

    /// Statuspage hosts frequently point at an image proxy with query
    /// parameters, so `&amp;` in an href is common and would otherwise produce
    /// a broken URL.
    @Test func decodesEscapedQueryParameters() throws {
        let html =
            #"<link rel="icon" href="/_next/image?url=https%3A%2F%2Fx.png&amp;w=96&amp;q=100"/>"#
        let href = try #require(IconResolver.extractIconHref(html))
        #expect(
            IconResolver.absolutize(base: "https://status.openai.com", href: href)
                == "https://status.openai.com/_next/image?url=https%3A%2F%2Fx.png&w=96&q=100")
    }

    @Test func returnsNilWhenThereIsNoIcon() {
        #expect(IconResolver.extractIconHref("<html><body>nothing here</body></html>") == nil)
    }

    /// Framework-rendered status pages emit their icon `<link>` well into the
    /// body, long after the head closes, so the scan cannot stop at `</head>`.
    @Test func findsIconsBehindALargeInlinePayload() {
        let filler = String(repeating: "x", count: 200_000)
        let html = "<head><script>\(filler)</script><link rel=\"icon\" href=\"/late.png\"></head>"
        #expect(IconResolver.extractIconHref(html) == "/late.png")
    }

    /// The scan window is applied to UTF-8 bytes, so a page of multi-byte
    /// characters longer than the cap must not produce a malformed slice or a
    /// crash. (The Rust build had to walk back to a character boundary by hand;
    /// here the truncation happens before anything is decoded.)
    @Test func truncationNeverBreaksOnMultibyteText() {
        let html = String(repeating: "运", count: IconResolver.maxScan)
        #expect(IconResolver.extractIconHref(html) == nil)
    }

    @Test func absolutizeHandlesTheRemainingShapes() {
        #expect(
            IconResolver.absolutize(base: "https://a.com/x", href: "logo.png")
                == "https://a.com/x/logo.png")
        #expect(
            IconResolver.absolutize(base: "https://a.com", href: "data:image/png;base64,AAA")
                == "data:image/png;base64,AAA")
        #expect(IconResolver.absolutize(base: "https://a.com", href: "   ") == nil)
    }
}
