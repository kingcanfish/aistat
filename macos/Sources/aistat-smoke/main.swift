import AIStatCore
import Foundation

/// Live smoke test: fetch all default sites and print normalized status.
///
/// ```sh
/// swift run aistat-smoke
/// ```
///
/// The counterpart of `cargo run -p aistat-core --example smoke`. It exists for
/// the same reason: the mappings have unit tests, but only a real fetch tells
/// you whether the pages still answer the shape those tests assume.
let client = HTTPClient()
let sites = Config.defaultSites
let started = Date()
let statuses = await Providers.fetchAll(client: client, sites: sites)
let elapsed = Int(Date().timeIntervalSince(started) * 1000)

let overall = aggregate(statuses.map(\.overall), priority: Status.defaultPriority)
print("aggregate overall: \(overall.label)  [\(elapsed)ms]")
print("")

for s in statuses {
    let fetched = s.fetchedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
    print("\(s.name)  \(s.overall.label)  [\(s.adapter)]  fetched_at=\(fetched)")
    if let err = s.error { print("    ERROR: \(err)") }
    if let icon = await IconResolver.fetchIconURL(client: client, pageURL: s.url) {
        print("    icon: \(icon)")
    }
    for c in s.components { print("    component: \(c.name) -> \(c.status.label)") }
    for i in s.incidents {
        print("    incident: [\(i.lifecycle)] \(i.title) (impact=\(i.impact.label), updated=\(i.updatedAt ?? "nil"))")
        if !i.latestUpdate.isEmpty { print("        latest: \(i.latestUpdate)") }
    }
}
