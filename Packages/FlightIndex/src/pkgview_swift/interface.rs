//! A module's Swift interface (`.swiftinterface`), read line by line. The compiler prints one
//! declaration per line with its attributes, nests members by braces, and qualifies every type
//! with its module, so a brace-tracking line reader recovers the public surface: top-level
//! names, each type's members (from the type and from extensions), and its supertypes.

use super::{base_type, PkgKind, SwiftModule};

/// Strip leading attributes (`@available(...)`, `@frozen`) from a declaration line, and return
/// the module an `@_originallyDefinedIn(module: "X", ...)` names: the module the declaration's
/// mangled name (and so its USR) still carries.
fn strip_attrs(mut s: &str) -> (&str, Option<String>) {
    let mut original = None;
    loop {
        s = s.trim_start();
        let Some(rest) = s.strip_prefix('@') else { break };
        let end = rest.find(|c: char| !(c.is_alphanumeric() || c == '_' || c == '.')).unwrap_or(rest.len());
        let name = &rest[..end];
        let mut after = &rest[end..];
        if after.starts_with('(') {
            let mut depth = 0;
            let mut cut = after.len();
            for (i, c) in after.char_indices() {
                match c {
                    '(' => depth += 1,
                    ')' => {
                        depth -= 1;
                        if depth == 0 {
                            cut = i + 1;
                            break;
                        }
                    }
                    _ => {}
                }
            }
            if name == "_originallyDefinedIn"
                && let Some(q) = after[..cut].split('"').nth(1)
            {
                original = Some(q.to_string());
            }
            after = &after[cut..];
        }
        s = after;
    }
    (s, original)
}

const MODIFIERS: &[&str] = &[
    "public", "open", "final", "static", "override", "mutating", "nonmutating", "convenience", "required", "indirect", "nonisolated",
    "dynamic", "optional", "lazy", "weak", "unowned", "prefix", "postfix", "infix", "consuming", "borrowing", "distributed", "__consuming",
    "package", "isolated", "sending", "unsafe",
];

/// Braces opened minus braces closed on a line, outside string literals.
fn brace_delta(s: &str) -> i32 {
    let mut d = 0;
    let mut in_str = false;
    let mut esc = false;
    for c in s.chars() {
        if in_str {
            match (esc, c) {
                (true, _) => esc = false,
                (false, '\\') => esc = true,
                (false, '"') => in_str = false,
                _ => {}
            }
            continue;
        }
        match c {
            '"' => in_str = true,
            '{' => d += 1,
            '}' => d -= 1,
            _ => {}
        }
    }
    d
}

/// The identifier at the start of `s` (a backticked one unquoted, an operator as written).
fn ident(s: &str) -> &str {
    let s = s.trim_start();
    if let Some(r) = s.strip_prefix('`') {
        return r.split('`').next().unwrap_or("");
    }
    let end = s.find(|c: char| !(c.is_alphanumeric() || c == '_')).unwrap_or(s.len());
    if end == 0 {
        // An operator: up to the generic list, the parameters or a space.
        return s.split(['<', '(', ' ']).next().unwrap_or("");
    }
    &s[..end]
}

/// Split at `sep` outside brackets.
fn split_top(s: &str, sep: char) -> Vec<&str> {
    let mut out = Vec::new();
    let mut depth = 0;
    let mut start = 0;
    let b = s.as_bytes();
    for (i, c) in s.char_indices() {
        match c {
            '<' | '(' | '[' => depth += 1,
            '>' if i > 0 && b[i - 1] == b'-' => {}
            '>' | ')' | ']' => depth -= 1,
            c if c == sep && depth == 0 => {
                out.push(&s[start..i]);
                start = i + 1;
            }
            _ => {}
        }
    }
    out.push(&s[start..]);
    out
}

/// The inheritance clause of a type or extension head (`struct A<T> : B, C where ... {`).
fn supers_of(head: &str) -> Vec<String> {
    let head = head.split('{').next().unwrap_or(head);
    let head = head.split(" where ").next().unwrap_or(head);
    let mut depth = 0;
    let mut colon = None;
    for (i, c) in head.char_indices() {
        match c {
            '<' | '(' | '[' => depth += 1,
            '>' | ')' | ']' => depth -= 1,
            ':' if depth == 0 => {
                colon = Some(i);
                break;
            }
            _ => {}
        }
    }
    let Some(colon) = colon else { return Vec::new() };
    split_top(&head[colon + 1..], ',')
        .into_iter()
        .flat_map(|p| p.split('&').map(str::to_string).collect::<Vec<_>>())
        .filter_map(|p| base_type(p.trim().trim_start_matches("@unchecked ").trim_start_matches('~')))
        .collect()
}

/// The result type of a function head (`func f(x: Int) throws -> Foundation.URL where ...`).
fn result_type(head: &str) -> Option<String> {
    let mut depth = 0;
    let mut last = None;
    let b = head.as_bytes();
    for (i, c) in head.char_indices() {
        match c {
            '(' | '[' | '<' => depth += 1,
            ')' | ']' => depth -= 1,
            '>' if i > 0 && b[i - 1] == b'-' => {
                if depth == 0 {
                    last = Some(i + 1);
                }
            }
            '>' => depth -= 1,
            _ => {}
        }
    }
    let t = head[last?..].split(" where ").next()?.split('{').next()?.trim();
    base_type(t)
}

/// A property's declared type (`var x: Foundation.URL { get }`).
fn var_type(rest: &str) -> Option<String> {
    let (_, t) = rest.split_once(':')?;
    let t = t.split(['{', '=']).next()?.trim();
    base_type(t)
}

enum Ctx {
    /// A type or an extension of one: its declarations are members, declared (for their USRs) in
    /// the module the second field names.
    Type(String, String),
    /// A function, accessor or inlinable body: nothing declared inside is API.
    Body,
}

/// Skip leading modifiers; `true` when one of them hides the declaration (`internal`, as an
/// `@usableFromInline` declaration is printed).
fn skip_modifiers(mut words: &str) -> (&str, bool) {
    let mut hidden = false;
    loop {
        let w = ident(words);
        let known = MODIFIERS.contains(&w);
        let hiding = matches!(w, "internal" | "private" | "fileprivate");
        // `class func`, `class var`: a modifier; `class Foo`: a declaration.
        let class_mod = w == "class" && {
            let next = ident(words.trim_start()[5..].trim_start());
            matches!(next, "func" | "var" | "let" | "subscript" | "override" | "final" | "public" | "open")
        };
        if !(known || hiding || class_mod) {
            return (words, hidden);
        }
        hidden |= hiding;
        words = &words.trim_start()[w.len()..];
        // `public(set)`, `nonisolated(unsafe)`
        if words.starts_with('(') {
            words = words.split_once(')').map(|x| x.1).unwrap_or("");
        }
    }
}

pub(super) fn parse(m: &mut SwiftModule, text: &str) {
    let module = m.name.clone();
    let mut stack: Vec<Ctx> = Vec::new();
    // `@_originallyDefinedIn` on an attribute line of its own applies to the next declaration.
    let mut pending: Option<String> = None;
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with("//") || line.starts_with('#') {
            continue;
        }
        if stack.is_empty()
            && let Some(rest) = line.strip_prefix("@_exported import ")
        {
            let target = rest.split_whitespace().last().unwrap_or("").split('.').next().unwrap_or("");
            if !target.is_empty() && !m.reexports.iter().any(|r| r == target) {
                m.reexports.push(target.to_string());
            }
            continue;
        }
        let delta = brace_delta(line);
        let mut opened: Option<Ctx> = None;
        if stack.iter().all(|c| matches!(c, Ctx::Type(..))) {
            let (decl, original) = strip_attrs(line);
            if decl.trim().is_empty() {
                pending = original.or(pending);
                continue;
            }
            opened = declaration(m, &module, &stack, decl, original.or(pending.take()));
        } else {
            pending = None;
        }
        if delta > 0 {
            stack.push(opened.unwrap_or(Ctx::Body));
            for _ in 1..delta {
                stack.push(Ctx::Body);
            }
        } else {
            for _ in 0..(-delta) {
                stack.pop();
            }
        }
    }
}

/// Record the declaration `decl` (attributes stripped; in the type `stack` names, if any); the
/// context its brace opens, when it is a type or an extension. `original` is the module an
/// `@_originallyDefinedIn` names.
fn declaration(m: &mut SwiftModule, module: &str, stack: &[Ctx], decl: &str, original: Option<String>) -> Option<Ctx> {
    let (words, hidden) = skip_modifiers(decl);
    let kw = ident(words);
    let rest = words.trim_start().get(kw.len()..).unwrap_or("").trim_start();
    let (container, container_module) = match stack.last() {
        Some(Ctx::Type(t, cm)) => (Some(t.clone()), Some(cm.clone())),
        _ => (None, None),
    };
    if let Some(o) = &original {
        super::record_move(o, module);
    }
    let decl_module = original.or(container_module).unwrap_or_else(|| module.to_string());
    let selfish = |t: String| if t == "Self" { container.clone().unwrap_or(t) } else { t };
    let record = |m: &mut SwiftModule, name: &str, kind: PkgKind, value_ty: Option<String>| {
        if hidden || name.is_empty() || name.starts_with('_') {
            return;
        }
        match &container {
            None => m.add_top(&decl_module, name, kind, Some(decl.chars().take(160).collect())),
            // Members keep no signature: there are ten times as many, and `find` shows
            // top-level ones.
            Some(t) => m.add_member(&decl_module, t, name, kind, None, value_ty),
        }
    };
    match kw {
        "struct" | "class" | "enum" | "protocol" | "actor" => {
            let name = ident(rest).to_string();
            let full = match &container {
                Some(c) => format!("{c}.{name}"),
                None => name.clone(),
            };
            record(m, &name, PkgKind::Type, Some(full.clone()));
            if !hidden && !name.starts_with('_') {
                m.add_supers(&full, supers_of(rest));
                m.mark_declared(&full);
            }
            return Some(Ctx::Type(full, decl_module));
        }
        "extension" => {
            let target = rest.split([' ', ':', '{', '<']).next().unwrap_or("");
            let target = base_type(target).unwrap_or_default();
            m.add_supers(&target, supers_of(rest));
            return Some(Ctx::Type(target, decl_module));
        }
        "typealias" | "associatedtype" => {
            let name = ident(rest).to_string();
            let aliased = rest.split_once('=').and_then(|(_, t)| base_type(t.trim()));
            record(m, &name, PkgKind::TypeAlias, aliased.clone());
            if container.is_none()
                && let Some(a) = aliased
            {
                // The aliased type's members are the alias's (`TimeInterval` is a `Double`).
                m.add_supers(&name, [a]);
            }
        }
        "func" => {
            let name = ident(rest);
            let kind = if name.starts_with(|c: char| c.is_alphanumeric() || c == '_') { PkgKind::Function } else { PkgKind::Operator };
            record(m, name, kind, result_type(rest).map(selfish));
        }
        "var" | "let" => record(m, ident(rest), PkgKind::Function, var_type(rest).map(selfish)),
        "case" if container.is_some() => {
            for part in split_top(rest, ',') {
                record(m, ident(part), PkgKind::Constructor, container.clone());
            }
        }
        // Macros (`#line`, `#Preview`) are written with `#` or `@`, which no reference keeps.
        "macro" => {}
        "init" => {
            if let Some(c) = &container
                && !hidden
            {
                m.add_member(&decl_module, c, "init", PkgKind::Function, None, Some(c.clone()));
            }
        }
        _ => {}
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    fn parsed(name: &str, text: &str) -> SwiftModule {
        let pkg = Arc::new(crate::pkgview::PackageId { manager: "swift-sdk", name: "macosx".into(), version: "1.0".into() });
        let mut m = SwiftModule::new(name, pkg);
        parse(&mut m, text);
        m
    }

    #[test]
    fn an_interface_yields_top_level_names_members_and_supertypes() {
        let m = parsed(
            "Foundation",
            "import Swift\n@_exported import Foundation\n@_exported import Observation\n\
             @available(macOS 10.15, *)\n@frozen public struct UUID : Swift.Hashable, Swift.Sendable {\n  public var uuidString: Swift.String {\n    get\n  }\n  @inlinable public func helper() -> Swift.Int {\n    let inner = 1\n    return inner\n  }\n  public init()\n}\n\
             extension Foundation.FileManager {\n  public func url(for directory: Foundation.FileManager.SearchPathDirectory) throws -> Foundation.URL\n  @usableFromInline internal func hidden()\n}\n\
             public typealias TimeInterval = Swift.Double\n\
             public func NSLog(_ format: Swift.String, _ args: any Swift.CVarArg...)\n\
             public enum Mode {\n  case a, b(Swift.Int)\n  public static func == (a: Foundation.Mode, b: Foundation.Mode) -> Swift.Bool\n}\n",
        );
        assert_eq!(m.reexports, ["Foundation", "Observation"]);
        for n in ["UUID", "TimeInterval", "NSLog", "Mode"] {
            assert!(m.top.contains_key(n), "{n}");
        }
        let uuid = &m.types["UUID"];
        assert_eq!(uuid.supers, ["Hashable", "Sendable"]);
        assert_eq!(uuid.members["uuidString"].ty.as_deref(), Some("String"));
        assert!(uuid.members.contains_key("helper") && uuid.members.contains_key("init"));
        assert!(!uuid.members.contains_key("inner"), "a body's locals are not API");
        assert_eq!(m.types["FileManager"].members["url"].ty.as_deref(), Some("URL"));
        assert!(!m.types["FileManager"].members.contains_key("hidden"));
        assert_eq!(&*m.types["FileManager"].members["url"].sym.module, "Foundation.FileManager");
        assert!(m.types["Mode"].members.contains_key("a") && m.types["Mode"].members.contains_key("b"));
        assert_eq!(m.types["TimeInterval"].supers, ["Double"]);
    }

    #[test]
    fn a_type_moved_to_another_module_keeps_its_original_module() {
        let m = parsed(
            "SwiftUICore",
            "@_originallyDefinedIn(module: \"SwiftUI\", macOS 14.0) @frozen public struct Text : Swift.Equatable {\n}\n\
             @_originallyDefinedIn(module: \"SwiftUI\", macOS 15.0)\n@_originallyDefinedIn(module: \"SwiftUI\", iOS 18.0)\n\
             extension SwiftUICore.View {\n  public func frame(width: Swift.Double) -> some SwiftUICore.View\n\n}\n\
             public struct Moved {\n}\n",
        );
        assert_eq!(&*m.top["Text"].module, "SwiftUI");
        assert_eq!(&*m.types["View"].members["frame"].sym.module, "SwiftUI.View", "an extension's attribute line covers its members");
        assert_eq!(&*m.top["Moved"].module, "SwiftUICore", "the attribute applies to one declaration only");
    }
}
