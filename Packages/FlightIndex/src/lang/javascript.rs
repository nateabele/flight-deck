//! JavaScript (and JSX, which the JavaScript grammar parses natively).

use super::{ecma, Language};
use crate::facts::BlobFacts;

pub struct JavaScript;

impl Language for JavaScript {
    fn id(&self) -> &'static str {
        "javascript"
    }

    fn parser_version(&self) -> u32 {
        1
    }

    fn extensions(&self) -> &'static [&'static str] {
        &["js", "jsx", "mjs", "cjs"]
    }

    fn extract(&self, source: &str) -> BlobFacts {
        ecma::extract(&tree_sitter_javascript::LANGUAGE.into(), source)
    }
}
