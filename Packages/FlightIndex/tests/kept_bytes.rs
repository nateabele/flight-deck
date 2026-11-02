//! What a kept view costs to hold. The daemon keeps one per active worktree (the base-tree index
//! `refresh` looks paths up in, and the stat snapshot `sweep` compares), and with ninety worktrees
//! of one repository those add up: measured at 93 MB on tessera when both were maps keyed by
//! owned path strings. The listing they describe is already shared by every worktree on the
//! commit, so neither should copy it.
//!
//! The counting allocator is process-wide, so this file holds a single test: nothing else runs
//! in the process while it measures.
mod common;
use common::*;
use flightindex::alloc::live_bytes;
use flightindex::git;
use flightindex::refresh::BaseIndex;
use flightindex::sweep::Snapshot;

#[test]
fn a_kept_view_does_not_copy_the_listing_it_shares() {
    let r = init_repo();
    const FILES: usize = 3000;
    for i in 0..FILES {
        // Paths about as long as tessera's (designer/src/Designer/Panels/Inspector/Field.elm).
        write(&r.root, &format!("packages/designer/src/dir{:02}/module_number_{i:05}.ts", i % 30), &format!("export const v{i} = {i};\n"));
    }
    commit_all(&r.root, "init");
    let view = git::view_for_path(&r.root).unwrap();
    assert_eq!(view.base.len(), FILES);
    let common = r.root.join(".git");
    // Warm up whatever is allocated once per process (the rayon pool, lazy statics).
    drop((BaseIndex::new(&view), Snapshot::take_with_window(&view, &common, 0.0)));

    let before = live_bytes();
    let kept = (BaseIndex::new(&view), Snapshot::take_with_window(&view, &common, 0.0));
    let per_file = live_bytes().saturating_sub(before) / FILES;
    assert!(kept.1.counts().0 == FILES);
    assert!(per_file <= 64, "a kept view costs {per_file} bytes per indexed file");
}
