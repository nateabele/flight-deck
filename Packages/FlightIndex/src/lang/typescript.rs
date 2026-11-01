//! TypeScript and TSX. Same extractor, different grammar (TSX allows JSX and forbids `<T>x` casts).

use super::{ecma, Language};
use crate::facts::BlobFacts;

pub struct TypeScript;
pub struct Tsx;

impl Language for TypeScript {
    fn id(&self) -> &'static str {
        "typescript"
    }

    fn parser_version(&self) -> u32 {
        1
    }

    fn extensions(&self) -> &'static [&'static str] {
        &["ts", "mts", "cts"]
    }

    fn extract(&self, source: &str) -> BlobFacts {
        ecma::extract(&tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(), source)
    }
}

impl Language for Tsx {
    fn id(&self) -> &'static str {
        "tsx"
    }

    fn parser_version(&self) -> u32 {
        1
    }

    fn extensions(&self) -> &'static [&'static str] {
        &["tsx"]
    }

    fn extract(&self, source: &str) -> BlobFacts {
        ecma::extract(&tree_sitter_typescript::LANGUAGE_TSX.into(), source)
    }
}
