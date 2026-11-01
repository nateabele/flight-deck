//! `fdindex` started under the name `qartez` (spec §11a: the alias is the same binary, installed
//! only at switch-over). Existing skills, hooks and MCP configs call `qartez mcp`, `qartez find …`
//! and `qartez --root <dir> find …`; this rewrites such an argv into the `fdindex` one before it is
//! parsed, so there is a single parser and the alias cannot drift from the real verbs.
//!
//! Only the way in is rewritten. Qartez's own indexing options (`--reindex`, `--no-watch`,
//! `--git-depth`, …) mean nothing to a daemon that owns the index, so they are accepted and dropped
//! before the verb rather than failing an agent's launch line.

/// Qartez global flags that take a value and have no meaning here.
const IGNORED_WITH_VALUE: &[&str] = &["--git-depth", "--db-path", "--log-level", "--wiki", "--leiden-resolution"];
/// Qartez global flags that are switches and have no meaning here.
const IGNORED_SWITCHES: &[&str] = &["--reindex", "--no-watch"];

/// True when `argv0` names the `qartez` alias.
pub fn is_alias(argv0: &str) -> bool {
    // `qartez-mcp` is the name the old install also linked to the binary.
    std::path::Path::new(argv0).file_name().is_some_and(|n| n == "qartez" || n == "qartez-mcp")
}

/// `args` is argv without the program name. Returned unchanged unless started as `qartez`.
/// `--root DIR` becomes `--cwd DIR` (the first one; qartez's extra roots are only hints here), and
/// no verb at all means the MCP server, as it does for qartez.
pub fn normalize(argv0: &str, args: Vec<String>) -> Vec<String> {
    if !is_alias(argv0) {
        return args;
    }
    let mut out = Vec::new();
    let mut verb_seen = false;
    let mut root_seen = false;
    let mut it = args.into_iter();
    while let Some(a) = it.next() {
        let (flag, inline) = match a.split_once('=') {
            Some((f, v)) if f.starts_with("--") => (f.to_string(), Some(v.to_string())),
            _ => (a.clone(), None),
        };
        if flag == "--root" {
            let value = inline.or_else(|| it.next());
            if let (Some(v), false) = (value, root_seen) {
                out.extend(["--cwd".to_string(), v]);
                root_seen = true;
            }
        } else if !verb_seen && IGNORED_SWITCHES.contains(&flag.as_str()) {
        } else if !verb_seen && IGNORED_WITH_VALUE.contains(&flag.as_str()) {
            if inline.is_none() {
                it.next();
            }
        } else if !verb_seen && flag == "--format" {
            // Qartez's global `--format json` is `--json` here; human and compact are the default.
            if inline.or_else(|| it.next()).as_deref() == Some("json") {
                out.push("--json".to_string());
            }
        } else {
            verb_seen |= !a.starts_with('-');
            out.push(a);
        }
    }
    if !verb_seen {
        out.push("mcp".to_string());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn norm(argv0: &str, args: &[&str]) -> Vec<String> {
        normalize(argv0, args.iter().map(|s| s.to_string()).collect())
    }

    #[test]
    fn other_names_are_left_alone() {
        assert_eq!(norm("/usr/bin/fdindex", &["--root", "/x", "find", "a"]), ["--root", "/x", "find", "a"]);
    }

    #[test]
    fn qartez_mcp_is_the_alias_too() {
        assert_eq!(norm("/home/n/.local/bin/qartez-mcp", &[]), ["mcp"]);
    }

    #[test]
    fn qartez_verbs_are_fdindex_verbs() {
        assert_eq!(norm("qartez", &["mcp"]), ["mcp"]);
        assert_eq!(norm("/home/n/.local/bin/qartez", &["find", "update", "--kind", "function"]), ["find", "update", "--kind", "function"]);
    }

    #[test]
    fn root_becomes_cwd_wherever_it_appears() {
        assert_eq!(norm("qartez", &["--root", "/work/app", "find", "x"]), ["--cwd", "/work/app", "find", "x"]);
        assert_eq!(norm("qartez", &["--root=/work/app", "find", "x"]), ["--cwd", "/work/app", "find", "x"]);
        assert_eq!(norm("qartez", &["find", "x", "--root", "/work/app"]), ["find", "x", "--cwd", "/work/app"]);
        assert_eq!(norm("qartez", &["--root", "/a", "--root", "/b", "mcp"]), ["--cwd", "/a", "mcp"]);
    }

    #[test]
    fn no_verb_starts_the_mcp_server_like_qartez() {
        assert_eq!(norm("qartez", &[]), ["mcp"]);
        assert_eq!(norm("qartez", &["--root", "/w", "--no-watch", "--git-depth", "300"]), ["--cwd", "/w", "mcp"]);
    }

    #[test]
    fn qartez_indexing_options_are_dropped_before_the_verb_only() {
        assert_eq!(norm("qartez", &["--reindex", "--git-depth=50", "--log-level", "warn", "mcp"]), ["mcp"]);
        assert_eq!(norm("qartez", &["find", "x", "--git-depth", "3"]), ["find", "x", "--git-depth", "3"]);
        assert_eq!(norm("qartez", &["--format", "json", "stats"]), ["--json", "stats"]);
        assert_eq!(norm("qartez", &["--format", "human", "stats"]), ["stats"]);
    }
}
