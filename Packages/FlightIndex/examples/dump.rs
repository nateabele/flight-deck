//! Print a file's tree-sitter tree with field names: `cargo run --example dump -- <elm|rust|ts|tsx|js|elixir|swift|python> <file>`.
//! The way to find the node kinds a new language extractor needs.
use tree_sitter::{Node, Parser};
fn walk(n: Node, src: &[u8], depth: usize, field: Option<&str>) {
    let text = if n.child_count() == 0 || n.byte_range().len() < 40 { format!(" {:?}", n.utf8_text(src).unwrap().replace('\n', "\\n")) } else { String::new() };
    if n.is_named() {
        println!("{}{}{}{}", "  ".repeat(depth), field.map(|f| format!("{f}: ")).unwrap_or_default(), n.kind(), text);
    }
    let mut c = n.walk();
    for (i, ch) in n.children(&mut c).enumerate() {
        walk(ch, src, depth + 1, n.field_name_for_child(i as u32));
    }
}
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let lang: tree_sitter::Language = match a[1].as_str() {
        "elm" => tree_sitter_elm::LANGUAGE.into(),
        "rust" => tree_sitter_rust::LANGUAGE.into(),
        "elixir" => tree_sitter_elixir::LANGUAGE.into(),
        "swift" => tree_sitter_swift::LANGUAGE.into(),
        "python" => tree_sitter_python::LANGUAGE.into(),
        "ts" => tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
        "tsx" => tree_sitter_typescript::LANGUAGE_TSX.into(),
        _ => tree_sitter_javascript::LANGUAGE.into(),
    };
    let src = std::fs::read(&a[2]).unwrap();
    let mut p = Parser::new();
    p.set_language(&lang).unwrap();
    let t = p.parse(&src, None).unwrap();
    walk(t.root_node(), &src, 0, None);
}
