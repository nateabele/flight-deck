//! Risk acknowledgements: the file that tells `fdindex guard` an agent has looked at what an edit of
//! a load-bearing file would break (the `impact` tool writes one on every call).
//!
//! The layout is qartez's, which the guard hook has always read, so the old `qartez-guard` and
//! this one accept each other's acks while a machine is switching over (contract doc, "The
//! acknowledgement gate"): `<worktree>/.qartez/acks/<fnv1a64(relative path)>`, the hash as 16
//! lowercase hex digits, the content `<unix seconds>\n<relative path>\n`. Freshness is the file's
//! **mtime**, not the number inside it.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// How long an ack lets an edit through (the old guard's default).
pub const DEFAULT_TTL: Duration = Duration::from_secs(600);

/// FNV-1a, 64 bits, over the UTF-8 bytes of `s`.
pub fn fnv1a64(s: &str) -> u64 {
    s.bytes().fold(0xcbf29ce484222325, |h, b| (h ^ u64::from(b)).wrapping_mul(0x100000001b3))
}

/// Where the ack for `rel` (the path relative to `worktree`, `/`-separated) lives.
pub fn path(worktree: &Path, rel: &str) -> PathBuf {
    worktree.join(".qartez/acks").join(format!("{:016x}", fnv1a64(rel)))
}

/// Record that `rel` was reviewed just now. Rewriting an existing ack refreshes its mtime.
pub fn write(worktree: &Path, rel: &str) -> std::io::Result<PathBuf> {
    let p = path(worktree, rel);
    std::fs::create_dir_all(p.parent().expect("an ack path has a parent"))?;
    let secs = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let mut f = std::fs::File::create(&p)?;
    write!(f, "{secs}\n{rel}\n")?;
    Ok(p)
}

/// Is there an ack for `rel` no older than `ttl`?
pub fn is_fresh(worktree: &Path, rel: &str, ttl: Duration, now: SystemTime) -> bool {
    std::fs::metadata(path(worktree, rel))
        .and_then(|m| m.modified())
        // A modified time in the future (clock skew) counts as fresh: the ack was just written.
        .is_ok_and(|t| now.duration_since(t).map(|age| age <= ttl).unwrap_or(true))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_name_is_fnv1a64_of_the_relative_path_as_the_old_guard_wrote_it() {
        // Observed from `qartez-guard`'s own acks in a scratch checkout: `src/core.ts` is this name.
        assert_eq!(format!("{:016x}", fnv1a64("src/core.ts")), "f4e20d6810cc9444");
        assert_eq!(fnv1a64(""), 0xcbf29ce484222325);
    }

    #[test]
    fn a_written_ack_is_fresh_until_its_ttl_and_has_the_documented_content() {
        let dir = tempfile::tempdir().unwrap();
        let p = write(dir.path(), "src/a.rs").unwrap();
        assert_eq!(p, path(dir.path(), "src/a.rs"));
        let body = std::fs::read_to_string(&p).unwrap();
        let (secs, rel) = body.split_once('\n').unwrap();
        assert!(secs.parse::<u64>().is_ok());
        assert_eq!(rel, "src/a.rs\n");
        let now = SystemTime::now();
        assert!(is_fresh(dir.path(), "src/a.rs", DEFAULT_TTL, now));
        assert!(is_fresh(dir.path(), "src/a.rs", DEFAULT_TTL, now + Duration::from_secs(598)));
        assert!(!is_fresh(dir.path(), "src/a.rs", DEFAULT_TTL, now + Duration::from_secs(700)));
        assert!(!is_fresh(dir.path(), "src/other.rs", DEFAULT_TTL, now));
    }
}
