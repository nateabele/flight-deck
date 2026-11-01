//! Python import resolution and reference binding through the graph.

mod common;
use common::*;
use flightindex::engine::Engine;
use flightindex::graph::{Confidence, ViewGraph};
use flightindex::query::{Direction, NameMatch};
use std::path::Path;
use std::sync::Arc;

fn graph_of(repo: &Repo) -> (tempfile::TempDir, Engine, Arc<ViewGraph>) {
    let dir = tempfile::tempdir().unwrap();
    let e = Engine::open(dir.path().join("store")).unwrap();
    let v = e.view_for_path(&repo.root).unwrap();
    e.build(&v, &[], |_| {}).unwrap();
    let g = e.graph(&v).unwrap();
    (dir, e, g)
}

fn rel(root: &Path, p: &Path) -> String {
    p.strip_prefix(root).unwrap_or(p).to_string_lossy().to_string()
}

fn out_deps(g: &ViewGraph, r: &Repo, file: &str) -> Vec<String> {
    let mut v: Vec<String> =
        g.file_deps(&r.root.join(file), Direction::Out, 1).data.unwrap().iter().map(|d| rel(&r.root, &d.path)).collect();
    v.sort();
    v
}

/// `src/` layout, a relative import, a package `__init__`, an aliased module import and a
/// `from pkg import submodule`.
fn fixture() -> Repo {
    let r = init_repo();
    write(&r.root, "src/app/__init__.py", "from .core import Engine\n");
    write(&r.root, "src/app/core.py", "class Engine:\n    def run(self):\n        return self.step()\n    def step(self):\n        return 1\n");
    write(&r.root, "src/app/util/__init__.py", "");
    write(&r.root, "src/app/util/text.py", "def shout(s):\n    return s.upper()\n");
    write(
        &r.root,
        "src/app/cli.py",
        "import app.util.text as text\nfrom app import core\nfrom app.core import Engine as E\nfrom .util import text as t2\nimport os\n\ndef main():\n    e = E()\n    e.run()\n    core.Engine()\n    return text.shout('x') + os.getcwd()\n",
    );
    write(&r.root, "tests/test_cli.py", "from app.cli import main\n\ndef test_main():\n    main()\n");
    commit_all(&r.root, "init");
    r
}

#[test]
fn imports_resolve_across_src_layout_relative_and_package_forms() {
    let r = fixture();
    let (_d, _e, g) = graph_of(&r);
    assert_eq!(
        out_deps(&g, &r, "src/app/cli.py"),
        ["src/app/__init__.py", "src/app/core.py", "src/app/util/__init__.py", "src/app/util/text.py"],
        "absolute dotted, `from pkg import module` (the package init too), relative `.util`; stdlib `os` stays unresolved"
    );
    assert_eq!(out_deps(&g, &r, "tests/test_cli.py"), ["src/app/cli.py"], "tests import through the src/ root");
    assert_eq!(out_deps(&g, &r, "src/app/__init__.py"), ["src/app/core.py"]);
}

#[test]
fn references_bind_through_aliases_and_imported_names() {
    let r = fixture();
    let (_d, _e, g) = graph_of(&r);
    let engine = g.find_symbols(&NameMatch::Exact("Engine".into()), None, 5).data;
    let class = engine.iter().find(|h| h.path.ends_with("core.py")).expect("class Engine");
    let from: Vec<String> = g.references(class.id).data.iter().filter(|h| h.confidence == Confidence::Exact).map(|h| rel(&r.root, &h.path)).collect();
    assert!(from.contains(&"src/app/cli.py".to_string()), "`E()` goes through `import Engine as E`: {from:?}");

    let shout = g.find_symbols(&NameMatch::Exact("shout".into()), None, 5).data;
    let refs = g.references(shout[0].id).data;
    assert!(
        refs.iter().any(|h| rel(&r.root, &h.path) == "src/app/cli.py" && h.confidence == Confidence::Exact),
        "`text.shout` goes through `import app.util.text as text`"
    );

    let step = g.find_symbols(&NameMatch::Exact("step".into()), None, 5).data;
    let refs = g.references(step[0].id).data;
    assert!(refs.iter().any(|h| rel(&r.root, &h.path) == "src/app/core.py" && h.confidence == Confidence::Exact), "self.step()");
}

#[test]
fn a_repo_root_package_resolves_without_src() {
    let r = init_repo();
    write(&r.root, "pkg/__init__.py", "");
    write(&r.root, "pkg/a.py", "from . import b\nfrom pkg.b import thing\nfrom ..outside import nothing\n");
    write(&r.root, "pkg/b.py", "def thing(): pass\n");
    commit_all(&r.root, "init");
    let (_d, _e, g) = graph_of(&r);
    assert_eq!(out_deps(&g, &r, "pkg/a.py"), ["pkg/__init__.py", "pkg/b.py"]);
}
