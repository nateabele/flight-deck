//! Python module paths: which file does `import a.b` or `from ..x import y` land on?

use super::{join_rel, normalize_rel, Resolved, Resolver};
use std::path::Path;

impl Resolver {
    /// `spec` is the module as written, leading dots included (`.util`, `..pkg.mod`, `app.core`).
    pub fn python_module(&self, from: &str, spec: &str) -> Resolved {
        let dots = spec.chars().take_while(|c| *c == '.').count();
        let rest = spec[dots..].replace('.', "/");
        let from_dir = Path::new(from).parent().unwrap_or(Path::new(""));
        if dots > 0 {
            // One dot is the importing file's own package; each further dot climbs one level.
            let up = "../".repeat(dots - 1);
            let Some(base) = normalize_rel(&join_rel(from_dir, &up)) else { return Resolved::Unresolved };
            return self.python_under(&base, &rest);
        }
        // Absolute: Python's import root is wherever the interpreter was started or `src/` was put
        // on the path, which a repository does not record. Every ancestor directory of the
        // importing file (and its `src/`) is a plausible root, nearest first, so a sibling
        // `scripts/` package, a monorepo subproject and a top-level `src/` layout all resolve.
        let mut dir = Some(from_dir);
        while let Some(d) = dir {
            for root in [d.to_path_buf(), d.join("src")] {
                let base = root.to_string_lossy().replace(std::path::MAIN_SEPARATOR, "/");
                if let found @ Resolved::File { .. } = self.python_under(&base, &rest) {
                    return found;
                }
            }
            dir = d.parent();
        }
        Resolved::Unresolved
    }

    /// `<base>/<rest>.py` or the package `<base>/<rest>/__init__.py` (`rest` empty: the package).
    fn python_under(&self, base: &str, rest: &str) -> Resolved {
        let stem = join_rel(Path::new(base), rest);
        let stem = stem.trim_end_matches('/');
        let candidates = if rest.is_empty() {
            vec![join_rel(Path::new(stem), "__init__.py")]
        } else {
            vec![format!("{stem}.py"), format!("{stem}/__init__.py")]
        };
        for c in candidates {
            if self.paths.contains(&c) {
                return Resolved::File { path: c, rest: vec![] };
            }
        }
        Resolved::Unresolved
    }
}
