import Foundation

public enum ProviderError: Error, CustomStringConvertible, Sendable {
    /// Rendered through the underlying-error chain because this string is what
    /// the menu bar row shows. `URLError`'s own message stops at "A server with
    /// the specified hostname could not be found", which is sometimes the whole
    /// story and sometimes hides a TLS alert underneath it.
    case http(String)
    case parse(String)

    public var description: String {
        switch self {
        case .http(let m): m
        case .parse(let m): "parse error: \(m)"
        }
    }

    public var localizedDescription: String { description }
}

/// The one HTTP client for the process.
///
/// Built once and reused, for the same reason the Rust build held a single
/// `reqwest::Client`: `URLSession` pools connections and reuses TLS sessions
/// per session object, and a session per refresh throws both away.
///
/// Notably *not* here: a TLS backend choice. The Rust build had to install
/// `rustls-graviola` so its ClientHello would offer X25519MLKEM768 first and
/// grow past ~1.4KB, because `status.deepseek.com` sits behind a middlebox that
/// resets a ClientHello fitting in one TCP segment. Apple's TLS stack already
/// offers the hybrid post-quantum group by default, so the whole workaround —
/// the dependency, the pinned group order, and the unit test guarding it —
/// disappears. Measured against the live site: 149ms to a 200.
public struct HTTPClient: Sendable {
    public static let timeout: TimeInterval = 15
    public static let userAgent = "aistat/\(AIStatCore.version)"

    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = HTTPClient.timeout
        config.httpAdditionalHeaders = ["User-Agent": HTTPClient.userAgent]
        // System proxy settings are read by default here. The Rust build had to
        // opt into reqwest's `system-proxy` feature to get the same thing,
        // because a GUI app launched from Finder never sees HTTP(S)_PROXY.
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    /// GETs `url` and returns the body as text.
    public func fetchText(_ url: String) async throws(ProviderError) -> String {
        let data = try await fetchData(url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProviderError.parse("response was not UTF-8")
        }
        return text
    }

    public func fetchData(_ url: String) async throws(ProviderError) -> Data {
        guard let parsed = URL(string: url) else {
            throw ProviderError.http("not a URL: \(url)")
        }
        do {
            let (data, response) = try await session.data(from: parsed)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let reason = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                throw ProviderError.http("HTTP \(http.statusCode) \(reason)")
            }
            return data
        } catch let error as ProviderError {
            throw error
        } catch {
            Log.provider.warning("\(url): request failed: \(chain(error), privacy: .public)")
            throw ProviderError.http(chain(error))
        }
    }

    public func fetchJSON<T: Decodable>(_ type: T.Type, from url: String) async throws(ProviderError) -> T {
        let data = try await fetchData(url)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // The body is the only way to tell "this isn't a status API" from
            // "the schema moved", and it's the one thing the error never
            // carries.
            let head = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
            Log.provider.warning(
                "\(url): response was not the expected JSON: \(error.localizedDescription, privacy: .public); body starts: \(head, privacy: .public)"
            )
            throw ProviderError.parse(describe(decodingError: error))
        }
    }
}

/// Renders an error together with its underlying causes.
///
/// `URLError`'s `localizedDescription` is the part we already know; the reason
/// — a bad certificate, a refused connection — is in `NSUnderlyingErrorKey`
/// beneath it, so a log line without the chain says nothing actionable.
func chain(_ error: Error) -> String {
    var parts: [String] = []
    var current: NSError? = error as NSError
    var seen = 0
    while let e = current, seen < 5 {
        let text = e.localizedDescription
        if parts.last != text { parts.append(text) }
        current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        seen += 1
    }
    return parts.joined(separator: ": ")
}

/// `DecodingError`'s own description is a multi-line debug dump; the row has
/// one line, so this reduces it to the part that names what went wrong.
func describe(decodingError error: Error) -> String {
    guard let decoding = error as? DecodingError else { return error.localizedDescription }
    switch decoding {
    case .keyNotFound(let key, _): return "missing field `\(key.stringValue)`"
    case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
        let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? ctx.debugDescription : "\(path): \(ctx.debugDescription)"
    case .dataCorrupted(let ctx): return ctx.debugDescription
    @unknown default: return error.localizedDescription
    }
}
