import AIStatCore
import Foundation
import Observation

/// Everything the panel and the menu bar read from, and the single path that
/// updates it.
///
/// `@MainActor` throughout, which is the native replacement for the Rust
/// build's five `Mutex`es: state that only the UI touches doesn't need locks,
/// it needs an actor, and the one it needs is the one SwiftUI already observes.
/// Network work still happens off the main thread — `await` on a `URLSession`
/// call suspends without blocking it.
@MainActor
@Observable
final class AppModel {
    private(set) var statuses: [SiteStatus] = []
    private(set) var isRefreshing = false
    /// Bound directly by the settings window: macOS settings apply as they are
    /// made, so every edit lands here and is persisted from `didSet` rather
    /// than being staged behind a Save button.
    var config: Config {
        didSet {
            guard !isInert, config != oldValue else { return }
            save()
            if config.launchAtLogin != oldValue.launchAtLogin {
                LoginItem.set(enabled: config.launchAtLogin)
            }
            if config.iconStyle != oldValue.iconStyle {
                onDisplayStateChanged?()
            }
            if config.sites != oldValue.sites {
                // Drop cache entries for services that are gone, so a URL
                // re-added later is looked up fresh rather than served a stale
                // answer, then go and read whatever is there now.
                let live = Set(config.sites.map(\.url))
                icons = icons.filter { live.contains($0.key) }
                statuses = statuses.filter { site in config.sites.contains { $0.id == site.id } }
                Task { await refresh() }
            }
        }
    }

    /// Called whenever something the menu bar icon shows has changed — a new
    /// reading, or a new icon style. Set by the app delegate; the model itself
    /// knows nothing about AppKit.
    var onDisplayStateChanged: (() -> Void)?

    /// The one model the app has. Owned here rather than plumbed through,
    /// because the `App` struct, the `Settings` scene and the app delegate all
    /// need the same instance and none of them owns the other two.
    static let shared = AppModel()

    private let client = HTTPClient()
    /// The same client, for the settings sheet's adapter probe: one connection
    /// pool for the process, whoever is asking.
    var probeClient: HTTPClient { client }
    private let configURL: URL
    private var previous: [String: SiteStatus] = [:]
    /// Site URL → resolved icon URL. A present key with a `nil` value records a
    /// page we already checked and that has no usable icon, so its HTML isn't
    /// refetched on every poll.
    private var icons: [String: String?] = [:]
    private var scheduler: Task<Void, Never>?
    /// The fetch currently running, if any. See ``refresh()``.
    private var inFlight: Task<Void, Never>?
    /// Suppresses persistence and refetching. Set only by ``seed(config:statuses:)``,
    /// so the preview renderer can put the model in a given state without
    /// writing a config file or reaching the network.
    private var isInert = false

    init(configURL: URL = AppModel.defaultConfigURL) {
        self.configURL = configURL
        self.config = AppModel.load(from: configURL)
    }

    /// `~/Library/Application Support/com.aistat.app/config.json` — the same
    /// path Tauri's `app_config_dir()` resolved to, with the same JSON key
    /// names, so an existing install keeps its settings.
    static var defaultConfigURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = base.appendingPathComponent("com.aistat.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    /// Installs fixed readings without touching the network.
    ///
    /// For the offscreen preview renderer (`swift run aistat-preview`), which
    /// needs the panel in states that are awkward to reach against live pages —
    /// a full outage, an unreachable host, an empty list.
    func seed(config: Config, statuses: [SiteStatus]) {
        isInert = true
        self.config = config
        self.statuses = statuses
    }

    /// The last reading for one configured service, if there is one yet.
    func status(for id: String) -> SiteStatus? {
        statuses.first { $0.id == id }
    }

    // MARK: - editing the service list

    func removeSite(_ id: String) {
        config.sites.removeAll { $0.id == id }
    }

    func moveSites(from source: IndexSet, to destination: Int) {
        config.sites.move(fromOffsets: source, toOffset: destination)
    }

    /// Adds a service, or replaces the one being edited.
    ///
    /// The id is derived from the name so it stays readable in the config file,
    /// but an *existing* service keeps the id it had: the id is what the
    /// snapshot diff matches on, and renaming a service is not a reason to
    /// notify about everything it is currently doing.
    func upsertSite(existingID: String?, name: String, url: String, adapter: AdapterKind) {
        let id = existingID ?? uniqueID(for: name)
        let site = SiteConfig(id: id, name: name, url: url, adapter: adapter)
        if let index = config.sites.firstIndex(where: { $0.id == id }) {
            config.sites[index] = site
        } else {
            config.sites.append(site)
        }
    }

    private func uniqueID(for name: String) -> String {
        let base = SiteConfig.slug(name)
        let taken = Set(config.sites.map(\.id))
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// The aggregate the menu bar icon and the panel header both show.
    var overall: Status {
        aggregate(statuses.map(\.overall), priority: config.statusPriority)
    }

    // MARK: - the refresh cycle

    /// The single path that updates anything: fetch every site concurrently
    /// alongside icon resolution → diff against the previous snapshot → store →
    /// tell the menu bar → notify.
    ///
    /// Anything that needs to affect the icon or the panel should go through
    /// here rather than mutating state directly.
    ///
    /// Only ever one at a time: a second caller joins the fetch already running
    /// instead of starting another. The button is disabled while
    /// ``isRefreshing``, so the overlap this prevents is the one the UI cannot
    /// — the scheduler coming due while the user is mid-refresh, which fetched
    /// everything twice and let whichever finished first clear `isRefreshing`
    /// out from under the other, re-enabling the button while a fetch was still
    /// in flight.
    func refresh() async {
        if let running = inFlight {
            await running.value
            return
        }
        // Assigned before the first suspension, so the task cannot start — let
        // alone finish and clear this — before it is recorded.
        let task = Task { @MainActor in
            await self.performRefresh()
            // Cleared here rather than after `await task.value` below: a caller
            // arriving between this task finishing and that line running would
            // otherwise join an already-finished fetch and get nothing done.
            self.inFlight = nil
        }
        inFlight = task
        await task.value
    }

    private func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let sites = config.sites
        let started = Date()

        // Statuses and icons hit different endpoints and don't depend on each
        // other, so they go out together rather than back to back.
        async let fetched = Providers.fetchAll(client: client, sites: sites)
        async let resolvedIcons = Self.resolveIcons(
            client: client, sites: sites, known: Set(icons.keys))

        var next = await fetched
        for (url, icon) in await resolvedIcons { icons[url] = icon }
        for i in next.indices { next[i].icon = icons[next[i].url] ?? nil }

        // Per-site failures are logged where they happen; this is the one line
        // that says a refresh ran at all, and how many sites came back
        // unreadable.
        let failed = next.filter { $0.error != nil }.count
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        Log.app.info("refreshed \(next.count) site(s) in \(ms)ms, \(failed) failed")

        let changes = detectChanges(before: previous, after: next)
        previous = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
        statuses = next
        onDisplayStateChanged?()

        if config.notificationsEnabled {
            for change in changes { Notifier.post(change) }
        }
    }

    /// Resolves the icon for any site we haven't seen before, filling the cache.
    ///
    /// Icons are scraped from each page's HTML, so this does real network work
    /// the first time a site appears and nothing at all afterwards. It depends
    /// only on the configured URLs, not on the fetched statuses, which is why
    /// the caller can run it alongside the status fetch instead of after it.
    private static func resolveIcons(
        client: HTTPClient, sites: [SiteConfig], known: Set<String>
    ) async -> [(String, String?)] {
        let unresolved = sites.map(\.url).filter { !known.contains($0) }
        guard !unresolved.isEmpty else { return [] }
        return await withTaskGroup(of: (String, String?).self) { group in
            for url in unresolved {
                group.addTask {
                    (url, await IconResolver.fetchIconURL(client: client, pageURL: url))
                }
            }
            var out: [(String, String?)] = []
            for await pair in group { out.append(pair) }
            return out
        }
    }

    /// Polls on the configured interval, re-reading it each cycle so a change
    /// in settings takes effect without a restart.
    func startScheduler() {
        scheduler?.cancel()
        scheduler = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.config.effectiveInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                await self?.refresh()
            }
        }
    }

    func stopScheduler() {
        scheduler?.cancel()
        scheduler = nil
    }

    // MARK: - persistence

    private static func load(from url: URL) -> Config {
        guard let data = try? Data(contentsOf: url) else {
            Log.app.info("no config at \(url.path, privacy: .public), starting from defaults")
            return Config()
        }
        do {
            return try Config.fromJSON(data)
        } catch {
            // A hand-edited config that fails to parse silently reverting to
            // defaults looks exactly like the app ignoring the file. Say so.
            Log.app.error(
                "\(url.path, privacy: .public) is not valid config JSON: \(error.localizedDescription, privacy: .public); starting from defaults"
            )
            return Config()
        }
    }

    private func save() {
        do {
            try config.toJSON().write(to: configURL, options: .atomic)
        } catch {
            Log.app.error(
                "could not write \(self.configURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
