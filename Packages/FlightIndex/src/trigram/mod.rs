//! A blob-keyed trigram index for regex and substring search across worktrees, after Russ Cox's
//! design (Regular Expression Matching with a Trigram Index, 2012).
//!
//! The multi-worktree body search (`tools::multigrep`) already reads each distinct blob once. What
//! it still pays per query is reading, hashing and matching every distinct blob of every worktree
//! asked about: 9,546 blobs for 110 tessera worktrees. This index lets it read only the blobs whose
//! trigrams can satisfy the regex, and touch the file lists of the others by ordinal, not by
//! 40-character blob id.
//!
//! - **Keyed by blob.** A blob's content never changes, so its trigrams never go stale: an index
//!   entry is right for every worktree, commit and path that holds the blob, forever. Worktrees
//!   share almost all their blobs, so the index of one repository serves all its worktrees.
//! - **Dense ordinals.** Each indexed blob gets the next `u32`; postings are sets of ordinals.
//! - **Files.** An immutable, memory-mapped segment per run of ordinals, in a `<repo>.tri/`
//!   directory beside the repository's SQLite database (`segment.rs`); new blobs land as
//!   append-only delta segments, merged into one base when the chain grows long (`index.rs`).
//! - **Per tree.** The ordinals of each commit's files, and their Roaring bitmap, are kept in
//!   memory per commit, so a query maps a whole worktree to ordinals without hashing its paths.
//! - **Planner.** `regex-syntax` HIR to an AND/OR trigram query (`plan.rs`), Cox's `analyze`.
//! - **Verification.** The candidates are read and matched with the `regex` crate exactly as an
//!   unindexed search matches every blob, so the index can only skip work, never change a hit.
//! - **Overlay.** Working-tree files that are not committed are not indexed and are always read.
//!   Committed blobs a query meets that the index lacks are read too, and queued for a background
//!   writer, which reads them with `git cat-file` and appends a delta segment.

pub mod index;
pub mod plan;
pub mod segment;

pub use index::{dir_for_db, for_dir, key, RepoIndex, Snapshot, TreeOrdinals, NOT_INDEXED};
pub use plan::{plan, Query};
