//! Ranked symbol search by words (`grep` with a multi-word query, and the zero-hit fallbacks of
//! `grep` and `find`): BM25 over camelCase/snake_case-split symbol names, parents and paths.

mod common;
use common::*;
use flightindex::proto::{Request, PROTOCOL_VERSION};
use flightindex::service::{Config, Service};
use serde_json::{json, Value};
use std::path::Path;
use std::sync::Arc;

fn service() -> (tempfile::TempDir, Arc<Service>) {
    let dir = tempfile::tempdir().unwrap();
    let svc = Service::open(Config::new(dir.path().join("store"))).unwrap();
    (dir, svc)
}

fn ok(svc: &Arc<Service>, cwd: &Path, tool: &str, args: Value) -> String {
    let req = Request { v: Some(PROTOCOL_VERSION), id: json!(1), cwd: cwd.to_string_lossy().to_string(), seq: 0, tool: tool.into(), args: args.as_object().cloned().unwrap_or_default() };
    let r = svc.handle(req);
    assert!(r.ok, "{tool} failed: {:?} {:?}", r.state, r.error);
    r.text.unwrap()
}

const PREVIEW: &str = "export function refuseRelease(reason: string) {\n  return reason.length > 0;\n}\n\nexport function previewRows() {\n  return [];\n}\n";
const IMAGES: &str = "export function previewImage() {\n  return 1;\n}\n\nexport function scaleImage() {\n  return 2;\n}\n";
const NOTES: &str = "export function releaseNotes() {\n  return 'notes';\n}\n\nexport function tagRelease() {\n  return 'tag';\n}\n";
const BODY: &str = "export function opaque() {\n  const marker = 'zebra crossing';\n  return marker;\n}\n";

fn project() -> Repo {
    let r = init_repo();
    write(&r.root, "web/export/preview.ts", PREVIEW);
    write(&r.root, "web/media/images.ts", IMAGES);
    write(&r.root, "web/release/notes.ts", NOTES);
    write(&r.root, "web/misc/body.ts", BODY);
    commit_all(&r.root, "init");
    r
}

/// Data rows of a ranked answer: the lines that name a file of the repo.
fn rows<'a>(text: &'a str, root: &Path) -> Vec<&'a str> {
    let prefix = format!("{}/", root.display());
    text.lines().filter(|l| l.contains(&prefix) && !l.starts_with("view:")).collect()
}

#[test]
fn a_multi_word_grep_ranks_symbols_by_their_words() {
    let (_d, svc) = service();
    let r = project();
    let t = ok(&svc, &r.root, "grep", json!({"query": "exports preview refuses release"}));
    assert!(!t.contains("No symbols match"), "a sentence is a ranked search, not a prefix: {t}");
    assert!(t.contains("Ranked by words: export preview refuse release"), "{t}");
    let rows = rows(&t, &r.root);
    assert!(rows.len() >= 3, "{t}");
    assert!(rows[0].starts_with("refuseRelease"), "the symbol matching every word, path included, ranks first: {t}");
    assert!(rows[0].contains(&r.root.join("web/export/preview.ts").display().to_string()), "{t}");
}

#[test]
fn rank_true_ranks_a_single_word() {
    let (_d, svc) = service();
    let r = project();
    let t = ok(&svc, &r.root, "grep", json!({"query": "image", "rank": true}));
    assert!(t.contains("Ranked by words: image"), "{t}");
    let rows = rows(&t, &r.root);
    assert!(rows.iter().take(2).all(|l| l.contains("Image")), "{t}");
}

#[test]
fn many_ranked_hits_are_rows_and_three_or_fewer_also_show_the_code() {
    let (_d, svc) = service();
    let r = project();
    // `release` names three symbols' words or paths: more than three hits gives rows only.
    let many = ok(&svc, &r.root, "grep", json!({"query": "release preview image", "rank": true}));
    assert!(rows(&many, &r.root).len() > 3 && !many.contains(" | "), "rows only: {many}");
    // One hit: the row and the symbol's code.
    let one = ok(&svc, &r.root, "grep", json!({"query": "scale", "rank": true}));
    assert_eq!(rows(&one, &r.root).len(), 1, "{one}");
    assert!(one.contains("5 | export function scaleImage() {") && one.contains("6 |   return 2;"), "code of a lone hit: {one}");
}

#[test]
fn a_prefix_grep_with_no_hits_falls_back_to_words() {
    let (_d, svc) = service();
    let r = project();
    let t = ok(&svc, &r.root, "grep", json!({"query": "imageScale"}));
    assert!(t.contains("No symbol names start with `imageScale`; closest by words:"), "{t}");
    assert!(rows(&t, &r.root)[0].starts_with("scaleImage"), "{t}");
    // A prefix that matches keeps today's answer, unranked words never in front of it.
    let t = ok(&svc, &r.root, "grep", json!({"query": "preview"}));
    assert!(t.contains("Found 2 result(s) for `preview`") && !t.contains("Ranked by words"), "{t}");
}

#[test]
fn a_find_with_no_exact_hit_appends_the_closest_by_words() {
    let (_d, svc) = service();
    let r = project();
    let t = ok(&svc, &r.root, "find", json!({"name": "releaseTag"}));
    assert!(t.starts_with("view:") && t.contains("No symbol found with name 'releaseTag'"), "{t}");
    assert!(t.contains("Closest by words (release tag):"), "{t}");
    assert!(rows(&t, &r.root)[0].starts_with("tagRelease"), "{t}");
    // An exact hit is unchanged.
    let t = ok(&svc, &r.root, "find", json!({"name": "tagRelease"}));
    assert!(t.contains("Found 1 match(es)") && !t.contains("Closest by words"), "{t}");
}

#[test]
fn words_no_symbol_carries_fall_back_to_the_bodies_they_appear_in() {
    let (_d, svc) = service();
    let r = project();
    let t = ok(&svc, &r.root, "grep", json!({"query": "zebra crossing"}));
    assert!(t.contains("No symbol has the words zebra crossing; function bodies that contain them:"), "{t}");
    let rows = rows(&t, &r.root);
    assert!(rows[0].contains("web/misc/body.ts:L2 in opaque (function)"), "the body line, reported against its function: {t}");
}

#[test]
fn an_edit_is_ranked_by_the_next_query() {
    let (_d, svc) = service();
    let r = project();
    ok(&svc, &r.root, "grep", json!({"query": "preview rows"})); // builds the word index of the base graph
    write(&r.root, "web/media/images.ts", &format!("{IMAGES}export function cropThumbnail() {{\n  return 3;\n}}\n"));
    let t = ok(&svc, &r.root, "grep", json!({"query": "crop thumbnail"}));
    let rows = rows(&t, &r.root);
    assert!(!rows.is_empty() && rows[0].starts_with("cropThumbnail"), "the edited view has its own word index: {t}");
}
