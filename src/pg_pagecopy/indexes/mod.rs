//! Index-transfer core shared by every access method: classification and
//! degradation of source indexes, matching against target indexes, and the
//! index entries of the manifest wire format. Transfer variants use
//! exhaustive matches over [`wire::IndexTransfer`], never runtime registration.
//! shortcut: B-tree source/page dispatch remains at call sites until #84 isolates it.

mod catalog;
pub mod wire;

pub use catalog::{
    classify_index_with, match_user_indexes, toast_index_verdict, toast_layout, ClassifyIndex,
};
pub use wire::{BtreeMetadata, IndexTransfer};
