//! Index-transfer core shared by every access method: classification and
//! degradation of source indexes, matching against target indexes, and the
//! index entries of the manifest wire format. Transfer variants dispatch
//! through exhaustive matches over [`wire::IndexTransfer`], never runtime
//! registration; access-method specifics live in [`btree`] and nowhere else.

mod btree;
mod catalog;
pub mod wire;

pub use btree::BtreeMetadata;
pub use catalog::{
    classify_index, classify_index_with, match_user_indexes, physical_index, toast_index_transfer,
    toast_index_verdict, verify_index_metapage, verify_toast_layout, ClassifyIndex,
};
pub use wire::IndexTransfer;
