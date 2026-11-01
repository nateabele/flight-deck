//! Editing other programs' config files without disturbing the rest of them.
//!
//! `~/.claude.json` is 240 kB of one app's state, rewritten by every running Claude process, so a
//! parse-and-reserialise would reorder keys, change number formats and reindent the lot. These
//! helpers instead find the **byte span** of the values to change (`parse` records where every
//! node starts and ends) and splice new text in; every other byte of the file stays as it was.
//! `replace_file` swaps the result in atomically and refuses to when the file changed since it
//! was read.

use std::path::Path;

#[derive(Debug, Clone)]
pub struct Node {
    pub start: usize,
    pub end: usize,
    pub kind: Kind,
}

#[derive(Debug, Clone)]
pub enum Kind {
    Obj(Vec<(String, Node)>),
    Arr(Vec<Node>),
    Str(String),
    Other,
}

impl Node {
    pub fn get(&self, key: &str) -> Option<&Node> {
        match &self.kind {
            Kind::Obj(members) => members.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    /// Follow object keys and array indexes (`"3"`).
    pub fn at(&self, path: &[String]) -> Option<&Node> {
        let Some((head, rest)) = path.split_first() else { return Some(self) };
        let next = match &self.kind {
            Kind::Obj(_) => self.get(head)?,
            Kind::Arr(items) => items.get(head.parse::<usize>().ok()?)?,
            _ => return None,
        };
        next.at(rest)
    }

    pub fn as_str(&self) -> Option<&str> {
        match &self.kind {
            Kind::Str(s) => Some(s),
            _ => None,
        }
    }

    pub fn text<'a>(&self, doc: &'a str) -> &'a str {
        &doc[self.start..self.end]
    }
}

/// Every string value under `node` stored under a key called `key`, with its path from `node`.
pub fn strings_under_key<'a>(node: &'a Node, key: &str) -> Vec<(Vec<String>, &'a Node)> {
    fn walk<'a>(n: &'a Node, key: &str, path: &mut Vec<String>, out: &mut Vec<(Vec<String>, &'a Node)>) {
        match &n.kind {
            Kind::Obj(members) => {
                for (k, v) in members {
                    path.push(k.clone());
                    if k == key && matches!(v.kind, Kind::Str(_)) {
                        out.push((path.clone(), v));
                    }
                    walk(v, key, path, out);
                    path.pop();
                }
            }
            Kind::Arr(items) => {
                for (i, v) in items.iter().enumerate() {
                    path.push(i.to_string());
                    walk(v, key, path, out);
                    path.pop();
                }
            }
            _ => {}
        }
    }
    let mut out = Vec::new();
    walk(node, key, &mut Vec::new(), &mut out);
    out
}

pub fn parse(doc: &str) -> Result<Node, String> {
    // Strict JSON first, so the scanner below can assume well-formed input.
    serde_json::from_str::<serde_json::Value>(doc).map_err(|e| format!("not valid JSON: {e}"))?;
    let mut p = Parser { s: doc.as_bytes(), doc, i: 0 };
    p.value()
}

struct Parser<'a> {
    s: &'a [u8],
    doc: &'a str,
    i: usize,
}

impl Parser<'_> {
    fn ws(&mut self) {
        while self.i < self.s.len() && self.s[self.i].is_ascii_whitespace() {
            self.i += 1;
        }
    }

    fn string_end(&self) -> usize {
        let mut j = self.i + 1;
        while self.s[j] != b'"' {
            j += if self.s[j] == b'\\' { 2 } else { 1 };
        }
        j + 1
    }

    fn value(&mut self) -> Result<Node, String> {
        self.ws();
        let start = self.i;
        let kind = match self.s.get(self.i) {
            Some(b'{') => {
                self.i += 1;
                let mut members = Vec::new();
                loop {
                    self.ws();
                    match self.s[self.i] {
                        b'}' => {
                            self.i += 1;
                            break;
                        }
                        b',' => self.i += 1,
                        _ => {
                            let key = self.value()?;
                            let Kind::Str(key) = key.kind else { return Err("object key is not a string".into()) };
                            self.ws();
                            self.i += 1; // ':'
                            members.push((key, self.value()?));
                        }
                    }
                }
                Kind::Obj(members)
            }
            Some(b'[') => {
                self.i += 1;
                let mut items = Vec::new();
                loop {
                    self.ws();
                    match self.s[self.i] {
                        b']' => {
                            self.i += 1;
                            break;
                        }
                        b',' => self.i += 1,
                        _ => items.push(self.value()?),
                    }
                }
                Kind::Arr(items)
            }
            Some(b'"') => {
                let end = self.string_end();
                let decoded: String = serde_json::from_str(&self.doc[start..end]).map_err(|e| e.to_string())?;
                self.i = end;
                Kind::Str(decoded)
            }
            Some(_) => {
                while self.i < self.s.len() && !matches!(self.s[self.i], b',' | b'}' | b']') && !self.s[self.i].is_ascii_whitespace() {
                    self.i += 1;
                }
                Kind::Other
            }
            None => return Err("unexpected end of input".into()),
        };
        Ok(Node { start, end: self.i, kind })
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Edit {
    pub start: usize,
    pub end: usize,
    pub text: String,
}

/// Splice `edits` (which must not overlap) into `doc`.
pub fn apply(doc: &str, edits: &[Edit]) -> String {
    let mut sorted: Vec<&Edit> = edits.iter().collect();
    sorted.sort_by_key(|e| e.start);
    let mut out = String::with_capacity(doc.len());
    let mut at = 0;
    for e in sorted {
        out.push_str(&doc[at..e.start]);
        out.push_str(&e.text);
        at = e.end;
    }
    out.push_str(&doc[at..]);
    out
}

/// The lines of `doc` that the byte range touches, without their newlines.
pub fn lines_of(doc: &str, start: usize, end: usize) -> Vec<String> {
    let from = doc[..start].rfind('\n').map_or(0, |i| i + 1);
    let to = doc[end..].find('\n').map_or(doc.len(), |i| end + i);
    doc[from..to].lines().map(str::to_string).collect()
}

pub fn line_number(doc: &str, at: usize) -> usize {
    doc[..at].matches('\n').count() + 1
}

/// A JSON string literal.
pub fn quote(s: &str) -> String {
    serde_json::to_string(s).expect("a string always serialises")
}

/// What a file looked like when it was read, to notice a concurrent writer.
#[derive(Debug, Clone, PartialEq)]
pub struct Stamp {
    pub len: u64,
    pub modified: Option<std::time::SystemTime>,
    pub sha: String,
}

pub fn sha1_hex(bytes: &[u8]) -> String {
    use sha1::{Digest, Sha1};
    Sha1::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

pub fn read_stamped(path: &Path) -> std::io::Result<(Vec<u8>, Stamp)> {
    let meta = std::fs::metadata(path)?;
    let bytes = std::fs::read(path)?;
    let stamp = Stamp { len: bytes.len() as u64, modified: meta.modified().ok(), sha: sha1_hex(&bytes) };
    Ok((bytes, stamp))
}

/// Replace `path`'s content with `new` unless the file is no longer what `read` saw: the new bytes
/// go to a temporary file beside it (same permissions), the original is stat'ed and hashed once
/// more, and only then is the temporary renamed over it. `Ok(false)` means "it changed, read it
/// again". The window between that last check and the rename is a few microseconds and cannot be
/// closed without a lock the other writers do not take; the caller verifies afterwards.
pub fn replace_file(path: &Path, new: &[u8], read: &Stamp) -> std::io::Result<bool> {
    // A symlinked config is edited where it points.
    let target = std::fs::canonicalize(path)?;
    let tmp = target.with_file_name(format!(".{}.fdindex-switchover.tmp", target.file_name().map(|n| n.to_string_lossy()).unwrap_or_default()));
    std::fs::write(&tmp, new)?;
    std::fs::set_permissions(&tmp, std::fs::metadata(&target)?.permissions())?;
    let now = read_stamped(&target)?.1;
    if now != *read {
        let _ = std::fs::remove_file(&tmp);
        return Ok(false);
    }
    std::fs::rename(&tmp, &target)?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    const DOC: &str = "{\n  \"a\": 1.0,\n  \"mcpServers\": {\n    \"qartez\": {\"args\": [], \"command\": \"/x/qartez\"}\n  },\n  \"hooks\": [ {\"command\": \"/x/qartez-guard\", \"timeout\": 3000} ]\n}\n";

    #[test]
    fn spans_point_at_the_values_and_splicing_leaves_every_other_byte_alone() {
        let root = parse(DOC).unwrap();
        let cmd = root.at(&["mcpServers".into(), "qartez".into(), "command".into()]).unwrap();
        assert_eq!(cmd.text(DOC), "\"/x/qartez\"");
        let args = root.at(&["mcpServers".into(), "qartez".into(), "args".into()]).unwrap();
        let out = apply(DOC, &[Edit { start: cmd.start, end: cmd.end, text: quote("/y/fdindex") }, Edit { start: args.start, end: args.end, text: "[\"mcp\"]".into() }]);
        assert_eq!(out, DOC.replace("\"/x/qartez\"", "\"/y/fdindex\"").replace("[]", "[\"mcp\"]"));
        assert!(out.contains("1.0"), "number formatting is untouched");
        let hooks = strings_under_key(&root, "command");
        assert_eq!(hooks.iter().map(|(p, n)| (p.join("/"), n.as_str().unwrap().to_string())).collect::<Vec<_>>(), [
            ("mcpServers/qartez/command".to_string(), "/x/qartez".to_string()),
            ("hooks/0/command".to_string(), "/x/qartez-guard".to_string())
        ]);
        assert_eq!(root.at(&["hooks".into(), "0".into(), "timeout".into()]).unwrap().text(DOC), "3000");
    }

    #[test]
    fn strings_with_escapes_and_braces_inside_do_not_confuse_the_scanner() {
        let doc = r#"{"k": "a \" } ] , b", "n": [1, "x\\", {"z": null}], "c": "v"}"#;
        let root = parse(doc).unwrap();
        assert_eq!(root.get("c").unwrap().as_str(), Some("v"));
        assert_eq!(root.get("k").unwrap().as_str(), Some("a \" } ] , b"));
        assert!(parse("{not json").is_err());
    }

    #[test]
    fn replace_file_refuses_when_the_file_changed_after_it_was_read() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("c.json");
        std::fs::write(&p, "one").unwrap();
        let (_, stamp) = read_stamped(&p).unwrap();
        std::fs::write(&p, "two").unwrap();
        assert!(!replace_file(&p, b"new", &stamp).unwrap());
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "two");
        let (_, stamp) = read_stamped(&p).unwrap();
        assert!(replace_file(&p, b"new", &stamp).unwrap());
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "new");
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 1, "no temporary file is left");
    }

    #[test]
    fn lines_of_gives_the_whole_lines_a_range_touches() {
        let doc = "a\nbb cc\nd\n";
        assert_eq!(lines_of(doc, 3, 5), ["bb cc"]);
        assert_eq!(line_number(doc, 3), 2);
    }
}
