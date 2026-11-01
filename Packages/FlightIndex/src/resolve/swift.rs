//! Swift modules. Swift files import modules, not files, so the unit of visibility is the module:
//! every file of a SwiftPM target (or Xcode target directory) sees every other.

use super::Resolver;
use std::collections::HashMap;

/// The directory that holds a Swift file's module: `Sources/<Target>` or `Tests/<Target>`, with
/// any package prefix (`Packages/HostKit/Sources/HostKit`). Files outside that layout (an Xcode
/// project's app folders, scripts) are grouped by their top-level directory: a coarse guess, but
/// one that keeps unrelated trees apart and never merges the whole repository into one module.
pub fn swift_module_key(path: &str) -> String {
    let comps: Vec<&str> = path.split('/').collect();
    for (i, c) in comps.iter().enumerate() {
        if matches!(*c, "Sources" | "Tests") && i + 2 < comps.len() {
            return comps[..=i + 1].join("/");
        }
    }
    if comps.len() > 1 { comps[0].to_string() } else { String::new() }
}

/// What `import Name` names: the last component of a module key.
pub fn swift_module_name(key: &str) -> &str {
    key.rsplit('/').next().unwrap_or(key)
}

/// Module name -> every module key bearing it (two packages may each have a `Core`).
pub(super) fn swift_module_names<'a>(paths: impl Iterator<Item = &'a String>) -> HashMap<String, Vec<String>> {
    let mut out: HashMap<String, Vec<String>> = HashMap::new();
    for p in paths.filter(|p| p.ends_with(".swift")) {
        let key = swift_module_key(p);
        let keys = out.entry(swift_module_name(&key).to_string()).or_default();
        if !keys.contains(&key) {
            keys.push(key);
        }
    }
    out
}

impl Resolver {
    pub fn swift_modules_named(&self, name: &str) -> &[String] {
        self.swift_modules.get(name).map(|v| v.as_slice()).unwrap_or(&[])
    }
}
