//! Index-transfer core shared by every access method: classification and
//! degradation of source indexes, matching against target indexes, and the
//! index entries of the manifest wire format. Transfer variants dispatch
//! through exhaustive matches over [`wire::IndexTransfer`], never runtime
//! registration; access-method specifics live in [`btree`], [`brin`],
//! [`hash`] and [`gist`].

mod brin;
mod btree;
mod catalog;
mod gist;
mod hash;
pub mod wire;

pub use brin::BrinMetadata;
pub use btree::BtreeMetadata;
pub use catalog::{
    catalog_preflight, classify_index, classify_index_with, match_user_indexes, physical_index,
    toast_index_transfer, toast_index_verdict, verify_index_metapage, verify_toast_layout,
    ClassifyIndex,
};
pub use gist::GistMetadata;
pub use hash::HashMetadata;
pub use wire::IndexTransfer;
