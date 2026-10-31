# Built-in canvas UI kit — OSS research

Researched 2026-10-25. Scope: HTML/CSS representations of SwiftUI/AppKit-style controls inside Flight Deck, not a desktop clone or a new native rendering framework. This is source/documentation research; no candidate has been installed, benchmarked, or visually tested in WKWebView.

## Recommendation

Start the implementation spike with **Puppertino** as the CSS foundation, compare **MacVue** on control accuracy, and expose either through Flight Deck-owned semantic components. Keep the agent API independent of upstream class names or JavaScript framework choices. The final baseline is selected after a representative native-vs-HTML comparison on the supported macOS/WebKit versions.

| Candidate | Verified upstream evidence | Fit and decision |
|---|---|---|
| [Puppertino](https://github.com/codedgar/Puppertino) | Plain CSS, optional vanilla-JS helpers, desktop/mobile bundles, appearance and component styles. [README](https://raw.githubusercontent.com/codedgar/Puppertino/master/README.md), [MIT license](https://raw.githubusercontent.com/codedgar/Puppertino/master/LICENSE). | Preferred framework-neutral baseline. Adapt missing/mismatched native details behind our catalog; do not assume its newest appearance matches a project's target OS. |
| [MacVue](https://github.com/antonreshetov/macvue) | Vue controls explicitly targeting AppKit sizes/states; upstream marks tokens unstable before 1.0. Its refraction has a WebKit fallback. [README](https://raw.githubusercontent.com/antonreshetov/macvue/main/README.md), [MIT license](https://raw.githubusercontent.com/antonreshetov/macvue/main/LICENSE). | Strong comparative spike for native control detail. Evaluate adopting selected CSS/metrics with attribution versus bundling Vue. Do not force Vue on project previews. |
| [Darwin UI](https://github.com/surajmandalcell/darwin-ui) | React 19, Tailwind v4 and Framer Motion, macOS-inspired glass styling. [README](https://raw.githubusercontent.com/surajmandalcell/darwin-ui/main/README.md), [MIT license](https://raw.githubusercontent.com/surajmandalcell/darwin-ui/main/LICENSE). | Alternative for React preview recipes. Higher framework commitment and no evidence yet of native metric equivalence; not the default renderer. |
| [Photon](https://github.com/connors/photon) | HTML/CSS desktop toolkit with dist, Sass, fonts, and [MIT license](https://raw.githubusercontent.com/connors/photon/master/LICENSE). | Older visual vocabulary; useful comparison/reference, not selected for current native fidelity. Audit font assets separately if any code is reused. |
| [Tokamak](https://github.com/TokamakUI/Tokamak) | SwiftUI-compatible browser framework with a partial API; repository is archived. [Apache-2.0 license](https://raw.githubusercontent.com/TokamakUI/Tokamak/main/LICENSE). | Different problem: compiling a SwiftUI-like program for the web. Do not make the fast HTML kit depend on Swift/Wasm compilation or an archived framework. |

Flight Deck's root license is BSD-3-Clause. The selected candidates' MIT source licenses allow reuse with retained copyright/license notices; keep those notices with vendored files and in shipped third-party acknowledgments. The proposed reuse leaves upstream files under their original licenses. Exact pinned revisions, dependency manifests, fonts/icons, optional effects, and NOTICE files are checked in the import task. No blanket claim about every asset in a repository follows from its root license.

## WebKit constraint

MacVue explicitly documents a CSS material fallback where its SVG displacement effect is unsupported. [WebKit issue 245510](https://bugs.webkit.org/show_bug.cgi?id=245510) remains open as of this research. Therefore a Chromium demo is insufficient evidence of WKWebView fidelity. Use solid/blurred material fallbacks as the baseline and feature-test optional effects; do not promise identical native Liquid Glass. No GPU-heavy effect belongs on the per-operation rendering path by default.

## Component contract

Publish concise semantic recipes, for example:

```json
{"type":"Button","id":"save","props":{"title":"Save","role":"default","controlSize":"regular","enabled":true,"action":"settings.save"}}
```

`NSButton` is a documented alias for the applicable button recipe, not an Objective-C API interpreter. Layout stacks, split views, forms, lists/tables, toolbars, sidebars, sheets/popovers, fields, selection controls, and progress get similarly versioned contracts. Associate aliases with precise supported behaviors; unsupported styles produce a visible diagnostic, never a generic replacement without notice. Project-specific recipes override system defaults explicitly.

Keep control value, focus, selection and expansion state in the existing interaction-state layer. Rendering helpers attach/detach once per stable element and provide serializers; upstream scripts must not repeatedly install listeners or reset state on every patch.

## Acceptance spike

1. Build a small SwiftUI/AppKit reference gallery for Button, TextField, Toggle/NSButton checkbox, segmented control, pop-up, slider, toolbar, sidebar/list, and sheet. Use the project's supported OS baseline and one current installed OS, with the OS recorded in every result.
2. Render the same fixtures using Puppertino and MacVue in actual WKWebView. Compare light/dark, control sizes, disabled/focus/pressed states, accent, active/inactive window, transparency preferences, 1x/2x scale and keyboard behavior. Select the baseline with measured per-control gaps and integration cost; no universal fidelity percentage based on a screenshot.
3. Preserve input/IME/caret/selection across updates and subtree restore. Confirm node IDs, annotation anchors, and serialized values survive. Test reference controls without taking the user's screen; run GUI comparison on the dedicated test Mac.
4. Calibrate Flight Deck-owned overrides and record missing behaviors. Use local system font stacks by default; do not redistribute Apple font/symbol files under an assumed MIT permission.
5. Pin immutable source revisions and hashes, ship CSS/helpers locally without a CDN, retain attribution, and add visual/interaction fixtures. Later upstream updates need explicit comparison and approval through normal dependency review, rather than changing checkpoint appearance on replay.

## Integration recommendation

Use a bundled `Resources/Canvas/` web renderer in a persistent WKWebView, with a TypeScript-owned document/history engine and Swift-backed storage and native integration (architecture revised 2026-10-26). [WKWebView](https://developer.apple.com/documentation/webkit/wkwebview), [WKScriptMessageHandler](https://developer.apple.com/documentation/webkit/wkscriptmessagehandler), and [WKURLSchemeHandler](https://developer.apple.com/documentation/webkit/wkurlschemehandler) are the API surfaces to validate in the integration spike. Keep preview script execution isolated from native commands. Node/Vue/React, if used to build assets, must not become an implicit external runtime requirement for Flight Deck's built-in kit.
