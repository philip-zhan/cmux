import {
  Compartment,
  EditorState,
  StateEffect,
  StateField,
  type Extension,
} from "@codemirror/state";
import {
  Decoration,
  type DecorationSet,
  EditorView,
  type Panel,
  WidgetType,
  drawSelection,
  highlightActiveLine,
  highlightActiveLineGutter,
  keymap,
  lineNumbers,
} from "@codemirror/view";
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import {
  SearchQuery,
  closeSearchPanel,
  findNext,
  findPrevious,
  getSearchQuery,
  replaceAll,
  replaceNext,
  search,
  searchKeymap,
  setSearchQuery,
} from "@codemirror/search";
import { StreamLanguage, forceParsing } from "@codemirror/language";
import { javascript } from "@codemirror/lang-javascript";
import { python } from "@codemirror/lang-python";
import { rust } from "@codemirror/lang-rust";
import { json } from "@codemirror/lang-json";
import { markdown } from "@codemirror/lang-markdown";
import { html } from "@codemirror/lang-html";
import { css } from "@codemirror/lang-css";
import { sql } from "@codemirror/lang-sql";
import { yaml } from "@codemirror/lang-yaml";
import { xml } from "@codemirror/lang-xml";
import { cpp } from "@codemirror/lang-cpp";
import { go } from "@codemirror/lang-go";
import { java } from "@codemirror/lang-java";
import { php } from "@codemirror/lang-php";
import { swift } from "@codemirror/legacy-modes/mode/swift";
import { shell } from "@codemirror/legacy-modes/mode/shell";
import { toml } from "@codemirror/legacy-modes/mode/toml";
import { ruby } from "@codemirror/legacy-modes/mode/ruby";
import { lua } from "@codemirror/legacy-modes/mode/lua";
import { oneDark } from "@codemirror/theme-one-dark";
import { MergeView } from "@codemirror/merge";

type ThemePalette = {
  background: string;
  foreground: string;
  gutterBackground: string;
  gutterForeground: string;
  selectionBackground: string;
  activeLineBackground: string;
};

type Payload = {
  content?: string;
  language?: string;
  isDark?: boolean;
  fontSize?: number;
  readOnly?: boolean;
  diffOriginal?: string;
  diffModified?: string;
  theme?: ThemePalette;
};

type SwiftHandler = {
  postMessage: (msg: { action: string; [k: string]: unknown }) => void;
};

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        cmuxCode?: SwiftHandler;
      };
    };
  }
}

function postToSwift(action: string, extra: Record<string, unknown> = {}) {
  const handler = window.webkit?.messageHandlers?.cmuxCode;
  if (!handler) return;
  try {
    handler.postMessage({ action, ...extra });
  } catch {
    // No-op: WebKit may have torn down the bridge.
  }
}

const fontSizeCompartment = new Compartment();
const themeCompartment = new Compartment();
const languageCompartment = new Compartment();
const readOnlyCompartment = new Compartment();

function languageExtension(id: string | undefined): Extension {
  switch (id) {
    case "typescript":
    case "tsx":
      return javascript({ typescript: true, jsx: true });
    case "javascript":
    case "jsx":
      return javascript({ jsx: true });
    case "python":
      return python();
    case "rust":
      return rust();
    case "json":
      return json();
    case "markdown":
      return markdown();
    case "html":
      return html();
    case "css":
      return css();
    case "sql":
      return sql();
    case "yaml":
      return yaml();
    case "xml":
      return xml();
    case "cpp":
    case "c":
      return cpp();
    case "go":
      return go();
    case "java":
      return java();
    case "php":
      return php();
    case "swift":
      return StreamLanguage.define(swift);
    case "shell":
    case "bash":
      return StreamLanguage.define(shell);
    case "toml":
      return StreamLanguage.define(toml);
    case "ruby":
      return StreamLanguage.define(ruby);
    case "lua":
      return StreamLanguage.define(lua);
    default:
      return [];
  }
}

let contentChangeTimer: number | null = null;
function scheduleContentChange(view: EditorView) {
  if (contentChangeTimer != null) {
    window.clearTimeout(contentChangeTimer);
  }
  contentChangeTimer = window.setTimeout(() => {
    contentChangeTimer = null;
    postToSwift("contentChanged", { content: view.state.doc.toString() });
  }, 120);
}

const contentChangeListener = EditorView.updateListener.of((u) => {
  if (u.docChanged) scheduleContentChange(u.view);
});

const REPLACE_ICON =
  '<svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" ' +
  'stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">' +
  '<path d="M8 2.5v6"/><path d="M5.3 5.8 8 8.5l2.7-2.7"/><path d="M3.5 12.5h9"/></svg>';
const REPLACE_ALL_ICON =
  '<svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" ' +
  'stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">' +
  '<path d="M8 1.5v5"/><path d="M5.3 4.3 8 7l2.7-2.7"/><path d="M3.5 10.5h9"/><path d="M3.5 13.5h9"/></svg>';

// A minimal find/replace widget modeled on VS Code's: a compact bar attached
// to the top-right edge. The case / whole-word / regex toggles are tucked
// inside the find input; a chevron expands the replace row.
function createSearchPanel(view: EditorView): Panel {
  const initial = getSearchQuery(view.state);
  let caseSensitive = initial.caseSensitive;
  let wholeWord = initial.wholeWord;
  let regexp = initial.regexp;
  let replaceShown = false;

  const dom = document.createElement("div");
  dom.className = "cmux-search";
  dom.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
      e.preventDefault();
      closeSearchPanel(view);
      view.focus();
    }
  });

  const makeButton = (cls: string, label: string, title: string) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = cls;
    button.textContent = label;
    button.title = title;
    button.setAttribute("aria-label", title);
    button.tabIndex = -1;
    return button;
  };
  const makeIconButton = (cls: string, svg: string, title: string) => {
    const button = makeButton(cls, "", title);
    button.innerHTML = svg;
    return button;
  };

  const field = document.createElement("input");
  field.className = "cmux-search-input";
  field.placeholder = "Find";
  field.spellcheck = false;
  field.setAttribute("aria-label", "Find");
  field.setAttribute("main-field", "true");
  field.value = initial.search;

  const replaceField = document.createElement("input");
  replaceField.className = "cmux-search-input";
  replaceField.placeholder = "Replace";
  replaceField.spellcheck = false;
  replaceField.setAttribute("aria-label", "Replace");
  replaceField.value = initial.replace;

  const expandButton = makeButton("cmux-search-expand", "›", "Toggle Replace");
  const caseButton = makeButton("cmux-search-toggle", "Aa", "Match Case");
  const wordButton = makeButton("cmux-search-toggle", "ab", "Match Whole Word");
  const regexpButton = makeButton("cmux-search-toggle", ".*", "Use Regular Expression");
  const prevButton = makeButton("cmux-search-action", "↑", "Previous Match");
  const nextButton = makeButton("cmux-search-action", "↓", "Next Match");
  const closeButton = makeButton("cmux-search-action", "✕", "Close");
  const replaceButton = makeIconButton("cmux-search-action", REPLACE_ICON, "Replace");
  const replaceAllButton = makeIconButton("cmux-search-action", REPLACE_ALL_ICON, "Replace All");

  const syncToggles = () => {
    caseButton.classList.toggle("cmux-search-toggle-on", caseSensitive);
    wordButton.classList.toggle("cmux-search-toggle-on", wholeWord);
    regexpButton.classList.toggle("cmux-search-toggle-on", regexp);
  };
  syncToggles();

  const commitQuery = () => {
    view.dispatch({
      effects: setSearchQuery.of(
        new SearchQuery({
          search: field.value,
          replace: replaceField.value,
          caseSensitive,
          regexp,
          wholeWord,
        })
      ),
    });
  };

  field.addEventListener("input", commitQuery);
  field.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      if (e.shiftKey) findPrevious(view);
      else findNext(view);
    }
  });
  replaceField.addEventListener("input", commitQuery);
  replaceField.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      replaceNext(view);
    }
  });

  const toggle = (button: HTMLButtonElement, apply: () => void) => {
    button.addEventListener("click", () => {
      apply();
      syncToggles();
      commitQuery();
      field.focus();
    });
  };
  toggle(caseButton, () => {
    caseSensitive = !caseSensitive;
  });
  toggle(wordButton, () => {
    wholeWord = !wholeWord;
  });
  toggle(regexpButton, () => {
    regexp = !regexp;
  });
  prevButton.addEventListener("click", () => {
    findPrevious(view);
    field.focus();
  });
  nextButton.addEventListener("click", () => {
    findNext(view);
    field.focus();
  });
  closeButton.addEventListener("click", () => {
    closeSearchPanel(view);
    view.focus();
  });
  replaceButton.addEventListener("click", () => {
    replaceNext(view);
  });
  replaceAllButton.addEventListener("click", () => {
    replaceAll(view);
  });

  const toggles = document.createElement("div");
  toggles.className = "cmux-search-toggles";
  toggles.append(caseButton, wordButton, regexpButton);

  const fieldWrap = document.createElement("div");
  fieldWrap.className = "cmux-search-field";
  fieldWrap.append(field, toggles);

  const replaceWrap = document.createElement("div");
  replaceWrap.className = "cmux-search-field";
  replaceWrap.append(replaceField);

  const findRow = document.createElement("div");
  findRow.className = "cmux-search-row";
  findRow.append(fieldWrap, prevButton, nextButton, closeButton);

  const replaceRow = document.createElement("div");
  replaceRow.className = "cmux-search-row cmux-search-replace-row";
  replaceRow.append(replaceWrap, replaceButton, replaceAllButton);
  replaceRow.style.display = "none";

  const rows = document.createElement("div");
  rows.className = "cmux-search-rows";
  rows.append(findRow, replaceRow);

  const setReplaceShown = (shown: boolean) => {
    replaceShown = shown;
    replaceRow.style.display = shown ? "" : "none";
    expandButton.textContent = shown ? "⌄" : "›";
    expandButton.classList.toggle("cmux-search-expand-on", shown);
  };
  expandButton.addEventListener("click", () => {
    setReplaceShown(!replaceShown);
    if (replaceShown) replaceField.focus();
    else field.focus();
  });

  dom.append(expandButton, rows);

  // Replace is meaningless in a read-only document — hide the affordance.
  const applyReadOnly = () => {
    const readOnly = view.state.readOnly;
    expandButton.style.display = readOnly ? "none" : "";
    if (readOnly && replaceShown) setReplaceShown(false);
  };
  applyReadOnly();

  return {
    dom,
    top: true,
    update(u) {
      if (u.state.readOnly !== u.startState.readOnly) applyReadOnly();
    },
    mount() {
      if (field.value && field.value !== getSearchQuery(view.state).search) {
        commitQuery();
      }
      field.focus();
      field.select();
    },
  };
}

// Colors are driven by CSS variables set in `setPanelVars` so the widget
// tracks the active theme.
function searchPanelTheme(): Extension {
  return EditorView.theme({
    ".cm-panels.cm-panels-top": {
      position: "absolute",
      top: "0",
      right: "14px",
      left: "auto",
      width: "auto",
      backgroundColor: "transparent",
      border: "none",
      zIndex: "20",
    },
    ".cmux-search": {
      display: "flex",
      alignItems: "stretch",
      gap: "2px",
      padding: "4px",
      borderRadius: "0 0 4px 4px",
      backgroundColor: "var(--cmux-panel-bg)",
      border: "1px solid var(--cmux-panel-border)",
      borderTop: "none",
      boxShadow: "0 2px 8px rgba(0, 0, 0, 0.3)",
      color: "var(--cmux-panel-fg)",
      fontFamily: "ui-sans-serif, system-ui, -apple-system, sans-serif",
    },
    ".cmux-search-expand": {
      width: "14px",
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
      padding: "0",
      fontSize: "13px",
      lineHeight: "1",
      color: "var(--cmux-panel-fg)",
      backgroundColor: "transparent",
      border: "none",
      borderRadius: "3px",
      cursor: "pointer",
    },
    ".cmux-search-expand:hover": {
      backgroundColor: "var(--cmux-panel-hover)",
    },
    ".cmux-search-rows": {
      display: "flex",
      flexDirection: "column",
      gap: "3px",
    },
    ".cmux-search-row": {
      display: "flex",
      alignItems: "center",
      gap: "1px",
    },
    ".cmux-search-field": {
      position: "relative",
      display: "flex",
      alignItems: "center",
      marginRight: "3px",
    },
    ".cmux-search-replace-row .cmux-search-input": {
      padding: "0 6px",
    },
    ".cmux-search-input": {
      width: "170px",
      height: "22px",
      boxSizing: "border-box",
      padding: "0 70px 0 6px",
      fontSize: "12px",
      color: "var(--cmux-panel-fg)",
      backgroundColor: "var(--cmux-panel-input-bg)",
      border: "1px solid transparent",
      borderRadius: "2px",
      outline: "none",
    },
    ".cmux-search-input:focus": {
      borderColor: "var(--cmux-panel-accent)",
    },
    ".cmux-search-input::placeholder": {
      color: "var(--cmux-panel-fg)",
      opacity: "0.45",
    },
    ".cmux-search-toggles": {
      position: "absolute",
      right: "2px",
      display: "flex",
      gap: "1px",
    },
    ".cmux-search-toggle": {
      width: "20px",
      height: "18px",
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
      padding: "0",
      fontSize: "10px",
      fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
      color: "var(--cmux-panel-fg)",
      backgroundColor: "transparent",
      border: "1px solid transparent",
      borderRadius: "3px",
      cursor: "pointer",
    },
    ".cmux-search-toggle:hover": {
      backgroundColor: "var(--cmux-panel-hover)",
    },
    ".cmux-search-toggle-on": {
      backgroundColor: "var(--cmux-panel-toggle-on-bg)",
      borderColor: "var(--cmux-panel-accent)",
    },
    ".cmux-search-action": {
      width: "22px",
      height: "22px",
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
      padding: "0",
      fontSize: "12px",
      lineHeight: "1",
      color: "var(--cmux-panel-fg)",
      backgroundColor: "transparent",
      border: "none",
      borderRadius: "3px",
      cursor: "pointer",
    },
    ".cmux-search-action:hover": {
      backgroundColor: "var(--cmux-panel-hover)",
    },
  });
}

// --- Inline git blame (current line only) -----------------------------------
//
// Swift sends the whole-file blame once per load via `__cmuxCodeSetBlame`. We
// keep it in a StateField and render a single end-of-line annotation on the
// line the cursor is on (GitLens-style), recomputed whenever the selection,
// document, or blame data changes.

type BlameLine = {
  h: string; // short hash ("" when uncommitted)
  a: string; // author ("You" when uncommitted)
  t: number; // author time, epoch seconds (0 when uncommitted)
  s: string; // commit summary ("" when uncommitted)
  u: boolean; // isUncommitted
};

const setBlameEffect = StateEffect.define<BlameLine[] | null>();

const blameDataField = StateField.define<BlameLine[] | null>({
  create: () => null,
  update(value, tr) {
    for (const effect of tr.effects) {
      if (effect.is(setBlameEffect)) return effect.value;
    }
    return value;
  },
});

function relativeTime(epochSeconds: number): string {
  if (!epochSeconds) return "";
  const seconds = Math.floor(Date.now() / 1000) - epochSeconds;
  if (seconds < 60) return "just now";
  const units: [number, string][] = [
    [60, "minute"],
    [60, "hour"],
    [24, "day"],
    [7, "week"],
    [4.345, "month"],
    [12, "year"],
  ];
  let value = seconds / 60;
  let unit = "minute";
  for (let i = 1; i < units.length; i++) {
    if (value < units[i][0]) break;
    value /= units[i][0];
    unit = units[i][1];
  }
  const rounded = Math.floor(value);
  return `${rounded} ${unit}${rounded === 1 ? "" : "s"} ago`;
}

function blameText(line: BlameLine): string {
  if (line.u) return "You · Uncommitted changes";
  const when = relativeTime(line.t);
  const summary = line.s.length > 60 ? `${line.s.slice(0, 59)}…` : line.s;
  return [line.a, when, summary].filter(Boolean).join(" · ");
}

class BlameWidget extends WidgetType {
  constructor(readonly text: string) {
    super();
  }
  eq(other: BlameWidget) {
    return other.text === this.text;
  }
  toDOM() {
    const span = document.createElement("span");
    span.className = "cm-blame-annotation";
    span.textContent = this.text;
    return span;
  }
  ignoreEvent() {
    return true;
  }
}

function buildBlameDecorations(state: EditorState): DecorationSet {
  const blame = state.field(blameDataField, false);
  if (!blame || blame.length === 0) return Decoration.none;
  const head = state.selection.main.head;
  const line = state.doc.lineAt(head);
  const entry = blame[line.number - 1];
  if (!entry) return Decoration.none;
  const text = blameText(entry);
  if (!text) return Decoration.none;
  const deco = Decoration.widget({
    widget: new BlameWidget(text),
    side: 1,
  });
  return Decoration.set([deco.range(line.to)]);
}

const blameDecorationField = StateField.define<DecorationSet>({
  create: buildBlameDecorations,
  update(deco, tr) {
    const blameChanged = tr.effects.some((e) => e.is(setBlameEffect));
    if (tr.docChanged || tr.selection || blameChanged) {
      return buildBlameDecorations(tr.state);
    }
    return deco.map(tr.changes);
  },
  provide: (f) => EditorView.decorations.from(f),
});

const blameTheme = EditorView.baseTheme({
  ".cm-blame-annotation": {
    paddingLeft: "2.5em",
    opacity: "0.5",
    fontStyle: "italic",
    userSelect: "none",
    pointerEvents: "none",
    whiteSpace: "pre",
  },
});

function blameExtension(): Extension {
  return [blameDataField, blameDecorationField, blameTheme];
}

function baseExtensions(): Extension[] {
  return [
    lineNumbers(),
    highlightActiveLine(),
    highlightActiveLineGutter(),
    drawSelection(),
    EditorState.allowMultipleSelections.of(true),
    history(),
    search({ top: true, createPanel: createSearchPanel }),
    searchPanelTheme(),
    // Save chord is intercepted on the Swift side so it can honor the user's
    // KeyboardShortcutSettings.saveFilePreview binding (which may be a chord
    // like ⌘K ⌘S). The bridge still exposes a `requestSave` action for any
    // future JS-triggered save flows (e.g. an in-editor "Save" button).
    keymap.of([...defaultKeymap, ...historyKeymap, ...searchKeymap]),
    fontSizeCompartment.of(EditorView.theme({ "&": { fontSize: "13px" } })),
    themeCompartment.of([]),
    languageCompartment.of([]),
    readOnlyCompartment.of(EditorState.readOnly.of(false)),
    contentChangeListener,
  ];
}

let editor: EditorView | null = null;
let mergeView: MergeView | null = null;
let lastBlame: BlameLine[] | null = null;

function teardown() {
  if (mergeView) {
    mergeView.destroy();
    mergeView = null;
  }
  if (editor) {
    editor.destroy();
    editor = null;
  }
}

function mountSingle(parent: HTMLElement, content: string) {
  teardown();
  editor = new EditorView({
    parent,
    state: EditorState.create({
      doc: content,
      extensions: [...baseExtensions(), blameExtension()],
    }),
  });
  // Re-apply any blame captured before this (re)mount so an editor recreated by
  // a payload change keeps its annotation.
  if (lastBlame) {
    editor.dispatch({ effects: setBlameEffect.of(lastBlame) });
  }
}

function mountDiff(parent: HTMLElement, original: string, modified: string) {
  teardown();
  mergeView = new MergeView({
    parent,
    a: { doc: original, extensions: baseExtensions() },
    b: { doc: modified, extensions: baseExtensions() },
    revertControls: "b-to-a",
    highlightChanges: true,
    gutter: true,
    diffConfig: { scanLimit: 1000 },
  });
}

function applyLanguage(id: string | undefined) {
  const ext = languageExtension(id);
  const effects = languageCompartment.reconfigure(ext);
  editor?.dispatch({ effects });
  mergeView?.a.dispatch({ effects });
  mergeView?.b.dispatch({ effects });
}

// CodeMirror parses syntax lazily around the viewport with a time budget, so
// scrolling faster than the parser advances briefly shows unhighlighted text.
// After a document is mounted we walk its whole length in idle slices, forcing
// the syntax tree ahead of the user so any scroll target is already highlighted.
const BG_PARSE_BUDGET_MS = 60;
// Skip the eager full-document walk above this size. CodeMirror still parses
// lazily around the viewport; we only drop the background pre-parse, whose
// cumulative cost on large (usually generated/minified) files is not worth it.
const MAX_EAGER_PARSE_BYTES = 1024 * 1024;
let bgParseGeneration = 0;

function backgroundParse(view: EditorView, generation: number) {
  if (view.state.doc.length > MAX_EAGER_PARSE_BYTES) return;
  const idle: (cb: () => void) => void =
    typeof window.requestIdleCallback === "function"
      ? (cb) => window.requestIdleCallback(cb)
      : (cb) => window.setTimeout(cb, 16);
  const step = () => {
    // A newer mount (or language change) supersedes this pass.
    if (generation !== bgParseGeneration || !view.dom.isConnected) return;
    const done = forceParsing(view, view.state.doc.length, BG_PARSE_BUDGET_MS);
    if (!done) idle(step);
  };
  idle(step);
}

function kickBackgroundParse() {
  const generation = ++bgParseGeneration;
  if (editor) backgroundParse(editor, generation);
  if (mergeView) {
    backgroundParse(mergeView.a, generation);
    backgroundParse(mergeView.b, generation);
  }
}

function paletteTheme(palette: ThemePalette): Extension {
  return EditorView.theme(
    {
      "&": {
        color: palette.foreground,
        backgroundColor: palette.background,
      },
      ".cm-content": { caretColor: palette.foreground },
      ".cm-gutters": {
        backgroundColor: palette.gutterBackground,
        color: palette.gutterForeground,
        border: "none",
      },
      ".cm-activeLine": { backgroundColor: palette.activeLineBackground },
      ".cm-activeLineGutter": { backgroundColor: palette.activeLineBackground },
      "&.cm-focused .cm-selectionBackground, ::selection": {
        backgroundColor: palette.selectionBackground,
      },
    },
    { dark: false }
  );
}

// Drive the find widget's colors. The widget styling in `searchPanelTheme`
// is static, so theme changes flow through CSS variables set here instead
// of reconfiguring a compartment.
function setPanelVars(isDark: boolean, palette?: ThemePalette) {
  const root = document.documentElement.style;
  root.setProperty("--cmux-panel-bg", palette?.background ?? (isDark ? "#252526" : "#ffffff"));
  root.setProperty("--cmux-panel-fg", palette?.foreground ?? (isDark ? "#cccccc" : "#1f1f1f"));
  root.setProperty(
    "--cmux-panel-border",
    isDark ? "rgba(255, 255, 255, 0.14)" : "rgba(0, 0, 0, 0.14)"
  );
  root.setProperty(
    "--cmux-panel-input-bg",
    isDark ? "rgba(255, 255, 255, 0.06)" : "rgba(0, 0, 0, 0.04)"
  );
  root.setProperty(
    "--cmux-panel-hover",
    isDark ? "rgba(255, 255, 255, 0.10)" : "rgba(0, 0, 0, 0.07)"
  );
  root.setProperty(
    "--cmux-panel-toggle-on-bg",
    isDark ? "rgba(10, 132, 255, 0.38)" : "rgba(10, 132, 255, 0.20)"
  );
  root.setProperty("--cmux-panel-accent", "#0a84ff");
}

function applyTheme(isDark: boolean, palette?: ThemePalette) {
  const base = isDark ? oneDark : [];
  const overlay = palette ? paletteTheme(palette) : [];
  const effects = themeCompartment.reconfigure([base, overlay]);
  editor?.dispatch({ effects });
  mergeView?.a.dispatch({ effects });
  mergeView?.b.dispatch({ effects });
  document.documentElement.style.colorScheme = isDark ? "dark" : "light";
  document.body.style.background = palette?.background ?? "transparent";
  setPanelVars(isDark, palette);
}

function applyReadOnly(readOnly: boolean) {
  const effects = readOnlyCompartment.reconfigure(EditorState.readOnly.of(readOnly));
  editor?.dispatch({ effects });
  // The original/HEAD side of a diff is never editable; only the working-tree
  // side (b) honors the panel's read-only flag.
  mergeView?.a.dispatch({
    effects: readOnlyCompartment.reconfigure(EditorState.readOnly.of(true)),
  });
  mergeView?.b.dispatch({ effects });
}

function applyFontSize(px: number) {
  const ext = EditorView.theme({ "&": { fontSize: `${px}px` } });
  const effects = fontSizeCompartment.reconfigure(ext);
  editor?.dispatch({ effects });
  mergeView?.a.dispatch({ effects });
  mergeView?.b.dispatch({ effects });
}

function ensureRoot(): HTMLElement {
  let root = document.getElementById("editor");
  if (!root) {
    root = document.createElement("div");
    root.id = "editor";
    document.body.appendChild(root);
  }
  return root;
}

declare global {
  interface Window {
    __cmuxCodeApply?: (payload: Payload | string) => void;
    __cmuxCodeGet?: () => string;
    __cmuxCodeSetFontSize?: (px: number) => void;
    __cmuxCodeSetBlame?: (blame: BlameLine[] | string | null) => void;
  }
}

window.__cmuxCodeApply = function (payload) {
  const root = ensureRoot();
  const p: Payload = typeof payload === "string" ? JSON.parse(payload) : payload;
  if (p.diffOriginal != null && p.diffModified != null) {
    mountDiff(root, p.diffOriginal, p.diffModified);
  } else {
    mountSingle(root, p.content ?? "");
  }
  applyLanguage(p.language);
  applyTheme(!!p.isDark, p.theme);
  applyFontSize(p.fontSize ?? 13);
  applyReadOnly(!!p.readOnly);
  kickBackgroundParse();
};

window.__cmuxCodeGet = function () {
  if (editor) return editor.state.doc.toString();
  if (mergeView) return mergeView.b.state.doc.toString();
  return "";
};

window.__cmuxCodeSetFontSize = function (px) {
  applyFontSize(px);
};

window.__cmuxCodeSetBlame = function (blame) {
  const parsed: BlameLine[] | null =
    typeof blame === "string" ? JSON.parse(blame) : blame;
  lastBlame = parsed;
  editor?.dispatch({ effects: setBlameEffect.of(parsed) });
};

document.documentElement.dataset.cmuxCodeViewerReady = "1";
postToSwift("ready");
