//! `calls depth>1` as a signature-only tree, and the callers `read with=callers` appends.
//!
//! The flat `calls` rows answer "who calls this", but an agent that wants the shape two levels
//! out then reads each node to learn what it is: one round trip per node. The tree prints every
//! node's signature (never its body) nested under the function that calls it, expands a function
//! reached twice only once, marks a call back into an ancestor, and drops whole levels rather
//! than cutting the tree mid-branch when it does not fit the token budget.

use super::analysis::function_like;
use super::analysis::tag_suffix;
use super::{is_test_path, Ctx};
use crate::graph::{Confidence, SymId};
use crate::links::Views;
use crate::query::{Direction, SymbolHit};
use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::fmt::Write;
use std::path::PathBuf;

type Key = (usize, SymId);

/// Callers that `read with=callers` appends per definition.
const READ_CALLERS: usize = 5;
/// A signature is folded onto one line and cut here: an Elm annotation or a Swift attribute list
/// can run to a paragraph.
const SIG_CHARS: usize = 120;

struct Edge {
    hit: SymbolHit,
    line: u32,
    confidence: Confidence,
}

fn key(h: &SymbolHit) -> Key {
    (h.view, h.id)
}

/// Resolved before matched-by-name, then the more central (PageRank), then by place.
fn order(a: &Edge, b: &Edge) -> Ordering {
    let by_name = |e: &Edge| e.confidence == Confidence::Fallback;
    by_name(a)
        .cmp(&by_name(b))
        .then(b.hit.rank.partial_cmp(&a.hit.rank).unwrap_or(Ordering::Equal))
        .then(a.hit.path.cmp(&b.hit.path))
        .then(a.line.cmp(&b.line))
        .then(a.hit.start_line.cmp(&b.hit.start_line))
        .then(a.hit.name.cmp(&b.hit.name))
}

/// One step out from `from`: each neighbour once (its first call site), in `order`.
fn step(views: &Views, from: &SymbolHit, dir: Direction, keep: &dyn Fn(&SymbolHit) -> bool) -> Vec<Edge> {
    let raw = if dir == Direction::In { views.callers(from) } else { views.callees(from) };
    let mut best: HashMap<Key, Edge> = HashMap::new();
    for (hit, line, confidence) in raw {
        if !keep(&hit) {
            continue;
        }
        let e = Edge { hit, line, confidence };
        match best.get(&key(&e.hit)) {
            Some(old) if old.line <= e.line => {}
            _ => {
                best.insert(key(&e.hit), e);
            }
        }
    }
    let mut out: Vec<Edge> = best.into_values().collect();
    out.sort_by(order);
    out
}

/// The call graph around `root` in one direction, breadth first: every node knows the shallowest
/// level it is reached at and the parent it is reached from there, which is where it is printed
/// in full.
struct Tree {
    root: SymbolHit,
    dir: Direction,
    kids: HashMap<Key, Vec<Edge>>,
    level: HashMap<Key, u32>,
    parent: HashMap<Key, Key>,
}

impl Tree {
    fn build(views: &Views, root: &SymbolHit, dir: Direction, depth: u32, keep: &dyn Fn(&SymbolHit) -> bool) -> Tree {
        let mut t = Tree { root: root.clone(), dir, kids: HashMap::new(), level: HashMap::from([(key(root), 0)]), parent: HashMap::new() };
        let mut frontier = vec![root.clone()];
        for d in 0..depth {
            let mut next = Vec::new();
            for from in &frontier {
                let edges = step(views, from, dir, keep);
                for e in &edges {
                    let k = key(&e.hit);
                    if let std::collections::hash_map::Entry::Vacant(slot) = t.level.entry(k) {
                        slot.insert(d + 1);
                        t.parent.insert(k, key(from));
                        next.push(e.hit.clone());
                    }
                }
                t.kids.insert(key(from), edges);
            }
            frontier = next;
        }
        t
    }

    fn distinct(&self, depth: u32) -> usize {
        self.level.values().filter(|l| (1..=depth).contains(*l)).count()
    }
}

/// Printing state for one section: the rows, in tree order, each with its level and whether it is
/// a function's full row (a `↑` or `↺` row only points at one).
struct Pen<'a> {
    views: &'a Views<'a>,
    tree: &'a Tree,
    depth: u32,
    expanded: HashSet<Key>,
    rows: Vec<(u32, bool, String)>,
}

impl Pen<'_> {
    fn walk(&mut self, node: Key, level: u32, stack: &mut Vec<Key>) {
        let Some(kids) = self.tree.kids.get(&node) else { return };
        for e in kids {
            let k = key(&e.hit);
            let mark = if stack.contains(&k) {
                Some('↺')
            } else if self.tree.parent.get(&k) == Some(&node) && self.tree.level.get(&k) == Some(&(level + 1)) && !self.expanded.contains(&k) {
                None
            } else {
                Some('↑')
            };
            self.row(e, level + 1, mark);
            if mark.is_none() {
                self.expanded.insert(k);
                if level + 1 < self.depth {
                    stack.push(k);
                    self.walk(k, level + 1, stack);
                    stack.pop();
                }
            }
        }
    }

    fn row(&mut self, e: &Edge, level: u32, mark: Option<char>) {
        let h = &e.hit;
        // A caller row names the call site, which is in the caller's own file; a callee row names
        // the callee's definition, with the line of the call in its parent.
        let at = if self.tree.dir == Direction::In {
            format!("{}:L{}", h.path.display(), e.line)
        } else {
            format!("{}:L{} call@L{}", h.path.display(), h.start_line, e.line)
        };
        let by_name = if e.confidence == Confidence::Fallback { " (matched by name)" } else { "" };
        let tail = match mark {
            Some(m) => format!(" {m}"),
            None => h.signature.as_deref().map(fold).filter(|s| !s.is_empty()).map(|s| format!(" · {s}")).unwrap_or_default(),
        };
        self.rows.push((level, mark.is_none(), format!("{}- {} {at}{}{by_name}{tail}", "  ".repeat(level as usize), h.name, tag_suffix(self.views, h.view))));
    }
}

/// A signature on one line: whitespace runs folded to a space, cut at `SIG_CHARS`.
fn fold(sig: &str) -> String {
    let one = sig.split_whitespace().collect::<Vec<_>>().join(" ");
    if one.chars().count() > SIG_CHARS { format!("{}…", one.chars().take(SIG_CHARS).collect::<String>()) } else { one }
}

/// One direction's tree printed `depth` levels deep, and how many rows `limit` left out of its
/// last level; `None` when the levels above the last already exceed `limit`. `why` names what
/// pushed the next level out, when the caller asked for more levels than this.
fn section(views: &Views, title: &str, tree: &Tree, depth: u32, of: u32, limit: usize, why: &str) -> Option<(String, usize)> {
    let mut pen = Pen { views, tree, depth, expanded: HashSet::new(), rows: Vec::new() };
    let mut stack = vec![key(&tree.root)];
    pen.walk(key(&tree.root), 0, &mut stack);
    // `limit` counts functions, as the flat rows do: the pointer rows are short and always shown.
    let above = pen.rows.iter().filter(|(l, full, _)| *full && *l < depth).count();
    if depth > 1 && above > limit {
        return None;
    }
    // The last level is filled in tree order (most central parents first) up to `limit`.
    let mut quota = limit - above.min(limit);
    let mut omitted = 0;
    let mut body = String::new();
    for (level, full, row) in &pen.rows {
        if *full && *level == depth {
            if quota == 0 {
                omitted += 1;
                continue;
            }
            quota -= 1;
        }
        body.push_str(row);
        body.push('\n');
    }
    let shown = if depth < of { format!("depth {depth} of {of}; level {} exceeds {why}", depth + 1) } else { format!("depth {depth}") };
    let mut out = format!("{title} (tree, {shown}, {} distinct):\n", tree.distinct(depth));
    out.push_str(&body);
    if omitted > 0 {
        let _ = writeln!(out, "  … {omitted} more row(s) at level {depth}; pass limit={} to see them", pen.rows.iter().filter(|r| r.1).count());
    }
    Some((out, omitted))
}

/// The `calls` answer for depth ≥ 2: a header, a legend, and a tree per requested direction.
/// Each direction goes as deep as its levels above the last fit `limit` functions (the last is
/// filled up to it); then, while the text exceeds the token budget, the deepest level goes. Levels
/// are dropped whole: a tree cut at its tail would lose the later branches of level 1, which
/// matter more than the earlier branches' grandchildren.
#[allow(clippy::too_many_arguments)]
pub fn render(c: &Ctx, views: &Views, target: &SymbolHit, callers: bool, callees: bool, depth: u32, limit: usize, keep: &dyn Fn(&SymbolHit) -> bool) -> String {
    let trees: Vec<(&str, Tree)> = [("Callers", callers, Direction::In), ("Callees", callees, Direction::Out)]
        .into_iter()
        .filter(|(_, want, _)| *want)
        .map(|(title, _, dir)| (title, Tree::build(views, target, dir, depth, keep)))
        .collect();
    let mut head = format!("Call tree for {} ({}) @ {}:L{}-{}{}\n", target.name, target.kind.as_str(), target.path.display(), target.start_line, target.end_line, tag_suffix(views, target.view));
    if let Some(s) = target.signature.as_deref().map(fold).filter(|s| !s.is_empty()) {
        let _ = writeln!(head, "  {s}");
    }
    head.push_str("Signatures only (read a name for its body). ↑ printed in full elsewhere in this tree; ↺ calls back into an ancestor.\n");
    // The rows above the last level only grow with depth, so the first depth that fits is the
    // deepest that does.
    let deepest: Vec<u32> = trees.iter().map(|(title, tree)| (2..=depth).rev().find(|d| section(views, title, tree, *d, depth, limit, "").is_some()).unwrap_or(1)).collect();
    let max = c.token_budget.saturating_mul(4);
    let top = deepest.iter().copied().max().unwrap_or(1);
    for cap in (1..=top).rev() {
        let mut text = head.clone();
        for ((title, tree), most) in trees.iter().zip(&deepest) {
            let d = cap.min(*most);
            let why = if d < *most { format!("token_budget={}", c.token_budget) } else { format!("limit={limit}") };
            if let Some((s, _)) = section(views, title, tree, d, depth, limit, &why) {
                text.push_str(&s);
            }
        }
        if cap == 1 || text.len() <= max {
            return c.fit(text);
        }
    }
    unreachable!("cap 1 always returns")
}

/// The callers block `read with=callers` prints after a definition: up to `READ_CALLERS` callers,
/// each with its signature and the source line of its call.
pub fn read_callers(views: &Views, d: &SymbolHit, out: &mut String) {
    if !function_like(d.kind) {
        let _ = writeln!(out, "// callers: {} is a {}, not function-like; `refs` lists its uses", d.name, d.kind.as_str());
        return;
    }
    let mut edges = step(views, d, Direction::In, &|_| true);
    // Tests last: they call everything and say least about how the code is used.
    edges.sort_by_key(|e| is_test_path(&e.hit.path.strip_prefix(&views.graph(e.hit.view).root).unwrap_or(&e.hit.path).to_string_lossy()));
    if edges.is_empty() {
        let _ = writeln!(out, "// callers (0): none found");
        return;
    }
    let _ = writeln!(out, "// callers ({} of {}):", edges.len().min(READ_CALLERS), edges.len());
    let mut files: HashMap<PathBuf, Option<String>> = HashMap::new();
    for e in edges.iter().take(READ_CALLERS) {
        let h = &e.hit;
        let by_name = if e.confidence == Confidence::Fallback { " (matched by name)" } else { "" };
        let sig = h.signature.as_deref().map(fold).filter(|s| !s.is_empty()).map(|s| format!(" · {s}")).unwrap_or_default();
        let _ = writeln!(out, "// ← {} @ {}:L{}{}{by_name}{sig}", h.name, h.path.display(), e.line, tag_suffix(views, h.view));
        let text = files.entry(h.path.clone()).or_insert_with(|| std::fs::read_to_string(&h.path).ok());
        if let Some(line) = text.as_deref().and_then(|t| t.lines().nth(e.line.saturating_sub(1) as usize)) {
            let line = line.trim();
            let line = if line.chars().count() > 160 { format!("{}…", line.chars().take(160).collect::<String>()) } else { line.to_string() };
            let _ = writeln!(out, "//   {} | {line}", e.line);
        }
    }
    if edges.len() > READ_CALLERS {
        let _ = writeln!(out, "// … {} more: `calls name={} direction=callers`", edges.len() - READ_CALLERS, d.name);
    }
}
