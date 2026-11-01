mod common;
use common::*;
use flightindex::git::{self, Overlay, View};
use flightindex::refresh::{refresh, BaseIndex, Refreshed};
use flightindex::watch::Pending;
use std::collections::BTreeMap;
use std::path::Path;

/// The overlay as a path-keyed summary, so two views compare regardless of listing order. A
/// deletion of a path the base tree never had (`git status` reports an untracked symlink or an
/// oversized file that way) says nothing, so it is left out.
fn overlay_of(v: &View) -> BTreeMap<String, Option<String>> {
    let in_base = |p: &str| v.base.iter().any(|f| f.path == p);
    v.overlay
        .iter()
        .filter(|o| matches!(o, Overlay::Present(_)) || in_base(o.path()))
        .map(|o| match o {
            Overlay::Present(f) => (f.path.clone(), Some(f.blob_id.clone())),
            Overlay::Deleted(p) => (p.clone(), None),
        })
        .collect()
}

/// What the index sees: the files after the overlay, which is what must not differ.
fn files_of(v: &View) -> BTreeMap<String, String> {
    v.files().into_iter().map(|f| (f.path, f.blob_id)).collect()
}

fn pending(root: &Path, paths: &[&str], subtrees: &[&str]) -> Pending {
    Pending { paths: paths.iter().map(|p| root.join(p)).collect(), subtrees: subtrees.iter().map(|p| root.join(p)).collect(), ..Default::default() }
}

fn project() -> Repo {
    let r = init_repo();
    write(&r.root, ".gitignore", "dist/\n");
    write(&r.root, "src/A.elm", ELM_A);
    write(&r.root, "src/B.elm", ELM_B);
    write(&r.root, "web/a.ts", "export const a = 1;\n");
    write(&r.root, "web/inner/b.ts", "export const b = 2;\n");
    write(&r.root, "README.md", "docs\n");
    commit_all(&r.root, "init");
    r
}

/// Apply `refresh` to the view from before `edit`, and require it to equal a view computed from
/// scratch after it: the watcher path may never see a different worktree than `git status` does.
fn agrees(r: &Repo, edit: impl FnOnce(&Path), p: impl FnOnce(&Path) -> Pending) {
    let before = git::view_for_path(&r.root).unwrap();
    let index = BaseIndex::new(&before);
    edit(&r.root);
    let Refreshed::View(got) = refresh(&before, &index, &p(&r.root)).unwrap() else { panic!("refresh asked for a rescan") };
    let want = git::view_for_path(&r.root).unwrap();
    assert_eq!(overlay_of(&got), overlay_of(&want), "overlay");
    assert_eq!(files_of(&got), files_of(&want), "files");
    // `dirty` is "the indexed view differs from HEAD": a change to a file the index never parses
    // (a README, a nested repository) is not seen by the watcher, so it may read clean where git
    // says dirty, but never the other way round and never with an overlay.
    assert!(got.label.dirty == want.label.dirty || (!got.label.dirty && got.overlay.is_empty()), "dirty");
}

#[test]
fn an_edited_tracked_file_enters_the_overlay_and_leaves_it_when_reverted() {
    let r = project();
    agrees(&r, |root| write(root, "src/A.elm", "module A exposing (a)\n\na = 1\n"), |root| pending(root, &["src/A.elm"], &[]));
    // Reverting to the committed bytes is no change at all: `git status` does not list it either.
    let dirty = git::view_for_path(&r.root).unwrap();
    let index = BaseIndex::new(&dirty);
    write(&r.root, "src/A.elm", ELM_A);
    let Refreshed::View(back) = refresh(&dirty, &index, &pending(&r.root, &["src/A.elm"], &[])).unwrap() else { panic!("rescan") };
    assert!(back.overlay.is_empty() && !back.label.dirty, "{:?}", back.overlay);
}

#[test]
fn a_new_file_a_removed_file_and_a_replaced_file_agree_with_git_status() {
    let r = project();
    agrees(
        &r,
        |root| {
            write(root, "src/New.elm", "module New exposing (n)\n\nn = 1\n");
            std::fs::remove_file(root.join("src/B.elm")).unwrap();
            write(root, "web/a.ts", "export const a = 99;\n");
        },
        |root| pending(root, &["src/New.elm", "src/B.elm", "web/a.ts"], &[]),
    );
}

#[test]
fn a_new_file_that_git_ignores_stays_out() {
    // Only git knows every ignore rule (nested .gitignore, info/exclude, global excludes), so a
    // path the base tree lacks is put to it. Getting this wrong puts build output in every answer.
    let r = project();
    agrees(&r, |root| write(root, "dist/bundle.js", "var x = 1;\n"), |root| pending(root, &["dist/bundle.js"], &[]));
    let v = git::view_for_path(&r.root).unwrap();
    assert!(v.overlay.is_empty());
}

#[test]
fn a_moved_directory_is_the_old_files_deleted_and_the_new_ones_present() {
    // A directory rename produces one event for each directory, none for the files inside.
    let r = project();
    agrees(&r, |root| std::fs::rename(root.join("web/inner"), root.join("web/moved")).unwrap(), |root| pending(root, &[], &["web/inner", "web/moved"]));
}

#[test]
fn a_deleted_directory_deletes_every_file_the_base_had_under_it() {
    let r = project();
    agrees(&r, |root| std::fs::remove_dir_all(root.join("web")).unwrap(), |root| pending(root, &[], &["web"]));
}

#[test]
fn a_file_inside_a_nested_repository_is_not_ours() {
    let r = project();
    agrees(
        &r,
        |root| {
            git(root, &["init", "-q", "vendor/dep"]);
            write(root, "vendor/dep/x.ts", "export const x = 1;\n");
        },
        |root| pending(root, &["vendor/dep/x.ts"], &["vendor", "vendor/dep"]),
    );
}

#[test]
fn files_the_index_cannot_parse_do_not_change_the_overlay() {
    let r = project();
    agrees(&r, |root| write(root, "README.md", "changed\n"), |root| pending(root, &["README.md"], &[]));
}

#[test]
fn a_symlink_and_an_oversized_file_are_not_indexed() {
    let r = project();
    agrees(
        &r,
        |root| {
            std::fs::remove_file(root.join("web/a.ts")).unwrap();
            std::os::unix::fs::symlink("../src/A.elm", root.join("web/a.ts")).unwrap();
            write(root, "web/big.ts", &"x".repeat(1_100_000));
        },
        |root| pending(root, &["web/a.ts", "web/big.ts"], &[]),
    );
}

#[test]
fn a_bulk_operation_asks_for_a_rescan_instead_of_a_thousand_stats() {
    let r = project();
    let before = git::view_for_path(&r.root).unwrap();
    let index = BaseIndex::new(&before);
    for i in 0..300 {
        write(&r.root, &format!("gen/f{i}.ts"), "export const g = 1;\n");
    }
    let p = pending(&r.root, &[], &["gen"]);
    assert!(matches!(refresh(&before, &index, &p).unwrap(), Refreshed::View(_) | Refreshed::Rescan));
    let names: Vec<String> = (0..300).map(|i| format!("gen/f{i}.ts")).collect();
    let paths: Vec<&str> = names.iter().map(String::as_str).collect();
    assert!(matches!(refresh(&before, &index, &pending(&r.root, &paths, &[])).unwrap(), Refreshed::Rescan));
}

#[test]
fn a_derived_listing_is_the_listing_git_would_give() {
    let r = project();
    let a = git(&r.root, &["rev-parse", "HEAD"]);
    let old = git::list_tree(&r.root, &a).unwrap();
    write(&r.root, "src/A.elm", "module A exposing (a)\n\na = 3\n");
    write(&r.root, "src/C.elm", "module C exposing (c)\n\nc = 1\n");
    std::fs::remove_file(r.root.join("src/B.elm")).unwrap();
    std::fs::rename(r.root.join("web/inner/b.ts"), r.root.join("web/inner/renamed.ts")).unwrap();
    write(&r.root, "web/huge.ts", &"y".repeat(1_100_000));
    write(&r.root, "README.md", "new docs\n");
    let b = commit_all(&r.root, "changes");
    let derived = git::derive_listing(&r.root, &old, &a, &b).unwrap().expect("small diff");
    assert_eq!(derived, git::list_tree(&r.root, &b).unwrap(), "same entries in the same order");
}
