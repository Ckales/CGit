//! Flutter frontend's Rust side.
//!
//! Mirrors src-tauri: all Git logic lives in `cgit-core`, and this crate only
//! translates it across the FFI seam. Core is synchronous on purpose — frb runs
//! each call on its own worker thread, the same way Tauri's `(async)` commands
//! run on its thread pool.
pub mod api;
mod frb_generated;
