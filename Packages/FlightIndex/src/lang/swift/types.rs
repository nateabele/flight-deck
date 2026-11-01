//! Swift type facts: what a file's own declarations say about the types of names, for the
//! receiver ladder (`graph::swift_types`). Read during the extractor's existing walk, no second
//! parse. Everything stays as written (`TypeSource::Expr` for an initialiser), because typing an
//! expression needs property and return types from other files, which a blob fact must not know.

use super::super::util::{one_line, text};
use crate::facts::{Binding, MemberType, ReturnType, TypeFacts, TypeSource};
use tree_sitter::Node;

/// Longest initialiser text kept as a `TypeSource::Expr`. Longer ones are closures or argument
/// lists the ladder could not type anyway.
const MAX_EXPR: usize = 200;

/// A written type reduced to the bare name members are keyed by: `Store` for `Store?`,
/// `some Store`, `Kit.Store` or `Store<T>`; `[Store]` keeps its brackets for a `for` loop. `None`
/// for a function, tuple, dictionary or composition type, and for a lowercase name.
pub fn norm(t: &str) -> Option<String> {
    let mut t = t.trim();
    loop {
        let before = t;
        for p in ["some ", "any ", "inout ", "@escaping ", "@Sendable ", "@MainActor ", "borrowing ", "consuming "] {
            t = t.strip_prefix(p).unwrap_or(t).trim_start();
        }
        if t == before {
            break;
        }
    }
    let t = t.trim_end_matches(['?', '!']).trim();
    if let Some(inner) = t.strip_prefix('[').and_then(|x| x.strip_suffix(']')) {
        return if inner.contains(':') { None } else { norm(inner).map(|e| format!("[{e}]")) };
    }
    if t.starts_with('(') || t.contains("->") || t.contains('&') || t.starts_with('[') {
        return None;
    }
    let base = t.split('<').next().unwrap_or(t);
    let last = base.rsplit('.').next().unwrap_or(base).trim();
    (!last.is_empty() && last.chars().all(|c| c.is_alphanumeric() || c == '_') && last.starts_with(|c: char| c.is_uppercase()))
        .then(|| last.to_string())
}

fn line(n: Node) -> u32 {
    n.start_position().row as u32 + 1
}

fn end_line(n: Node) -> u32 {
    n.end_position().row as u32 + 1
}

fn ancestor<'t>(n: Node<'t>, kinds: &[&str]) -> Option<Node<'t>> {
    let mut p = n.parent();
    while let Some(q) = p {
        if kinds.contains(&q.kind()) {
            return Some(q);
        }
        p = q.parent();
    }
    None
}

/// The children of `n` under field `field` (a node may hold several `name` children: the
/// parameter's identifier and its type both sit under `name`).
fn field_kids<'t>(n: Node<'t>, field: &str) -> Vec<Node<'t>> {
    let mut c = n.walk();
    n.children(&mut c).enumerate().filter(|(i, _)| n.field_name_for_child(*i as u32) == Some(field)).map(|(_, k)| k).collect()
}

/// What an initialiser or condition says about its type: a cast's type outright, otherwise the
/// expression text for the ladder to evaluate. `None` for anything it could not type.
fn expr_source(e: Node, src: &str) -> Option<TypeSource> {
    match e.kind() {
        "try_expression" | "await_expression" => e.child_by_field_name("expr").and_then(|x| expr_source(x, src)),
        "as_expression" => e.child_by_field_name("type").and_then(|t| norm(text(t, src))).map(TypeSource::Named),
        "call_expression" | "navigation_expression" | "simple_identifier" | "self_expression" => {
            let t = one_line(text(e, src));
            (t.len() <= MAX_EXPR).then_some(TypeSource::Expr(t))
        }
        _ => None,
    }
}

/// Record the binding `n` introduces, if it is one: a parameter, closure parameter, local
/// `let`/`var`, `if`/`guard`/`while let`, or `for` item. `enclosing` is the symbol it sits in.
pub fn binding(n: Node, src: &str, enclosing: Option<u32>, out: &mut TypeFacts) {
    let mut push = |name: &str, ty: Option<TypeSource>, decl: u32, scope: (u32, u32)| {
        out.bindings.push(Binding { name: name.to_string(), ty, decl_line: decl, scope_start: scope.0, scope_end: scope.1, enclosing });
    };
    match n.kind() {
        "parameter" => {
            let Some(f) = ancestor(n, &["function_declaration", "init_declaration", "subscript_declaration", "protocol_function_declaration"]) else { return };
            let kids = field_kids(n, "name");
            let Some(name) = kids.iter().find(|k| k.kind() == "simple_identifier") else { return };
            let ty = kids.iter().find(|k| k.kind() != "simple_identifier").and_then(|t| norm(text(*t, src))).map(TypeSource::Named);
            push(text(*name, src), ty, line(f), (line(f), end_line(f)));
        }
        "lambda_parameter" => {
            let Some(lam) = ancestor(n, &["lambda_literal"]) else { return };
            let kids = field_kids(n, "name");
            let Some(name) = kids.iter().find(|k| k.kind() == "simple_identifier") else { return };
            let mut c = n.walk();
            let ty = n.named_children(&mut c).find(|k| k.kind() != "simple_identifier").and_then(|t| norm(text(t, src))).map(TypeSource::Named);
            push(text(*name, src), ty, line(lam), (line(lam), end_line(lam)));
        }
        "property_declaration" if n.parent().is_some_and(|p| p.kind() == "statements") => {
            let Some(name) = n.child_by_field_name("name").and_then(|p| p.child_by_field_name("bound_identifier")) else { return };
            let mut c = n.walk();
            let ann = n
                .named_children(&mut c)
                .find(|k| k.kind() == "type_annotation")
                .and_then(|a| a.child_by_field_name("name"))
                .and_then(|t| norm(text(t, src)))
                .map(TypeSource::Named);
            let ty = ann.or_else(|| n.child_by_field_name("value").and_then(|v| expr_source(v, src)));
            let scope_end = n.parent().map(end_line).unwrap_or(end_line(n));
            push(text(name, src), ty, line(n), (line(n), scope_end));
        }
        "if_statement" | "guard_statement" | "while_statement" => {
            // A guard's bindings live on to the end of the enclosing block.
            let scope_end = if n.kind() == "guard_statement" { n.parent().map(end_line).unwrap_or(end_line(n)) } else { end_line(n) };
            let mut c = n.walk();
            let kids: Vec<(Option<&str>, Node)> = n.children(&mut c).enumerate().map(|(i, k)| (n.field_name_for_child(i as u32), k)).collect();
            for (i, (field, k)) in kids.iter().enumerate() {
                if *field != Some("bound_identifier") {
                    continue;
                }
                let rest = kids[i + 1..].iter().take_while(|x| x.0 != Some("bound_identifier"));
                let mut ty = None;
                let mut found = false;
                for (f, x) in rest {
                    match *f {
                        Some("name") => ty = ty.or_else(|| norm(text(*x, src)).map(TypeSource::Named)),
                        // The `=` token sits under `condition` too.
                        Some("condition") if x.is_named() && x.kind() != "value_binding_pattern" => {
                            found = true;
                            ty = ty.or_else(|| expr_source(*x, src));
                            break;
                        }
                        _ => {}
                    }
                }
                // Shorthand `if let x {` rebinds `x` with its own type: leave the outer one.
                if found {
                    push(text(*k, src), ty, line(n), (line(n), scope_end));
                }
            }
        }
        "for_statement" => {
            let (Some(item), Some(coll)) = (n.child_by_field_name("item"), n.child_by_field_name("collection")) else { return };
            let Some(id) = item.child_by_field_name("bound_identifier") else { return };
            let ty = matches!(coll.kind(), "simple_identifier" | "navigation_expression" | "self_expression")
                .then(|| one_line(text(coll, src)))
                .filter(|t| t.len() <= MAX_EXPR)
                .map(TypeSource::Each);
            push(text(id, src), ty, line(n), (line(n), end_line(n)));
        }
        _ => {}
    }
}

/// A property of type `owner`: its annotation, or the type its `T(...)` initialiser builds.
pub fn member(n: Node, src: &str, owner: &str, out: &mut TypeFacts) {
    let Some(name) = n.child_by_field_name("name").and_then(|p| p.child_by_field_name("bound_identifier")) else { return };
    let mut c = n.walk();
    let ann = n.named_children(&mut c).find(|k| k.kind() == "type_annotation").and_then(|a| a.child_by_field_name("name")).and_then(|t| norm(text(t, src)));
    let init = || {
        let v = n.child_by_field_name("value").filter(|v| v.kind() == "call_expression")?;
        let callee = v.named_child(0).filter(|c| c.kind() == "simple_identifier")?;
        norm(text(callee, src))
    };
    if let Some(ty) = ann.or_else(init) {
        out.members.push(MemberType { owner: owner.to_string(), member: text(name, src).to_string(), ty });
    }
}

/// A function's declared return type (the `name` field child that is not its identifier). A
/// function returning nothing, or a type the ladder cannot use, is not recorded: two thirds of
/// all functions, and nothing is ever looked up on their result.
pub fn returns(n: Node, src: &str, owner: &str, name: &str, out: &mut TypeFacts) {
    let ty = field_kids(n, "name").into_iter().find(|k| k.kind() != "simple_identifier").and_then(|t| norm(text(t, src)));
    if ty.is_some() {
        out.returns.push(ReturnType { owner: owner.to_string(), name: name.to_string(), ty });
    }
}

/// Drop the bindings no receiver can reach: only a name that roots some reference's qualifier
/// (or the initialiser of a binding that does) is ever looked up. On Flight Deck this keeps about
/// a third of them, which is what the store and the graph's memory pay for.
pub fn prune(facts: &mut crate::facts::BlobFacts) {
    let root = |q: &str| -> Option<String> {
        let q = q.trim_start_matches("try ").trim_start_matches("await ");
        let end = q.find(|c: char| !(c.is_alphanumeric() || c == '_')).unwrap_or(q.len());
        (end > 0).then(|| q[..end].to_string())
    };
    let mut used: std::collections::HashSet<String> = facts.refs.iter().filter_map(|r| r.qualifier.as_deref().and_then(root)).collect();
    loop {
        let before = used.len();
        for b in &facts.types.bindings {
            if let (true, Some(TypeSource::Expr(e) | TypeSource::Each(e))) = (used.contains(&b.name), &b.ty) {
                used.extend(e.split(|c: char| !(c.is_alphanumeric() || c == '_')).filter(|t| !t.is_empty()).map(str::to_string));
            }
        }
        if used.len() == before {
            break;
        }
    }
    facts.types.bindings.retain(|b| used.contains(&b.name));
}

#[cfg(test)]
mod tests {
    use super::norm;

    #[test]
    fn written_types_reduce_to_the_name_members_are_keyed_by() {
        assert_eq!(norm("Store?").as_deref(), Some("Store"));
        assert_eq!(norm("some Kit.Store").as_deref(), Some("Store"));
        assert_eq!(norm("Store<Int>").as_deref(), Some("Store"));
        assert_eq!(norm("[Car]?").as_deref(), Some("[Car]"));
        assert_eq!(norm("@escaping () -> Void"), None);
        assert_eq!(norm("[String: Car]"), None);
        assert_eq!(norm("A & B"), None);
    }
}
