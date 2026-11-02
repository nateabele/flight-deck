//! A framework's Objective-C and C headers with its API notes, read the way the Clang importer
//! names them in Swift. Line-based: Apple's headers put each `@interface`, `@property`, method,
//! enum and function head on its own line, which is all the names need.

use super::{PkgKind, Sdk, SwiftModule};
use std::collections::HashMap;
use std::path::Path;

/// What a module's API notes rename: top-level C names, and members per class or protocol.
#[derive(Default)]
struct ApiNotes {
    /// C name -> Swift name (`""` when the notes hide it from Swift).
    top: HashMap<String, String>,
    /// (class, property or selector) -> Swift name.
    members: HashMap<(String, String), String>,
}

/// Read the parts of an API notes file the names use. The YAML is regular enough to read by
/// indentation: each top-level entry is `- Name: X` in a section, its members are `- Name:` or
/// `- Selector:` entries one level deeper, and `SwiftVersions:` (renames for older Swift
/// versions) ends what applies.
fn api_notes(text: &str) -> ApiNotes {
    let mut n = ApiNotes::default();
    let mut top_indent: Option<usize> = None;
    let mut cur_top: Option<String> = None;
    let mut cur_member: Option<String> = None;
    let mut member_indent = usize::MAX;
    for raw in text.lines() {
        if raw.starts_with("SwiftVersions:") {
            break;
        }
        let indent = raw.len() - raw.trim_start().len();
        let line = raw.trim();
        let (is_item, body) = match line.strip_prefix("- ") {
            Some(b) => (true, b),
            None => (false, line),
        };
        let Some((k, v)) = body.split_once(':') else { continue };
        let v = v.trim().trim_matches('\'').trim_matches('"').to_string();
        let target = |cur_member: &Option<String>| match (&cur_top, cur_member) {
            (Some(t), Some(mm)) if indent > member_indent => Some((t.clone(), Some(mm.clone()))),
            (Some(t), _) => Some((t.clone(), None)),
            _ => None,
        };
        match (is_item, k.trim()) {
            (true, "Name" | "Selector") => {
                let ti = *top_indent.get_or_insert(indent);
                if indent <= ti {
                    cur_top = Some(v);
                    cur_member = None;
                    member_indent = usize::MAX;
                } else {
                    cur_member = Some(v);
                    member_indent = indent;
                }
            }
            (false, "SwiftName") => {
                let swift = v.split('(').next().unwrap_or("").to_string();
                match target(&cur_member) {
                    Some((t, Some(mm))) => {
                        n.members.insert((t, mm), swift);
                    }
                    Some((t, None)) => {
                        n.top.insert(t, swift);
                    }
                    None => {}
                }
            }
            (false, "SwiftPrivate") | (false, "Availability") if v == "true" || v == "nonswift" => match target(&cur_member) {
                Some((t, Some(mm))) => {
                    n.members.insert((t, mm), String::new());
                }
                Some((t, None)) => {
                    n.top.insert(t, String::new());
                }
                None => {}
            },
            _ => {}
        }
    }
    n
}

/// `X` of `NS_SWIFT_NAME(X)` / `CF_SWIFT_NAME(X)` / `swift_name("X")`, base name only.
fn swift_name_attr(s: &str) -> Option<String> {
    for pat in ["NS_SWIFT_NAME(", "CF_SWIFT_NAME(", "swift_name(\""] {
        if let Some(i) = s.find(pat) {
            let rest = &s[i + pat.len()..];
            let end = rest.find(['(', ')', '"']).unwrap_or(rest.len());
            let n = rest[..end].trim();
            if !n.is_empty() {
                return Some(n.to_string());
            }
        }
    }
    None
}

fn unavailable(s: &str) -> bool {
    s.contains("NS_SWIFT_UNAVAILABLE")
        || s.contains("NS_UNAVAILABLE")
        || s.contains("CF_SWIFT_UNAVAILABLE")
        || s.contains("API_UNAVAILABLE(macos")
        || s.contains("__attribute__((unavailable")
}

/// `text` without its `/* ... */` and `// ...` comments (newlines kept, so lines stay lines):
/// prose in a comment would otherwise read as declarations (`the files` became a function).
fn strip_comments(text: &str) -> String {
    let b = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    let mut start = 0;
    while i < b.len() {
        match (b[i], b.get(i + 1)) {
            (b'"', _) => {
                i += 1;
                while i < b.len() && b[i] != b'"' && b[i] != b'\n' {
                    i += if b[i] == b'\\' { 2 } else { 1 };
                }
                i += 1;
            }
            (b'/', Some(b'*')) => {
                out.push_str(&text[start..i]);
                let end = text[i + 2..].find("*/").map(|e| i + 2 + e + 2).unwrap_or(b.len());
                out.extend(text[i..end].chars().filter(|c| *c == '\n'));
                out.push(' ');
                i = end;
                start = i;
            }
            (b'/', Some(b'/')) => {
                out.push_str(&text[start..i]);
                i = text[i..].find('\n').map(|e| i + e).unwrap_or(b.len());
                start = i;
            }
            _ => i += 1,
        }
    }
    out.push_str(&text[start.min(b.len())..]);
    out
}

fn idents(s: &str) -> Vec<&str> {
    s.split(|c: char| !(c.is_alphanumeric() || c == '_')).filter(|w| !w.is_empty()).collect()
}

/// Is `w` an attribute macro or keyword rather than a declared name?
fn is_macroish(w: &str) -> bool {
    (w.len() > 1 && w.chars().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_'))
        || matches!(
            w,
            "const" | "struct" | "enum" | "union" | "unsigned" | "signed" | "extern" | "static" | "inline" | "typedef" | "void" | "nonnull"
                | "nullable" | "_Nonnull" | "_Nullable" | "_Null_unspecified" | "__kindof" | "instancetype" | "id" | "nonatomic"
        )
        || w.starts_with("__")
}

/// The camelCase words of an identifier: `URLByAppending` -> `URL`, `By`, `Appending`.
fn words(s: &str) -> Vec<&str> {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut start = 0;
    for i in 1..b.len() {
        let up = b[i].is_ascii_uppercase();
        let prev_up = b[i - 1].is_ascii_uppercase();
        let next_low = b.get(i + 1).is_some_and(|c| c.is_ascii_lowercase());
        if (up && (!prev_up || next_low)) || (b[i].is_ascii_digit() && !b[i - 1].is_ascii_digit()) {
            out.push(&s[start..i]);
            start = i;
        }
    }
    out.push(&s[start..]);
    out
}

const PREPOSITIONS: &[&str] = &[
    "At", "With", "For", "From", "To", "In", "Of", "By", "On", "Using", "Into", "Onto", "Within", "Without", "As", "Before", "After",
    "Since", "Until", "Like", "Over", "Under", "Between", "Through", "Inside", "Along", "Than", "Via", "Upon", "Across", "Toward", "Towards",
];

/// `NSFileManager` -> `File`, `Manager`: a type's words without its two- or three-letter prefix,
/// as omit-needless-words matches them.
fn type_words(ty: &str) -> Vec<&str> {
    let w = words(ty);
    if w.len() > 1 && w[0].len() >= 2 && w[0].chars().all(|c| c.is_ascii_uppercase()) { w[1..].to_vec() } else { w }
}

/// `URLForKey` -> `urlForKey`: a leading acronym is lowered whole.
fn lower_first(s: &str) -> String {
    let w = words(s);
    match w.first() {
        Some(f) if f.len() > 1 && f.chars().all(|c| c.is_ascii_uppercase()) => format!("{}{}", f.to_lowercase(), &s[f.len()..]),
        _ => {
            let mut c = s.chars();
            match c.next() {
                Some(f) => f.to_lowercase().collect::<String>() + c.as_str(),
                None => String::new(),
            }
        }
    }
}

/// Drop the trailing words of `w` that repeat the trailing words of type `ty`; `true` if any did.
fn prune_type_suffix(w: &mut Vec<&str>, ty: &str) -> bool {
    let tw = type_words(ty);
    let (mut n, mut t) = (w.len(), tw.len());
    while n > 1 && t > 0 && w[n - 1].eq_ignore_ascii_case(tw[t - 1]) {
        n -= 1;
        t -= 1;
    }
    // A name that is all type (`processInfo` of `NSProcessInfo`) keeps every word.
    if n == 1 && t > 0 && w[0].eq_ignore_ascii_case(tw[t - 1]) {
        return false;
    }
    let pruned = n < w.len();
    w.truncate(n);
    pruned
}

/// A reduced omit-needless-words for a property: `defaultManager` of an `NSFileManager` is
/// `default`, `sharedApplication` of `NSApplication` `shared`; a name that is all type
/// (`processInfo`) stays.
pub(super) fn property_name(name: &str, ty: &str) -> String {
    let mut w = words(name);
    if prune_type_suffix(&mut w, ty) { w.concat() } else { name.to_string() }
}

/// A reduced omit-needless-words for a method's base name: the first selector piece, without a
/// leading `<result type>By` (`stringByAppendingPathComponent:` -> `appendingPathComponent`),
/// without a trailing copy of its parameter's type (`removeItemAtURL:` -> `removeItemAt`), cut
/// before its last preposition (`fileExistsAtPath:` -> `fileExists`).
pub(super) fn method_name(selector: &str, result: &str, param: Option<&str>) -> String {
    let piece = selector.split(':').next().unwrap_or(selector);
    let mut w: Vec<&str> = words(piece);
    if let Some(last) = type_words(result).last()
        && w.len() > 2
        && w[0].eq_ignore_ascii_case(last)
        && w[1] == "By"
    {
        w.drain(..2);
    }
    if selector.contains(':') {
        if let Some(p) = param {
            prune_type_suffix(&mut w, p);
        }
        if let Some(i) = (1..w.len()).rev().find(|i| PREPOSITIONS.contains(&w[*i])) {
            w.truncate(i);
        }
    }
    lower_first(&w.concat())
}

/// The type in a C declarator prefix (`NSFileManager *`, `nullable NSURL *`): its last identifier
/// that is not a qualifier.
fn c_type(s: &str) -> Option<String> {
    idents(s).into_iter().rev().find(|w| !is_macroish(w)).map(str::to_string)
}

fn headers_of(dir: &Path) -> Vec<std::path::PathBuf> {
    let mut v: Vec<_> = std::fs::read_dir(dir).into_iter().flatten().flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|x| x == "h")).collect();
    v.sort();
    v
}

struct Prop {
    class: String,
    name: String,
    ty: String,
    explicit: Option<String>,
    getter: Option<String>,
}

struct Method {
    class: String,
    selector: String,
    result: String,
    param: Option<String>,
    explicit: Option<String>,
}

/// A top-level C or Objective-C declaration: its C name, kind, the word its signature starts
/// with (`@interface`, `@protocol`, `c`) and an explicit Swift name.
struct Decl {
    c: String,
    kind: PkgKind,
    word: &'static str,
    explicit: Option<String>,
}

#[derive(Default)]
struct Headers {
    decls: Vec<Decl>,
    props: Vec<Prop>,
    methods: Vec<Method>,
    supers: Vec<(String, String)>,
}

const ENUM_MACROS: &[&str] = &["NS_ENUM(", "NS_OPTIONS(", "NS_CLOSED_ENUM(", "NS_ERROR_ENUM(", "CF_ENUM(", "CF_OPTIONS(", "CF_CLOSED_ENUM("];
const TYPED_ENUM_MACROS: &[&str] = &["NS_TYPED_ENUM", "NS_STRING_ENUM", "NS_TYPED_EXTENSIBLE_ENUM", "NS_EXTENSIBLE_STRING_ENUM"];

impl Headers {
    fn read(&mut self, text: &str) {
        let mut class: Option<String> = None;
        let mut pending_name: Option<String> = None;
        let mut typedef_block = false;
        let mut depth = 0i32;
        let mut stmt = String::new();
        let text = strip_comments(text);
        for raw in text.lines() {
            let line = raw.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if line.starts_with("@interface ") || line.starts_with("@protocol ") || line.starts_with("@end") {
                // An unterminated run of attribute lines ends at a class: it named the class.
                stmt.clear();
            }
            if let Some(rest) = line.strip_prefix("@interface ") {
                let Some(c) = idents(rest).first().map(|s| s.to_string()) else { continue };
                let after = rest.trim_start()[c.len()..].trim_start();
                if !after.starts_with('(') {
                    let explicit = swift_name_attr(line).or(pending_name.take());
                    self.decls.push(Decl { c: c.clone(), kind: PkgKind::Type, word: "@interface", explicit });
                    if let Some(sup) = after.strip_prefix(':').and_then(|s| idents(s).first().map(|x| x.to_string())) {
                        self.supers.push((c.clone(), sup));
                    }
                }
                if let Some(protos) = after.split_once('<').and_then(|(_, p)| p.split_once('>')).map(|x| x.0) {
                    for p in idents(protos) {
                        self.supers.push((c.clone(), p.to_string()));
                    }
                }
                pending_name = None;
                class = Some(c);
                continue;
            }
            if let Some(rest) = line.strip_prefix("@protocol ") {
                if let (Some(p), false) = (idents(rest).first(), line.ends_with(';')) {
                    let explicit = swift_name_attr(line).or(pending_name.take());
                    self.decls.push(Decl { c: p.to_string(), kind: PkgKind::Type, word: "@protocol", explicit });
                    class = Some(p.to_string());
                }
                pending_name = None;
                continue;
            }
            if line.starts_with("@end") {
                class = None;
                pending_name = None;
                continue;
            }
            if let Some(c) = &class {
                self.member(c, line);
                continue;
            }
            // Outside any class: enums, typedefs, structs, functions, constants.
            let before = depth;
            depth += line.matches('{').count() as i32 - line.matches('}').count() as i32;
            if before > 0 {
                if typedef_block && depth == 0 && line.starts_with('}') {
                    // `} Name;` closes `typedef struct { ... } Name;`
                    if let Some(n) = idents(line).into_iter().find(|w| !is_macroish(w)) {
                        self.decls.push(Decl { c: n.to_string(), kind: PkgKind::Type, word: "c", explicit: swift_name_attr(line) });
                    }
                    typedef_block = false;
                }
                continue;
            }
            if unavailable(line) {
                pending_name = None;
                stmt.clear();
                continue;
            }
            if line.starts_with("typedef") {
                if let Some((n, pat)) = ENUM_MACROS.iter().find_map(|p| line.find(p).map(|i| (i, p))) {
                    let name = line[n + pat.len()..].split(')').next().and_then(|a| a.split(',').nth(1)).map(|s| s.trim().to_string());
                    if let Some(name) = name.filter(|n| !n.is_empty()) {
                        self.decls.push(Decl { c: name, kind: PkgKind::Type, word: "c", explicit: swift_name_attr(line).or(pending_name.take()) });
                    }
                    stmt.clear();
                    continue;
                }
                if let Some(i) = TYPED_ENUM_MACROS.iter().find_map(|p| line.find(p)) {
                    // `typedef NSString * NSFooKey NS_TYPED_ENUM;`
                    if let Some(name) = idents(&line[..i]).last() {
                        self.decls.push(Decl { c: name.to_string(), kind: PkgKind::Type, word: "c", explicit: swift_name_attr(line).or(pending_name.take()) });
                    }
                    stmt.clear();
                    continue;
                }
                if depth > 0 {
                    typedef_block = true;
                    continue;
                }
            }
            if depth > 0 {
                // `struct CGPoint {`
                if let Some(rest) = line.strip_prefix("struct ")
                    && let Some(n) = idents(rest).first()
                {
                    self.decls.push(Decl { c: n.to_string(), kind: PkgKind::Type, word: "c", explicit: pending_name.take() });
                }
                stmt.clear();
                continue;
            }
            stmt.push(' ');
            stmt.push_str(line);
            if !stmt.contains(';') {
                // A line of attribute macros: its Swift name applies to what follows.
                if let Some(n) = swift_name_attr(line) {
                    pending_name = Some(n);
                }
                if stmt.len() > 2000 {
                    stmt.clear();
                }
                continue;
            }
            let s = std::mem::take(&mut stmt);
            self.statement(s.trim(), pending_name.take());
        }
    }

    /// A top-level statement up to its `;`: a typedef, a struct, a function, a constant.
    fn statement(&mut self, s: &str, pending: Option<String>) {
        let explicit = swift_name_attr(s).or(pending);
        let head = s.split(';').next().unwrap_or("");
        if head.starts_with("typedef") {
            let name = if head.contains("(^") || head.contains("(*") {
                // a block or function-pointer typedef: `typedef void (^Handler)(...)`
                head.split("(^").nth(1).or_else(|| head.split("(*").nth(1)).and_then(|r| idents(r).first().map(|x| x.to_string()))
            } else {
                idents(head).into_iter().rev().find(|w| !is_macroish(w)).map(str::to_string)
            };
            if let Some(n) = name {
                self.decls.push(Decl { c: n, kind: PkgKind::TypeAlias, word: "c", explicit });
            }
            return;
        }
        if head.starts_with("struct ") || head.starts_with("@class") || head.starts_with("enum ") {
            return;
        }
        if let Some(paren) = head.find('(') {
            // `CG_EXTERN CGRect CGRectMake(CGFloat x, ...)`
            if let Some(n) = idents(&head[..paren]).last().filter(|n| !is_macroish(n)) {
                self.decls.push(Decl { c: n.to_string(), kind: PkgKind::Function, word: "c", explicit });
            }
            return;
        }
        if head.contains("extern") || head.contains("EXPORT") || head.contains("EXTERN") {
            let decl = head.split(" API_").next().unwrap_or(head).split(" NS_").next().unwrap_or(head);
            if let Some(n) = idents(decl).into_iter().rev().find(|w| !is_macroish(w)) {
                self.decls.push(Decl { c: n.to_string(), kind: PkgKind::Function, word: "c var", explicit });
            }
        }
    }

    /// A line inside `@interface`/`@protocol` ... `@end`: a property or a method head.
    fn member(&mut self, class: &str, line: &str) {
        if unavailable(line) {
            return;
        }
        if let Some(rest) = line.strip_prefix("@property") {
            let rest = rest.trim_start();
            let (attrs, after) = match rest.strip_prefix('(').and_then(|r| r.split_once(')')) {
                Some((a, b)) => (a, b),
                None => ("", rest),
            };
            let getter = attrs.split(',').find_map(|a| a.trim().strip_prefix("getter").map(|g| g.trim_start_matches([' ', '=']).trim().to_string()));
            let decl = after.split(';').next().unwrap_or("");
            let decl = decl.split(" API_").next().unwrap_or(decl).split(" NS_").next().unwrap_or(decl);
            let ids = idents(decl);
            let Some(pos) = ids.iter().rposition(|w| !is_macroish(w)) else { return };
            let ty = c_type(&ids[..pos].join(" ")).unwrap_or_default();
            self.props.push(Prop { class: class.into(), name: ids[pos].into(), ty, explicit: swift_name_attr(line), getter });
            return;
        }
        let Some(after) = line.strip_prefix('-').or_else(|| line.strip_prefix('+')) else { return };
        let after = after.trim_start();
        let (result, after) = match after.strip_prefix('(').and_then(|r| r.split_once(')')) {
            Some((r, a)) => (c_type(r).unwrap_or_default(), a.trim_start()),
            None => (String::new(), after),
        };
        let Some(first) = idents(after).first().map(|s| s.to_string()) else { return };
        let has_arg = after[first.len()..].trim_start().starts_with(':');
        let param = if has_arg { after.split_once(':').and_then(|(_, r)| r.trim_start().strip_prefix('(')).and_then(|r| r.split_once(')')).and_then(|x| c_type(x.0)) } else { None };
        if line.starts_with('+') && result == "instancetype" {
            return; // a factory: imported as an initialiser
        }
        // The first selector piece is all the base name uses; the USR check matches selectors
        // by it.
        let selector = if has_arg { format!("{first}:") } else { first };
        self.methods.push(Method { class: class.into(), selector, result, param, explicit: swift_name_attr(line) });
    }
}

pub(super) fn parse_framework(m: &mut SwiftModule, headers: &Path, name: &str, sdk: &Sdk) {
    let notes = std::fs::read_to_string(headers.join(format!("{name}.apinotes"))).map(|t| api_notes(&t)).unwrap_or_default();
    let mut h = Headers::default();
    let mut includes: Vec<String> = Vec::new();
    for p in headers_of(headers) {
        let Ok(text) = std::fs::read_to_string(&p) else { continue };
        // Re-exports: the frameworks any header includes (`XCTestCase.h` brings Foundation;
        // Apple's module maps say `export *`).
        for l in text.lines().map(str::trim).filter(|l| l.starts_with("#import") || l.starts_with("#include")) {
            if let Some(inc) = l.split('<').nth(1).and_then(|r| r.split_once('/')).map(|x| x.0)
                && inc != name
                && !includes.iter().any(|r| r == inc)
            {
                includes.push(inc.to_string());
            }
        }
        h.read(&text);
    }
    for inc in includes {
        if !m.reexports.contains(&inc) && super::framework(sdk, &inc).is_some() {
            m.reexports.push(inc);
        }
    }
    // Swift names: API notes win, then `NS_SWIFT_NAME`, then the C name.
    let module = m.name.clone();
    let mut swift_of: HashMap<String, String> = HashMap::new();
    for d in &h.decls {
        let swift = notes.top.get(&d.c).cloned().or_else(|| d.explicit.clone()).unwrap_or_else(|| d.c.clone());
        swift_of.entry(d.c.clone()).or_insert(swift);
    }
    for d in &h.decls {
        let swift = swift_of[&d.c].clone();
        if swift.is_empty() || swift.starts_with('_') {
            continue;
        }
        if swift != d.c {
            m.objc_names.insert(d.c.clone(), swift.clone());
        }
        let sig = Some(format!("{} {}", d.word, d.c));
        let is_type = matches!(d.kind, PkgKind::Type | PkgKind::TypeAlias);
        match swift.rsplit_once('.') {
            // `FileManager.DirectoryEnumerator`, `NSAttributedString.Key.font`
            Some((parent, leaf)) => {
                m.add_member(&module, parent, leaf, d.kind, sig, is_type.then(|| swift.clone()));
                if is_type {
                    m.mark_declared(&swift);
                }
            }
            None => {
                m.add_top(&module, &swift, d.kind, sig);
                if is_type {
                    m.mark_declared(&swift);
                }
            }
        }
    }
    let name_of = |c: &str| swift_of.get(c).filter(|s| !s.is_empty()).cloned().unwrap_or_else(|| c.to_string());
    for (c, s) in &h.supers {
        m.add_supers(&name_of(c), [name_of(s)]);
    }
    for p in h.props {
        // Only a property of its own class's type loses the type's words (`defaultManager` of
        // `NSFileManager`); `currentMode` of `NSRunLoop` (an `NSRunLoopMode`) keeps them.
        let pruned = if p.ty == p.class { property_name(&p.name, &p.ty) } else { p.name.clone() };
        let swift = notes
            .members
            .get(&(p.class.clone(), p.name.clone()))
            .cloned()
            .or(p.explicit)
            .or_else(|| p.getter.clone().filter(|g| g.starts_with("is")))
            .unwrap_or(pruned);
        if swift.is_empty() {
            continue;
        }
        let ty = Some(name_of(&p.ty)).filter(|t| !t.is_empty());
        m.add_member(&module, &name_of(&p.class), &swift, PkgKind::Function, Some(format!("@property {}", p.name)), ty);
    }
    for me in h.methods {
        let swift = notes
            .members
            .get(&(me.class.clone(), me.selector.clone()))
            .cloned()
            .or(me.explicit)
            .unwrap_or_else(|| method_name(&me.selector, &me.result, me.param.as_deref()));
        if swift.is_empty() || swift.starts_with("init") && me.selector.starts_with("init") {
            continue;
        }
        let ty = Some(name_of(&me.result)).filter(|t| !t.is_empty() && t != "void" && t != "BOOL");
        m.add_member(&module, &name_of(&me.class), &swift, PkgKind::Function, Some(format!("@method {}", me.selector)), ty);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn omit_needless_words_reduced() {
        assert_eq!(property_name("defaultManager", "NSFileManager"), "default");
        assert_eq!(property_name("sharedApplication", "NSApplication"), "shared");
        assert_eq!(property_name("processInfo", "NSProcessInfo"), "processInfo");
        assert_eq!(property_name("mainBundle", "NSBundle"), "main");
        assert_eq!(method_name("removeItemAtURL:", "BOOL", Some("NSURL")), "removeItem");
        assert_eq!(method_name("fileExistsAtPath:", "BOOL", Some("NSString")), "fileExists");
        assert_eq!(method_name("createDirectoryAtURL:", "BOOL", Some("NSURL")), "createDirectory");
        assert_eq!(method_name("stringByAppendingPathComponent:", "NSString", Some("NSString")), "appendingPathComponent");
        assert_eq!(method_name("contentsOfDirectoryAtPath:", "NSArray", Some("NSString")), "contentsOfDirectory");
        assert_eq!(method_name("addObserver:", "void", Some("id")), "addObserver");
        assert_eq!(method_name("reloadData", "void", None), "reloadData");
        assert_eq!(method_name("URLForKey:", "NSURL", Some("NSString")), "url");
    }

    #[test]
    fn api_notes_rename_top_level_names_and_members() {
        let n = api_notes(
            "---\nName: Foundation\nClasses:\n- Name: NSFileManager\n  SwiftName: FileManager\n  Properties:\n  - Name: defaultManager\n    SwiftName: default\n- Name: NSHidden\n  SwiftPrivate: true\nSwiftVersions:\n- Version: 3\n  Classes:\n  - Name: NSOld\n    SwiftName: Old\n",
        );
        assert_eq!(n.top.get("NSFileManager").map(String::as_str), Some("FileManager"));
        assert_eq!(n.members.get(&("NSFileManager".into(), "defaultManager".into())).map(String::as_str), Some("default"));
        assert_eq!(n.top.get("NSHidden").map(String::as_str), Some(""));
        assert!(!n.top.contains_key("NSOld"), "renames for older Swift versions do not apply");
    }

    #[test]
    fn headers_yield_classes_properties_enums_and_functions() {
        let mut h = Headers::default();
        h.read(
            "/* comment\n @interface Fake\n */\n/* see the files (below) */\nNS_SWIFT_NAME(Thing)\n@interface NSThing : NSObject <NSCopying>\n@property (class, readonly, strong) NSThing *defaultThing;\n@property (getter=isOn) BOOL on;\n- (BOOL)removeItemAtURL:(NSURL *)url error:(NSError **)error;\n- (void)gone NS_UNAVAILABLE;\n@end\n\
             typedef NS_ENUM(NSInteger, NSThingKind) {\n    NSThingKindA,\n};\ntypedef double NSInterval;\nCG_EXTERN CGRect CGRectMake(CGFloat x, CGFloat y)\n    API_AVAILABLE(macos(10.0));\ntypedef struct _NSSpan {\n    int a;\n} NSSpan;\n",
        );
        let names: Vec<&str> = h.decls.iter().map(|d| d.c.as_str()).collect();
        assert_eq!(names, ["NSThing", "NSThingKind", "NSInterval", "CGRectMake", "NSSpan"]);
        assert_eq!(h.decls[0].explicit.as_deref(), Some("Thing"));
        assert_eq!(h.supers, [("NSThing".to_string(), "NSObject".to_string()), ("NSThing".to_string(), "NSCopying".to_string())]);
        let props: Vec<(&str, &str)> = h.props.iter().map(|p| (p.name.as_str(), p.ty.as_str())).collect();
        assert_eq!(props, [("defaultThing", "NSThing"), ("on", "")], "an all-caps C type (`BOOL`) reads as a macro and is not kept");
        assert_eq!(h.methods.len(), 1);
        assert_eq!(h.methods[0].selector, "removeItemAtURL:");
    }
}
