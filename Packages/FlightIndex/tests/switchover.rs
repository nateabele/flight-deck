mod common;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use tempfile::TempDir;

const BIN: &str = env!("CARGO_BIN_EXE_fdindex");

const SETTINGS: &str = r#"{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Glob|Grep",
        "hooks": [{"type": "command", "command": "HOME/.local/bin/qartez-guard", "timeout": 3000}]
      },
      {
        "matcher": "Edit|Write|MultiEdit",
        "hooks": [{"type": "command", "command": "HOME/.local/bin/qartez-guard", "timeout": 3000}]
      },
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "HOME/.local/bin/grep-guard", "timeout": 3000}]}
    ],
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "HOME/.local/bin/qartez-setup --session-start", "timeout": 5000}]},
      {"hooks": [{"type": "command", "command": "HOME/.claude/hooks/check-browser-bridge.sh", "timeout": 5}]}
    ]
  },
  "permissions": {"allow": ["mcp__qartez__*"]},
  "mcpServers": {
    "qartez": {
      "args": [],
      "command": "HOME/.local/bin/qartez"
    }
  }
}
"#;

const CLAUDE_JSON: &str = r#"{
  "numStartups": 12,
  "ratio": 1.0,
  "projects": {"/work/a": {"allowedTools": [], "mcpServers": {}}},
  "skillUsage": {
    "qartez": {"usageCount": 149, "lastUsedAt": 1787257423312}
  },
  "mcpServers": {
    "other": {"args": ["-y", "pkg"], "command": "npx", "env": {}, "type": "stdio"},
    "qartez": {
      "args": [],
      "command": "HOME/.local/bin/qartez",
      "env": {},
      "type": "stdio"
    }
  },
  "migrationVersion": 14
}
"#;

const CODEX: &str = "personality = \"pragmatic\"\n# <qartez-mcp-begin>\n[mcp_servers.qartez]\ncommand = \"HOME/.local/bin/qartez\"\nargs = []\n\n[mcp_servers.qartez.tools.qartez_project]\napproval_mode = \"approve\"\n\n[mcp_servers.qartez.tools.qartez_add_root]\napproval_mode = \"approve\"\n\n[projects.\"/work/a\"]\ntrust_level = \"trusted\"\n# <qartez-mcp-end>\n\n[features]\nhooks = true\n";

const OPENCODE: &str = "{\n  \"$schema\": \"https://opencode.ai/config.json\",\n  \"mcp\": {\n    \"qartez\": {\n      \"command\": [\n        \"HOME/.local/bin/qartez\"\n      ],\n      \"enabled\": false,\n      \"type\": \"local\"\n    }\n  }\n}\n";

const ZED: &str = "{\n  \"context_servers\": {\n    \"qartez\": {\n      \"args\": [],\n      \"command\": \"HOME/.local/bin/qartez\",\n      \"env\": {}\n    }\n  },\n  \"theme\": \"x\"\n}\n";

const GEMINI: &str = "{\n  \"hooks\": {\n    \"BeforeTool\": [\n      {\n        \"hooks\": [{\"command\": \"HOME/.local/bin/qartez-guard\", \"timeout\": 3000, \"type\": \"command\"}],\n        \"matcher\": \"replace|write_file\"\n      }\n    ]\n  },\n  \"mcpServers\": {\n    \"qartez\": {\n      \"args\": [],\n      \"command\": \"HOME/.local/bin/qartez\"\n    }\n  }\n}\n";

struct Home {
    _dir: TempDir,
    home: PathBuf,
    store: PathBuf,
}

impl Home {
    fn seeded() -> Home {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().canonicalize().unwrap().join("home");
        let h = home.to_string_lossy().to_string();
        let put = |rel: &str, text: &str| {
            let p = home.join(rel);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(&p, text.replace("HOME", &h)).unwrap();
        };
        for profile in [".claude", ".claude-radify"] {
            put(&format!("{profile}/settings.json"), SETTINGS);
            put(&format!("{profile}/skills/qartez/SKILL.md"), "old skill\n");
            put(&format!("{profile}/skills/qartez/references/guard.md"), "old guard doc\n");
            put(&format!("{profile}/skills/qartez/references/doctrine-explore.md"), "doctrine stays\n");
        }
        put(".claude.json", CLAUDE_JSON);
        put(".claude-radify/.claude.json", CLAUDE_JSON);
        put(".codex/config.toml", CODEX);
        put(".config/opencode/opencode.json", OPENCODE);
        put(".config/zed/settings.json", ZED);
        put(".gemini/settings.json", GEMINI);
        put(".cursor/mcp.json", "{\n  \"mcpServers\": {\n    \"qartez\": {\n      \"args\": [],\n      \"command\": \"HOME/.local/bin/qartez\"\n    }\n  }\n}\n");
        put(".local/bin/qartez", "#!/bin/sh\necho the old qartez\n");
        put(".local/bin/qartez-guard", "#!/bin/sh\necho the old guard\n");
        std::os::unix::fs::symlink("qartez", home.join(".local/bin/qartez-mcp")).unwrap();
        Home { store: dir.path().canonicalize().unwrap().join("store"), home, _dir: dir }
    }

    fn run(&self, args: &[&str]) -> Output {
        Command::new(BIN)
            .args(["--home", self.home.to_str().unwrap(), "--store", self.store.to_str().unwrap(), "--socket", self.store.join("s.sock").to_str().unwrap(), "switchover", "--no-service"])
            .args(args)
            .env("HOME", &self.home)
            .output()
            .unwrap()
    }

    fn ok(&self, args: &[&str]) -> String {
        let o = self.run(args);
        assert!(o.status.success(), "{args:?}: {}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr));
        String::from_utf8_lossy(&o.stdout).to_string()
    }

    /// Every regular file and symlink under home: path -> content (symlinks as `-> target`).
    fn snapshot(&self) -> BTreeMap<PathBuf, String> {
        fn walk(dir: &Path, out: &mut BTreeMap<PathBuf, String>) {
            for e in std::fs::read_dir(dir).unwrap().flatten() {
                let p = e.path();
                let ft = e.file_type().unwrap();
                if ft.is_symlink() {
                    out.insert(p.clone(), format!("-> {}", std::fs::read_link(&p).unwrap().display()));
                } else if ft.is_dir() {
                    walk(&p, out);
                } else {
                    out.insert(p.clone(), String::from_utf8_lossy(&std::fs::read(&p).unwrap()).to_string());
                }
            }
        }
        let mut out = BTreeMap::new();
        walk(&self.home, &mut out);
        out
    }

    fn read(&self, rel: &str) -> String {
        std::fs::read_to_string(self.home.join(rel)).unwrap()
    }
}

/// The lines that differ between two texts of the same line count.
fn changed_lines(before: &str, after: &str) -> Vec<(String, String)> {
    let (b, a): (Vec<&str>, Vec<&str>) = (before.lines().collect(), after.lines().collect());
    assert_eq!(b.len(), a.len(), "line count changed");
    b.iter().zip(&a).filter(|(x, y)| x != y).map(|(x, y)| (x.trim().to_string(), y.trim().to_string())).collect()
}

#[test]
fn a_dry_run_lists_every_change_and_touches_nothing() {
    let h = Home::seeded();
    let before = h.snapshot();
    let out = h.ok(&[]);
    assert_eq!(h.snapshot(), before);
    assert!(!h.store.exists(), "a dry run does not even create the backup directory");
    for needle in [
        "DRY RUN",
        ".claude/settings.json (5 change(s))",
        ".claude-radify/settings.json (5 change(s))",
        ".claude.json (2 change(s))",
        "- \"command\": \"",
        "/.local/bin/fdindex guard\"",
        "/.local/bin/fdindex session-start\"",
        "\"args\": [\"mcp\"]",
        ".codex/config.toml (2 change(s) in [mcp_servers.qartez])",
        "the per-tool tables",
        "opencode.json (1 change(s))",
        "zed/settings.json (2 change(s))",
        "cursor/mcp.json (2 change(s))",
        ".gemini/settings.json (3 change(s))",
        "the `qartez` name",
        "rename it to",
        "qartez.orig (kept)",
        "skill: overlay",
        "doctrine-*.md) stay",
        "references/guard.md: replaced",
        "left alone on purpose",
    ] {
        assert!(out.contains(needle), "missing {needle:?} in:\n{out}");
    }
    // The skill usage counter named qartez is not an MCP server and is not in the plan.
    assert!(!out.contains("skillUsage"), "{out}");
}

#[test]
fn apply_changes_only_the_intended_keys_and_rollback_restores_every_byte() {
    let h = Home::seeded();
    let before = h.snapshot();
    let fd = h.home.join(".local/bin/fdindex").to_string_lossy().to_string();

    let report = h.ok(&["--apply"]);
    assert!(report.contains("switched over"), "{report}");
    let after = h.snapshot();

    // Settings: the three hook commands and the server, nothing else.
    for profile in [".claude", ".claude-radify"] {
        let rel = format!("{profile}/settings.json");
        let changes = changed_lines(&before[&h.home.join(&rel)], &after[&h.home.join(&rel)]);
        let new: Vec<&str> = changes.iter().map(|(_, a)| a.as_str()).collect();
        assert_eq!(changes.len(), 5, "{changes:#?}");
        assert!(new.iter().any(|l| l.contains(&format!("\"{fd} guard\""))));
        assert!(new.iter().any(|l| l.contains(&format!("\"{fd} session-start\""))));
        assert!(new.contains(&"\"args\": [\"mcp\"],") && new.contains(&format!("\"command\": \"{fd}\"").as_str()), "{new:?}");
        assert!(after[&h.home.join(&rel)].contains("grep-guard"), "unrelated hooks stay");
    }
    // ~/.claude.json: one server entry changed; the skill counter named qartez and 1.0 are untouched.
    let cj = changed_lines(&before[&h.home.join(".claude.json")], &after[&h.home.join(".claude.json")]);
    assert_eq!(cj.len(), 2, "{cj:#?}");
    assert!(after[&h.home.join(".claude.json")].contains("\"ratio\": 1.0") && after[&h.home.join(".claude.json")].contains("\"usageCount\": 149"));
    let v: serde_json::Value = serde_json::from_str(&h.read(".claude.json")).unwrap();
    assert_eq!(v["mcpServers"]["qartez"]["command"], fd.as_str());
    assert_eq!(v["mcpServers"]["qartez"]["args"], serde_json::json!(["mcp"]));
    assert_eq!(v["mcpServers"]["other"]["command"], "npx");
    // Codex: two lines; the per-tool tables and the markers are as they were.
    let codex = h.read(".codex/config.toml");
    assert_eq!(changed_lines(&before[&h.home.join(".codex/config.toml")], &codex).len(), 2);
    assert!(codex.contains(&format!("command = \"{fd}\"")) && codex.contains("args = [\"mcp\"]"));
    assert!(codex.contains("[mcp_servers.qartez.tools.qartez_add_root]\napproval_mode = \"approve\""));
    assert!(codex.contains("# <qartez-mcp-begin>") && codex.contains("# <qartez-mcp-end>"));
    // opencode keeps its array layout; zed, cursor, gemini change the same way.
    assert!(h.read(".config/opencode/opencode.json").contains(&format!("\"command\": [\n        \"{fd}\",\n        \"mcp\"\n      ]")));
    assert!(h.read(".config/zed/settings.json").contains("\"args\": [\"mcp\"]"));
    assert!(h.read(".gemini/settings.json").contains(&format!("\"{fd} guard\"")));
    // The binary, the alias and the kept original.
    assert!(h.home.join(".local/bin/fdindex").is_file());
    assert_eq!(after[&h.home.join(".local/bin/qartez")], "-> fdindex");
    assert_eq!(after[&h.home.join(".local/bin/qartez.orig")], "#!/bin/sh\necho the old qartez\n");
    assert_eq!(after[&h.home.join(".local/bin/qartez-guard")], "#!/bin/sh\necho the old guard\n", "the old guard binary is left where it was");
    // The skill: overlaid, and the other references are left in place.
    assert!(h.read(".claude/skills/qartez/SKILL.md").contains("Flight Deck's index"));
    assert!(!h.read(".claude/skills/qartez/references/runtime-contract.md").contains("status.json`)\n"));
    assert_eq!(h.read(".claude/skills/qartez/references/doctrine-explore.md"), "doctrine stays\n");
    // The alias really is an MCP server (the apply itself checked; check again from outside).
    let mut alias = Command::new(h.home.join(".local/bin/qartez"));
    alias.env("FLIGHTDECK_INDEX_NO_START", "1").stdin(std::process::Stdio::piped()).stdout(std::process::Stdio::piped());
    let mut child = alias.spawn().unwrap();
    use std::io::Write;
    writeln!(child.stdin.take().unwrap(), r#"{{"jsonrpc":"2.0","id":1,"method":"initialize","params":{{}}}}"#).unwrap();
    assert!(String::from_utf8_lossy(&child.wait_with_output().unwrap().stdout).contains("serverInfo"));

    // A second apply has nothing to do.
    assert!(h.ok(&["--apply"]).contains("already switched over"));

    // Rollback: every file byte-identical to the seed; nothing new left behind.
    let report = h.ok(&["--rollback"]);
    assert!(report.contains("original bytes restored"), "{report}");
    let mut restored = h.snapshot();
    restored.retain(|p, _| !p.starts_with(&h.store));
    assert_eq!(restored, before);
    let again = h.run(&["--rollback"]);
    assert_eq!(again.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&again.stderr).contains("nothing to roll back"));
}

#[test]
fn rollback_after_a_running_claude_rewrote_its_file_reverts_only_our_values() {
    let h = Home::seeded();
    h.ok(&["--apply"]);
    // Claude Code rewrites ~/.claude.json all the time: it bumps counters and adds projects.
    let path = h.home.join(".claude.json");
    let now = std::fs::read_to_string(&path).unwrap().replace("\"numStartups\": 12", "\"numStartups\": 13, \"newKey\": [1, 2]");
    std::fs::write(&path, &now).unwrap();
    let report = h.ok(&["--rollback"]);
    assert!(report.contains("changed since apply"), "{report}");
    let back = std::fs::read_to_string(&path).unwrap();
    assert_eq!(back, CLAUDE_JSON.replace("HOME", h.home.to_str().unwrap()).replace("\"numStartups\": 12", "\"numStartups\": 13, \"newKey\": [1, 2]"));
}

#[test]
fn apply_survives_a_writer_rewriting_the_file_all_the_while() {
    let h = Home::seeded();
    let path = h.home.join(".claude.json");
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let writer = {
        let (path, stop) = (path.clone(), stop.clone());
        std::thread::spawn(move || {
            // Like Claude Code: read the file, bump a counter, write it back whole.
            let mut n = 0u64;
            while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                if let Ok(text) = std::fs::read_to_string(&path) {
                    n += 1;
                    let bumped = match text.find("\"numStartups\": ") {
                        Some(i) => {
                            let end = i + text[i..].find(',').unwrap();
                            format!("{}\"numStartups\": {n}{}", &text[..i], &text[end..])
                        }
                        None => text,
                    };
                    let tmp = path.with_extension("w.tmp");
                    std::fs::write(&tmp, bumped).unwrap();
                    std::fs::rename(&tmp, &path).unwrap();
                }
                std::thread::sleep(std::time::Duration::from_millis(1));
            }
        })
    };
    let out = h.run(&["--apply"]);
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    writer.join().unwrap();
    assert!(out.status.success(), "{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    let v: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(v["mcpServers"]["qartez"]["args"], serde_json::json!(["mcp"]));
    assert!(v["numStartups"].as_u64().unwrap() > 12, "the writer's changes survived");
}

#[test]
fn a_config_that_is_not_json_stops_the_apply_before_anything_changes() {
    let h = Home::seeded();
    std::fs::write(h.home.join(".claude.json"), "{ not json").unwrap();
    let before = h.snapshot();
    let o = h.run(&["--apply"]);
    assert!(!o.status.success());
    assert!(String::from_utf8_lossy(&o.stderr).contains(".claude.json"), "{}", String::from_utf8_lossy(&o.stderr));
    assert_eq!(h.snapshot(), before);
}

#[test]
fn a_step_that_fails_midway_rolls_the_whole_apply_back() {
    use std::os::unix::fs::PermissionsExt;
    let h = Home::seeded();
    let before = h.snapshot();
    // The last step (the skill overlay) cannot write into a read-only directory.
    let skill = h.home.join(".claude-radify/skills/qartez");
    std::fs::set_permissions(&skill, std::fs::Permissions::from_mode(0o555)).unwrap();
    let o = h.run(&["--apply"]);
    std::fs::set_permissions(&skill, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(!o.status.success());
    let err = String::from_utf8_lossy(&o.stderr).to_string();
    assert!(err.contains("rolled back"), "{err}");
    let mut now = h.snapshot();
    now.retain(|p, _| !p.starts_with(&h.store));
    assert_eq!(now, before, "{err}");
}

#[test]
fn list_old_dbs_lists_with_sizes_and_deletes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    for (repo, size) in [("a", 3000usize), ("b/nested", 9000), ("node_modules/x", 5000)] {
        let q = root.join(repo).join(".qartez");
        std::fs::create_dir_all(&q).unwrap();
        std::fs::write(q.join("index.db"), vec![0u8; size]).unwrap();
        std::fs::write(q.join("index.db-wal"), vec![0u8; 100]).unwrap();
    }
    let o = Command::new(BIN).args(["switchover", "--list-old-dbs", root.to_str().unwrap()]).output().unwrap();
    let out = String::from_utf8_lossy(&o.stdout).to_string();
    assert!(o.status.success(), "{out}");
    let lines: Vec<&str> = out.lines().collect();
    assert!(lines[0].contains("b/nested/.qartez/index.db") && lines[1].contains("a/.qartez/index.db"), "{out}");
    assert!(out.contains("2 database(s)") && !out.contains("node_modules"), "{out}");
    assert!(out.contains("Nothing was deleted"));
    assert!(root.join("a/.qartez/index.db").exists() && root.join("b/nested/.qartez/index.db").exists());
}
