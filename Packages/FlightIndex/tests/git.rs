mod common;
use common::*;
use flightindex::git::{self, Overlay};

#[test]
fn clean_main_checkout() {
    let r = init_repo();
    write(&r.root, "src/A.elm", ELM_A);
    write(&r.root, "src/B.elm", ELM_B);
    write(&r.root, "README.md", "x");
    let c = commit_all(&r.root, "init");
    let v = git::view_for_path(&r.root.join("src/A.elm")).unwrap();
    assert_eq!(v.label.base_commit.as_deref(), Some(c.as_str()));
    assert_eq!(v.label.worktree, r.root);
    assert_eq!(v.label.repo, r.root.join(".git"));
    assert!(!v.label.dirty);
    assert!(v.overlay.is_empty());
    let files: Vec<_> = v.files().into_iter().map(|f| f.path).collect();
    assert_eq!(files, ["src/A.elm", "src/B.elm"], "README is not an indexable language");
    // the blob id is git's own
    let want = git(&r.root, &["rev-parse", "HEAD:src/A.elm"]);
    assert_eq!(v.base[0].blob_id, want);
    assert_eq!(git::blob_id(ELM_A.as_bytes()), want);
}

#[test]
fn linked_worktree_shares_repository_identity() {
    let r = init_repo();
    write(&r.root, "a.elm", ELM_B);
    commit_all(&r.root, "init");
    let wt_parent = tempfile::tempdir().unwrap();
    let wt = wt_parent.path().canonicalize().unwrap().join("feature");
    git(&r.root, &["worktree", "add", "-q", "-b", "feature", wt.to_str().unwrap()]);

    let main = git::view_for_path(&r.root).unwrap();
    let linked = git::view_for_path(&wt.join("a.elm")).unwrap();
    assert_eq!(main.label.repo, linked.label.repo, "all worktrees share the common dir");
    assert_eq!(linked.label.worktree, wt);
    assert_ne!(main.label.worktree, linked.label.worktree);
    assert!(git::locate(&wt).unwrap().linked);
    assert!(!git::locate(&r.root).unwrap().linked);
    assert_eq!(main.base_commit(), linked.base_commit());
}

trait Base {
    fn base_commit(&self) -> Option<&str>;
}
impl Base for git::View {
    fn base_commit(&self) -> Option<&str> {
        self.label.base_commit.as_deref()
    }
}

#[test]
fn overlay_covers_modified_added_deleted_untracked_and_not_ignored() {
    let r = init_repo();
    write(&r.root, ".gitignore", "ignored.elm\n");
    write(&r.root, "keep.elm", ELM_A);
    write(&r.root, "mod.elm", ELM_A);
    write(&r.root, "del.elm", ELM_B);
    write(&r.root, "ren.elm", "module Ren exposing (..)\nx = 1\n");
    commit_all(&r.root, "init");

    write(&r.root, "mod.elm", "module Mod exposing (..)\nm = 2\n");
    std::fs::remove_file(r.root.join("del.elm")).unwrap();
    write(&r.root, "staged.elm", ELM_B);
    git(&r.root, &["add", "staged.elm"]);
    write(&r.root, "untracked/deep.ts", "export const x = 1;\n");
    write(&r.root, "ignored.elm", ELM_B);
    git(&r.root, &["mv", "ren.elm", "renamed.elm"]);

    let v = git::view_for_path(&r.root).unwrap();
    assert!(v.label.dirty);
    let find = |p: &str| v.overlay.iter().find(|o| o.path() == p);
    let mod_blob = git::blob_id(b"module Mod exposing (..)\nm = 2\n");
    assert!(matches!(find("mod.elm"), Some(Overlay::Present(f)) if f.blob_id == mod_blob));
    assert!(matches!(find("del.elm"), Some(Overlay::Deleted(_))));
    assert!(matches!(find("staged.elm"), Some(Overlay::Present(_))));
    assert!(matches!(find("untracked/deep.ts"), Some(Overlay::Present(f)) if f.language == "typescript"));
    assert!(matches!(find("renamed.elm"), Some(Overlay::Present(_))));
    assert!(matches!(find("ren.elm"), Some(Overlay::Deleted(_))));
    assert!(find("ignored.elm").is_none(), "ignored files are not part of the view");
    assert!(find("keep.elm").is_none());

    let files: Vec<_> = v.files().into_iter().map(|f| f.path).collect();
    assert_eq!(files, ["keep.elm", "mod.elm", "renamed.elm", "staged.elm", "untracked/deep.ts"]);
    // The merged view carries the overlay's blob for the modified file, not HEAD's.
    assert_eq!(v.files().iter().find(|f| f.path == "mod.elm").unwrap().blob_id, mod_blob);
}

#[test]
fn repo_without_commits_is_all_overlay() {
    let r = init_repo();
    write(&r.root, "a.elm", ELM_B);
    write(&r.root, "b.rs", "fn main() {}\n");
    let v = git::view_for_path(&r.root).unwrap();
    assert_eq!(v.label.base_commit, None);
    assert!(v.base.is_empty());
    assert_eq!(v.files().len(), 2);
    assert!(v.label.is_git);
}

#[test]
fn detached_head_uses_the_commit() {
    let r = init_repo();
    write(&r.root, "a.elm", ELM_B);
    let c1 = commit_all(&r.root, "one");
    write(&r.root, "b.elm", ELM_B);
    commit_all(&r.root, "two");
    git(&r.root, &["checkout", "-q", "--detach", &c1]);
    let v = git::view_for_path(&r.root).unwrap();
    assert_eq!(v.label.base_commit.as_deref(), Some(c1.as_str()));
    assert_eq!(v.files().len(), 1);
}

#[test]
fn directory_outside_git_is_a_repository_of_overlay() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    write(&root, "elm.json", "{}");
    write(&root, ".gitignore", "gen/\n");
    write(&root, "src/A.elm", ELM_A);
    write(&root, "gen/G.elm", ELM_B);
    write(&root, "node_modules/x/i.js", "x");
    let v = git::view_for_path(&root.join("src/A.elm")).unwrap();
    assert!(!v.label.is_git);
    assert_eq!(v.label.base_commit, None);
    assert_eq!(v.label.repo, root);
    let files: Vec<_> = v.files().into_iter().map(|f| f.path).collect();
    assert_eq!(files, ["src/A.elm"], ".gitignore and node_modules are respected");
    assert_eq!(v.files()[0].blob_id, git::blob_id(ELM_A.as_bytes()));
}

#[test]
fn submodule_is_its_own_repository_and_not_descended_into() {
    let sub = init_repo();
    write(&sub.root, "lib.elm", ELM_B);
    commit_all(&sub.root, "sub");
    let r = init_repo();
    write(&r.root, "top.elm", ELM_A);
    commit_all(&r.root, "top");
    git(&r.root, &["-c", "protocol.file.allow=always", "submodule", "add", "-q", sub.root.to_str().unwrap(), "vendor/sub"]);
    commit_all(&r.root, "add sub");

    let parent = git::view_for_path(&r.root).unwrap();
    let files: Vec<_> = parent.files().into_iter().map(|f| f.path).collect();
    assert_eq!(files, ["top.elm"], "parent view must not include the submodule's files");
    assert!(!parent.label.dirty);

    let child = git::view_for_path(&r.root.join("vendor/sub/lib.elm")).unwrap();
    assert_eq!(child.label.worktree, r.root.join("vendor/sub"));
    assert_ne!(child.label.repo, parent.label.repo, "a submodule is its own repository");
    assert_eq!(child.files().len(), 1);
}

#[test]
fn symlinks_and_huge_files_are_skipped() {
    let r = init_repo();
    let outside = tempfile::tempdir().unwrap();
    write(outside.path(), "secret.elm", ELM_B);
    write(&r.root, "real.elm", ELM_B);
    std::os::unix::fs::symlink(outside.path().join("secret.elm"), r.root.join("link.elm")).unwrap();
    write(&r.root, "big.js", &"x".repeat(1_100_000));
    commit_all(&r.root, "init");
    write(&r.root, "big2.js", &"y".repeat(1_100_000));
    std::os::unix::fs::symlink(outside.path().join("secret.elm"), r.root.join("link2.elm")).unwrap();
    let v = git::view_for_path(&r.root).unwrap();
    let files: Vec<_> = v.files().into_iter().map(|f| f.path).collect();
    assert_eq!(files, ["real.elm"]);
}

#[test]
fn a_path_that_does_not_exist_yet_resolves_through_its_ancestor() {
    let r = init_repo();
    write(&r.root, "a.elm", ELM_B);
    commit_all(&r.root, "init");
    let v = git::view_for_path(&r.root.join("new/dir/Thing.elm")).unwrap();
    assert_eq!(v.label.worktree, r.root);
}
