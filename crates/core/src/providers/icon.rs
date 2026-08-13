//! Resolves a status page's own icon.
//!
//! Status APIs don't publish a logo, so the icon is read out of the page's
//! HTML `<link rel="...icon...">`. Statuspage and FlashDuty both point these at
//! the brand's uploaded logo, which is what makes each row recognizable.

/// Finds the `href` of the first `<link>` whose `rel` mentions "icon",
/// preferring an `apple-touch-icon` when one is present because those are
/// guaranteed to be raster and reasonably large.
pub fn extract_icon_href(html: &str) -> Option<String> {
    let mut best: Option<String> = None;

    for tag in link_tags(html) {
        let Some(rel) = attr(&tag, "rel") else { continue };
        let rel = rel.to_ascii_lowercase();
        if !rel.contains("icon") {
            continue;
        }
        let Some(href) = attr(&tag, "href") else { continue };
        if href.trim().is_empty() {
            continue;
        }
        if rel.contains("apple-touch-icon") {
            return Some(href);
        }
        best.get_or_insert(href);
    }

    best
}

/// Yields the text of every `<link ...>` tag in `html`.
fn link_tags(html: &str) -> impl Iterator<Item = String> + '_ {
    let lower = html.to_ascii_lowercase();
    let mut from = 0usize;
    std::iter::from_fn(move || {
        loop {
            let start = lower[from..].find("<link")? + from;
            // Guard against matching something like `<linkedin`.
            let after = lower.as_bytes().get(start + 5).copied().unwrap_or(b' ');
            let end = lower[start..].find('>').map(|i| start + i)?;
            from = end + 1;
            if after.is_ascii_whitespace() || after == b'/' {
                return Some(html[start..end].to_string());
            }
        }
    })
}

/// Reads `name="value"` / `name='value'` out of a tag body.
fn attr(tag: &str, name: &str) -> Option<String> {
    let lower = tag.to_ascii_lowercase();
    let mut from = 0usize;
    while let Some(idx) = lower[from..].find(name) {
        let at = from + idx;
        from = at + name.len();

        // Must be a standalone attribute name followed by `=`.
        let before_ok = at == 0
            || lower.as_bytes()[at - 1].is_ascii_whitespace()
            || lower.as_bytes()[at - 1] == b'"';
        let rest = lower[from..].trim_start();
        if !before_ok || !rest.starts_with('=') {
            continue;
        }

        let eq = lower[from..].find('=')? + from + 1;
        let value = tag[eq..].trim_start();
        let quote = value.chars().next()?;
        if quote == '"' || quote == '\'' {
            let end = value[1..].find(quote)? + 1;
            return Some(value[1..end].to_string());
        }
        let end = value
            .find(|c: char| c.is_whitespace() || c == '>')
            .unwrap_or(value.len());
        return Some(value[..end].to_string());
    }
    None
}

/// Undoes the HTML escaping applied to attribute values. Statuspage hosts
/// frequently point at an image proxy with query parameters, so `&amp;` in an
/// href is common and would otherwise produce a broken URL.
fn unescape_entities(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&#38;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
}

/// Turns a possibly relative icon href into an absolute URL.
pub fn absolutize(base: &str, href: &str) -> Option<String> {
    let unescaped = unescape_entities(href);
    let href = unescaped.trim();
    let base = base.trim_end_matches('/');

    if href.starts_with("http://") || href.starts_with("https://") {
        return Some(href.to_string());
    }
    if href.starts_with("data:") {
        return Some(href.to_string());
    }
    // Protocol-relative, e.g. `//cdn.example.com/logo.png`.
    if let Some(rest) = href.strip_prefix("//") {
        return Some(format!("https://{rest}"));
    }
    if let Some(rest) = href.strip_prefix('/') {
        let origin = origin_of(base)?;
        return Some(format!("{origin}/{rest}"));
    }
    if href.is_empty() {
        return None;
    }
    Some(format!("{base}/{href}"))
}

fn origin_of(url: &str) -> Option<String> {
    let (scheme, rest) = url.split_once("://")?;
    let host = rest.split('/').next()?;
    Some(format!("{scheme}://{host}"))
}

/// Upper bound on how much of a page we search.
const MAX_SCAN: usize = 512 * 1024;

/// Bounds how much of the document we scan.
///
/// This deliberately doesn't stop at `</head>`: framework-rendered status pages
/// (DeepSeek's is a Next.js app) emit their icon `<link>` well into the body,
/// long after the head closes.
fn scan_window(html: &str) -> &str {
    let mut cut = html.len().min(MAX_SCAN);
    // Never slice through a multi-byte character.
    while cut > 0 && !html.is_char_boundary(cut) {
        cut -= 1;
    }
    &html[..cut]
}

/// Fetches `page_url` and resolves its icon to an absolute URL.
pub async fn fetch_icon_url(client: &reqwest::Client, page_url: &str) -> Option<String> {
    // Goes through fetch_text so pages that reject Rust's TLS still resolve.
    let html = super::fetch_text(client, page_url).await.ok()?;
    absolutize(page_url, &extract_icon_href(scan_window(&html))?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_a_protocol_relative_statuspage_icon() {
        let html = r#"<head><link rel="shortcut icon" type="image/x-icon"
            href="//dka575ofm4ao0.cloudfront.net/pages-favicon_logos/original/362807/NEW_spark.png" /></head>"#;
        let href = extract_icon_href(html).unwrap();
        assert_eq!(
            absolutize("https://status.claude.com", &href).unwrap(),
            "https://dka575ofm4ao0.cloudfront.net/pages-favicon_logos/original/362807/NEW_spark.png"
        );
    }

    #[test]
    fn finds_an_absolute_flashduty_icon() {
        let html = r#"<link rel="icon" href="https://static.flashcat.cloud/statuspage/favicon.png"/>"#;
        assert_eq!(
            extract_icon_href(html).unwrap(),
            "https://static.flashcat.cloud/statuspage/favicon.png"
        );
    }

    #[test]
    fn resolves_root_relative_hrefs_against_the_origin() {
        assert_eq!(
            absolutize("https://status.openai.com/some/page", "/favicon.ico").unwrap(),
            "https://status.openai.com/favicon.ico"
        );
    }

    #[test]
    fn prefers_apple_touch_icon() {
        let html = r#"
            <link rel="icon" href="/small.png">
            <link rel="apple-touch-icon" href="/big.png">
        "#;
        assert_eq!(extract_icon_href(html).unwrap(), "/big.png");
    }

    #[test]
    fn ignores_non_icon_links_and_lookalike_tags() {
        let html = r#"
            <linkedin href="/nope.png">
            <link rel="stylesheet" href="/style.css">
            <link rel="icon" href="/yes.png">
        "#;
        assert_eq!(extract_icon_href(html).unwrap(), "/yes.png");
    }

    #[test]
    fn handles_single_quoted_and_unquoted_attributes() {
        assert_eq!(
            extract_icon_href("<link rel='icon' href='/a.png'>").unwrap(),
            "/a.png"
        );
        assert_eq!(
            extract_icon_href("<link rel=icon href=/b.png>").unwrap(),
            "/b.png"
        );
    }

    #[test]
    fn decodes_escaped_query_parameters() {
        let html = r#"<link rel="icon" href="/_next/image?url=https%3A%2F%2Fx.png&amp;w=96&amp;q=100"/>"#;
        let href = extract_icon_href(html).unwrap();
        assert_eq!(
            absolutize("https://status.openai.com", &href).unwrap(),
            "https://status.openai.com/_next/image?url=https%3A%2F%2Fx.png&w=96&q=100"
        );
    }

    #[test]
    fn returns_none_when_there_is_no_icon() {
        assert!(extract_icon_href("<html><body>nothing here</body></html>").is_none());
    }

    #[test]
    fn finds_icons_behind_a_large_inline_payload() {
        let filler = "x".repeat(200_000);
        let html =
            format!("<head><script>{filler}</script><link rel=\"icon\" href=\"/late.png\"></head>");
        assert_eq!(extract_icon_href(scan_window(&html)).unwrap(), "/late.png");
    }

    #[test]
    fn scan_window_never_slices_through_a_character() {
        // No </head>, longer than MAX_SCAN, multi-byte throughout.
        let html = "运".repeat(MAX_SCAN);
        let head = scan_window(&html);
        assert!(head.len() <= MAX_SCAN);
        assert!(html.starts_with(head));
    }
}
