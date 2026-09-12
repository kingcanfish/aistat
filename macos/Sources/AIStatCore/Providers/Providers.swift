import Foundation

public enum Providers {
    public static func fetchSite(
        client: HTTPClient, site: SiteConfig
    ) async throws(ProviderError) -> SiteStatus {
        switch site.adapter {
        case .statuspage: try await StatusPageProvider.fetch(client: client, site: site)
        case .flashduty: try await FlashDutyProvider.fetch(client: client, site: site)
        }
    }

    /// Fetches every site concurrently, capturing per-site errors as `unknown`
    /// rather than failing the whole batch — one unreachable page must not cost
    /// the user the other two.
    ///
    /// Results come back in the configured order, not in completion order, so
    /// the panel's rows don't reshuffle themselves on every refresh.
    public static func fetchAll(client: HTTPClient, sites: [SiteConfig]) async -> [SiteStatus] {
        guard !sites.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, SiteStatus).self) { group in
            for (index, site) in sites.enumerated() {
                group.addTask {
                    do {
                        return (index, try await fetchSite(client: client, site: site))
                    } catch let error as ProviderError {
                        let message = error.description
                        Log.provider.error(
                            "\(site.name) (\(site.url)): \(message, privacy: .public)")
                        return (index, SiteStatus.fromError(site: site, message: message))
                    } catch {
                        return (index, SiteStatus.fromError(site: site, message: chain(error)))
                    }
                }
            }
            var out = [SiteStatus?](repeating: nil, count: sites.count)
            for await (index, status) in group { out[index] = status }
            return out.compactMap { $0 }
        }
    }

    /// Probes a status page URL to work out which adapter can read it, so the
    /// user never has to know whether a page is StatusPage- or FlashDuty-
    /// flavored. The settings sheet has no adapter picker for exactly this
    /// reason — which also means a provider missing from here can never be
    /// added by a user.
    ///
    /// Both probes run at once: a page that isn't StatusPage-flavored can take
    /// the full request timeout to say so, and serializing that behind the
    /// FlashDuty probe would double the worst case.
    public static func detectAdapter(client: HTTPClient, url: String) async -> AdapterKind? {
        func probe(_ adapter: AdapterKind) -> SiteConfig {
            SiteConfig(id: "", name: "", url: url.trimmedTrailingSlash, adapter: adapter)
        }

        let spSite = probe(.statuspage)
        let fdSite = probe(.flashduty)
        async let statuspage = probeResult(client: client, site: spSite)
        async let flashduty = probeResult(client: client, site: fdSite)

        let (sp, fd) = await (statuspage, flashduty)
        switch (sp, fd) {
        case (.success, _): return .statuspage
        case (.failure, .success): return .flashduty
        case (.failure(let spError), .failure(let fdError)):
            // The user only sees "unsupported"; these two lines are what
            // actually say whether the page is unreachable or just not a
            // status API.
            Log.provider.warning("\(url): no adapter matched")
            Log.provider.warning("  statuspage probe: \(spError.description, privacy: .public)")
            Log.provider.warning("  flashduty probe: \(fdError.description, privacy: .public)")
            return nil
        }
    }

    /// Runs one adapter probe and reports which way it went. Typed throws do
    /// not survive being captured by an `async let` closure, so the conversion
    /// to `Result` happens here where the thrown type is still concrete.
    private static func probeResult(
        client: HTTPClient, site: SiteConfig
    ) async -> Result<SiteStatus, ProviderError> {
        do {
            return .success(try await fetchSite(client: client, site: site))
        } catch {
            return .failure(error)
        }
    }

    /// The message the settings sheet shows for a page neither adapter reads.
    /// It names the two paths, because "unsupported" on its own leaves the user
    /// with nothing to check.
    public static func unsupportedMessage(for url: String) -> String {
        """
        \(url) doesn't expose a supported status API.

        Supported: Atlassian StatusPage / incident.io (\(StatusPageProvider.summaryPath)) \
        and FlashDuty (\(FlashDutyProvider.widgetPath)).
        """
    }
}

public struct URLProblem: Error, CustomStringConvertible, Sendable {
    public var message: String
    public var description: String { message }
}

/// Requires an http(s) scheme, adding `https://` when the user typed a bare
/// host. `NSWorkspace.open` treats a bare `status.claude.com` as a file path
/// and fails rather than reaching the site.
public func normalizeURL(_ raw: String) -> Result<String, URLProblem> {
    let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if url.isEmpty { return .failure(URLProblem(message: "empty URL")) }
    if url.hasPrefix("http://") || url.hasPrefix("https://") { return .success(url) }
    if url.contains("://") {
        return .failure(URLProblem(message: "unsupported URL scheme: \(url)"))
    }
    return .success("https://" + url)
}
