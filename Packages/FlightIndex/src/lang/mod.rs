//! One module per language behind a small trait.
//!
//! Adding a language is one file here plus one line in `REGISTRY`: implement `Language`, bump
//! nothing else. `parser_version` is part of the facts' store key, so changing one language's
//! extractor (and its version) re-parses only that language's blobs.

mod ecma;
mod elm;
mod javascript;
mod rust;
mod typescript;
pub(crate) mod util;

use crate::facts::BlobFacts;
use std::path::Path;

pub trait Language: Sync + Send {
    /// Stable id stored in the database (`elm`, `rust`, `typescript`, `tsx`, `javascript`).
    fn id(&self) -> &'static str;
    /// Bump when `extract` output changes for the same input, so stored facts are re-derived.
    fn parser_version(&self) -> u32;
    /// Lower-case file extensions without the dot.
    fn extensions(&self) -> &'static [&'static str];
    /// Pure function of the source text: no paths, no I/O.
    fn extract(&self, source: &str) -> BlobFacts;
}

static REGISTRY: &[&dyn Language] = &[
    &elm::Elm,
    &rust::Rust,
    &typescript::TypeScript,
    &typescript::Tsx,
    &javascript::JavaScript,
];

pub fn all() -> &'static [&'static dyn Language] {
    REGISTRY
}

pub fn by_id(id: &str) -> Option<&'static dyn Language> {
    REGISTRY.iter().copied().find(|l| l.id() == id)
}

pub fn for_path(path: &Path) -> Option<&'static dyn Language> {
    let ext = path.extension()?.to_str()?.to_ascii_lowercase();
    REGISTRY.iter().copied().find(|l| l.extensions().contains(&ext.as_str()))
}
