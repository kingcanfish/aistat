//! Live smoke test: fetch all default sites and print normalized status.
//!
//! ```sh
//! cargo run -p aiisdown-core --example smoke
//! ```

use aiisdown_core::{aggregate, config::default_sites, fetch_all};

#[tokio::main]
async fn main() {
    let sites = default_sites();
    let statuses = fetch_all(&sites).await;

    let priority = aiisdown_core::Status::DEFAULT_PRIORITY.to_vec();
    let overall = aggregate(statuses.iter().map(|s| s.overall), &priority);

    println!("aggregate overall: {} ({})", overall.label(), overall.color());
    println!();

    for s in &statuses {
        println!(
            "{}  {}  [{:?}]  fetched_at={:?}",
            s.name,
            s.overall.label(),
            s.adapter,
            s.fetched_at
        );
        if let Some(err) = &s.error {
            println!("    ERROR: {}", err);
        }
        for c in &s.components {
            println!("    component: {} -> {}", c.name, c.status.label());
        }
        for i in &s.incidents {
            println!(
                "    incident: [{}] {} (impact={}, updated={:?})",
                i.lifecycle,
                i.title,
                i.impact.label(),
                i.updated_at
            );
            if !i.latest_update.is_empty() {
                println!("        latest: {}", i.latest_update);
            }
        }
    }
}
