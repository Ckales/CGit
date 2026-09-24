//! Flutter frontend's Rust side.
//!
//! All Git logic lives in `cgit-core`, and this crate only translates it across
//! the FFI seam. Core is synchronous on purpose — frb runs each call on its own
//! worker thread.
pub mod api;
mod frb_generated;
