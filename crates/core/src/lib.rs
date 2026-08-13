//! Core logic for aistat.
//!
//! This crate is Tauri-agnostic: it contains the data model, configuration,
//! status providers (StatusPage + FlashDuty), status normalization, and
//! snapshot diffing. It can be unit-tested without any GUI dependencies.

pub mod aggregate;
pub mod config;
pub mod model;
pub mod normalize;
pub mod providers;
pub mod snapshot;

pub use aggregate::aggregate;
pub use config::{AdapterKind, Config, SiteConfig};
pub use model::{Component, Incident, SiteStatus, Status};
pub use providers::{build_client, detect_adapter, fetch_all, fetch_site, HttpClient, ProviderError};
pub use snapshot::{detect_changes, StatusChange};
