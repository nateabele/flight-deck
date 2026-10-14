// Claude Code's fenced-code highlighting, reproduced so the phone colours a code block the way
// the desktop's terminal does. Loaded into a JSContext after highlight-11.11.1.min.js — the
// highlight.js version Claude Code 2.1.x bundles, with every language it can lazy-load.
//
// What Claude Code does with a ```lang fence (read out of its 2.1.296 bundle):
//   1. highlight.js tokenises the code (`ignoreIllegals: true`) into its emitter tree.
//   2. Each node's scope maps to a chalk style through the table below; a scope with no entry
//      falls back to its dotted parent ("title.function.invoke" → "title.function"), and a
//      node with no style at all passes its children through unstyled.
//   3. The ANSI that produces is drawn by the terminal through its palette.
// Steps 1 and 2 run here, chalk included, so nesting and the `reset` scopes behave exactly as
// they do there (a `title` inside a coloured node clears the colour for the rest of that node,
// which is chalk's doing, not a choice). Step 3 is parsed back into runs for Swift, which
// resolves the palette indices against Flight Deck's own Ghostty themes.

(function () {
  "use strict";
  var ESC = "\u001B[";

  // chalk 5's applyStyle, cut down to the styles the table uses.
  function style(open, close, parent) {
    var s = { open: ESC + open + "m", close: ESC + close + "m", parent: parent };
    s.openAll = parent ? parent.openAll + s.open : s.open;
    s.closeAll = parent ? s.close + parent.closeAll : s.close;
    var fn = function (string) {
      if (!string) return string;
      if (string.indexOf("\u001B") !== -1) {
        for (var st = s; st; st = st.parent) string = string.split(st.close).join(st.open);
      }
      if (string.indexOf("\n") !== -1) {
        string = string.replace(/\r?\n/g, function (lf) { return s.closeAll + lf + s.openAll; });
      }
      return s.openAll + string + s.closeAll;
    };
    fn.style = s;
    return fn;
  }

  var blue = style(34, 39), cyan = style(36, 39), green = style(32, 39), red = style(31, 39),
      yellow = style(33, 39), grey = style(90, 39), italic = style(3, 23), bold = style(1, 22),
      underline = style(4, 24), reset = style(0, 0);
  var cyanDim = style(2, 22, cyan.style);
  var RESET = ESC + "0m";

  // Claude Code's `i`: a reset that also survives an inner reset and line breaks.
  function plain(t) {
    return t.indexOf(RESET) !== -1
      ? RESET + t.replace(/\r?\n/g, function (lf) { return RESET + lf + RESET; }) + RESET
      : reset(t);
  }

  var table = {
    keyword: blue, built_in: cyan, type: cyanDim, literal: blue, number: green, regexp: red,
    string: red, subst: plain, symbol: plain, class: blue, function: yellow, title: plain,
    "title.function": yellow, "title.class": blue, params: plain, comment: green, doctag: green,
    meta: grey, "meta-keyword": plain, "meta-string": plain, "meta.keyword": plain,
    "meta.string": plain, section: plain, tag: grey, name: blue, attr: cyan, attribute: plain,
    variable: plain, bullet: plain, code: plain, emphasis: italic, strong: bold, link: underline,
    quote: plain, addition: green, deletion: red
  };

  function styleFor(scope) {
    var e = scope.replace(/^hljs-/, "");
    for (;;) {
      if (Object.prototype.hasOwnProperty.call(table, e)) return table[e];
      var dot = e.lastIndexOf(".");
      if (dot < 0) return undefined;
      e = e.slice(0, dot);
    }
  }

  function render(node) {
    if (typeof node === "string") return node;
    var text = node.children.map(render).join("");
    var scope = node.scope || node.kind;
    var fn = scope ? styleFor(scope) : undefined;
    return fn ? fn(text) : text;
  }

  // Claude Code tries the info string whole, then its leading word, then gives up to plaintext.
  function resolve(info) {
    if (!info) return null;
    if (hljs.getLanguage(info.toLowerCase())) return info.toLowerCase();
    var m = info.match(/^[\w.+#-]+/);
    if (m && hljs.getLanguage(m[0].toLowerCase())) return m[0].toLowerCase();
    return "plaintext";
  }

  // ANSI back to runs: [text, fg, flags], fg -1 for the default foreground or a palette index
  // 0-15, flags a bitmask of 1 bold, 2 faint, 4 italic, 8 underline.
  function runs(ansi) {
    var out = [], fg = -1, flags = 0, re = /\u001B\[([0-9;]*)m/g, last = 0, m;
    function push(t) {
      if (!t) return;
      var prev = out[out.length - 1];
      if (prev && prev[1] === fg && prev[2] === flags) prev[0] += t;
      else out.push([t, fg, flags]);
    }
    while ((m = re.exec(ansi)) !== null) {
      push(ansi.slice(last, m.index));
      last = re.lastIndex;
      var codes = m[1] === "" ? [0] : m[1].split(";").map(Number);
      for (var i = 0; i < codes.length; i++) {
        var c = codes[i];
        if (c === 0) { fg = -1; flags = 0; }
        else if (c === 1) flags |= 1;
        else if (c === 2) flags |= 2;
        else if (c === 22) flags &= ~3;
        else if (c === 3) flags |= 4;
        else if (c === 23) flags &= ~4;
        else if (c === 4) flags |= 8;
        else if (c === 24) flags &= ~8;
        else if (c >= 30 && c <= 37) fg = c - 30;
        else if (c >= 90 && c <= 97) fg = c - 90 + 8;
        else if (c === 39) fg = -1;
      }
    }
    push(ansi.slice(last));
    return out;
  }

  // Returns JSON runs, or null for "not highlighted": no language (the caller draws that in
  // Claude Code's `permission` colour) or a grammar that threw.
  this.claudeCodeHighlight = function (code, info) {
    var language = resolve(info);
    if (!language) return null;
    try {
      var result = hljs.highlight(code, { language: language, ignoreIllegals: true });
      var emitter = result._emitter || result.emitter;
      var root = emitter && (emitter.rootNode || emitter.root);
      if (!root || typeof root === "string") return JSON.stringify([[code, -1, 0]]);
      return JSON.stringify(runs(root.children.map(render).join("")));
    } catch (e) {
      return JSON.stringify([[code, -1, 0]]);
    }
  };
}).call(this);
