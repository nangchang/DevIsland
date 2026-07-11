#!/usr/bin/env python3
"""One-time migration: Localizable.swift (s("EN","KO")) -> String Catalog.

Facade-preserving: keeps the typed L10n properties/funcs, swaps the
s("EN","KO") bodies for t("key") / tf("key", args...) that read the compiled
Localizable.xcstrings via a per-lproj Bundle lookup (preserves live switching).
Emits DevIsland/Localizable.xcstrings, rewrites DevIsland/Utility/Localizable.swift,
and writes DevIslandTests/LocalizableCatalogGoldenTests.swift.

This is a ONE-SHOT tool: it only understands the pre-migration s("EN","KO")
source. It is committed for provenance and to document the transformation
(format-specifier + positional + %% derivation); it is not part of the build.
To re-run against the original, check out the pre-migration Localizable.swift
first (e.g. `git show <pre-migration-ref>:DevIsland/Utility/Localizable.swift`).
"""
import json, re, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "DevIsland/Utility/Localizable.swift")
XCSTRINGS = os.path.join(ROOT, "DevIsland/Localizable.xcstrings")
GOLDEN = os.path.join(ROOT, "DevIslandTests/LocalizableCatalogGoldenTests.swift")

lines = open(SRC, encoding="utf-8").read().split("\n")

if 't("' in "\n".join(lines) and 's("' not in "\n".join(lines):
    raise SystemExit(
        "Localizable.swift is already migrated (uses t()/tf()). This tool only "
        "runs against the pre-migration s(\"EN\",\"KO\") source. See the module "
        "docstring for how to re-run against the original.")

# ---- locate the `extension L10n {` block (String constants) ----
ext_start = next(i for i, l in enumerate(lines) if l.strip() == "extension L10n {")
# find matching close brace by counting (skip strings)
def brace_delta(s):
    d = 0; i = 0; n = len(s)
    while i < n:
        c = s[i]
        if c == '"':
            i = skip_string(s, i)
            continue
        if c == '{': d += 1
        elif c == '}': d -= 1
        i += 1
    return d

def skip_string(s, i):
    # s[i] == '"'; return index after closing quote, honoring \(...) and escapes
    assert s[i] == '"'
    i += 1
    while i < len(s):
        c = s[i]
        if c == '\\':
            if i + 1 < len(s) and s[i+1] == '(':
                i = skip_interp(s, i+2)
                continue
            i += 2
            continue
        if c == '"':
            return i + 1
        i += 1
    return i

def skip_interp(s, i):
    # s[i] is first char after '\('; return index after matching ')'
    depth = 1
    while i < len(s):
        c = s[i]
        if c == '"':
            i = skip_string(s, i); continue
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return i

depth = 0
ext_end = None
for i in range(ext_start, len(lines)):
    depth += brace_delta(lines[i])
    if depth == 0 and i > ext_start:
        ext_end = i
        break
assert ext_end is not None, "no matching close for extension"

header = lines[:ext_start + 1]
body_src = lines[ext_start + 1:ext_end]

# ---- scan one Swift string literal, return (raw_inner, index_after) ----
def read_string(s, i):
    assert s[i] == '"'
    i += 1; start = i
    parts = []
    while i < len(s):
        c = s[i]
        if c == '\\':
            if s[i+1] == '(':
                j = skip_interp(s, i+2)
                parts.append(s[i:j]); i = j; continue
            parts.append(s[i:i+2]); i += 2; continue
        if c == '"':
            return "".join(parts), i + 1
        parts.append(c); i += 1
    raise ValueError("unterminated string")

def find_s_calls(text):
    """Return list of (raw_en, raw_ko) for each s(...)/self.s(...) call at top level."""
    calls = []
    i = 0; n = len(text)
    while i < n:
        c = text[i]
        if c == '"':
            i = skip_string(text, i); continue
        # match `s(` where preceding char is not identifier char
        if c == 's' and i + 1 < n and text[i+1] == '(':
            prev = text[i-1] if i > 0 else ' '
            if not (prev.isalnum() or prev == '_'):
                # parse two string args
                j = i + 2
                while text[j] != '"':
                    j += 1
                en, j = read_string(text, j)
                while text[j] != '"':
                    j += 1
                ko, j = read_string(text, j)
                calls.append((en, ko)); i = j; continue
        i += 1
    return calls

# ---- interpolation-aware conversion ----
TYPE_TAIL = {"String": "@", "Int": "lld", "Int32": "d", "Double": "f"}

def parse_params(params_str):
    """'(_ id: String, _ count: Int)' -> [(name, type)] in order."""
    inner = params_str.strip()[1:-1].strip()
    if not inner:
        return []
    out = []
    for part in split_top_commas(inner):
        m = re.match(r'(?:\w+\s+)?(\w+)\s*:\s*(\S+)', part.strip())
        out.append((m.group(1), m.group(2)))
    return out

def split_top_commas(s):
    res = []; depth = 0; cur = ""; i = 0
    while i < len(s):
        c = s[i]
        if c == '"':
            j = skip_string(s, i); cur += s[i:j]; i = j; continue
        if c in "([<": depth += 1
        elif c in ")]>": depth -= 1
        if c == ',' and depth == 0:
            res.append(cur); cur = ""; i += 1; continue
        cur += c; i += 1
    if cur.strip():
        res.append(cur)
    return res

def iter_raw(raw):
    """Yield ('lit', text) or ('interp', expr) tokens over a raw string literal."""
    i = 0; n = len(raw)
    while i < n:
        c = raw[i]
        if c == '\\' and i + 1 < n and raw[i+1] == '(':
            j = skip_interp(raw, i+2)
            yield ('interp', raw[i+2:j-1]); i = j; continue
        if c == '\\':
            e = raw[i+1]
            yield ('esc', e); i += 2; continue
        yield ('char', c); i += 1

NESTED_FMT = re.compile(r'String\(format:\s*"([^"]*)",\s*(\w+)\)')

def convert_to_catalog(raw, pmap, will_format):
    multi = len(pmap) > 1
    out = []
    for kind, val in iter_raw(raw):
        if kind == 'char':
            out.append('%%' if (will_format and val == '%') else val)
        elif kind == 'esc':
            out.append({'n': '\n', '"': '"', '\\': '\\', 't': '\t'}.get(val, val))
        else:  # interp
            expr = val.strip()
            m = NESTED_FMT.match(expr)
            if m:
                out.append(m.group(1))  # e.g. %.2f  (single-arg only)
            else:
                pos, typ = pmap[expr]
                tail = TYPE_TAIL[typ]
                out.append(f'%{pos}${tail}' if multi else f'%{tail}')
    return "".join(out)

def convert_to_display(raw, dummy):
    """Compute the final rendered string for golden expectations."""
    out = []
    for kind, val in iter_raw(raw):
        if kind == 'char':
            out.append(val)
        elif kind == 'esc':
            out.append({'n': '\n', '"': '"', '\\': '\\', 't': '\t'}.get(val, val))
        else:
            expr = val.strip()
            m = NESTED_FMT.match(expr)
            if m:
                fmt, name = m.group(1), m.group(2)
                out.append(fmt % dummy[name][0])
            else:
                out.append(str(dummy[expr][0]))
    return "".join(out)

# ---- process declarations ----
catalog = {}          # key -> {"en":.., "ko":..}
new_body = []         # rewritten extension body lines
golden = []           # (call_expr, expected_en, expected_ko, name)

MANUAL = {"notifTaskCompleteBody"}

def swift_lit(pyval, typ):
    if typ in ("Int", "Int32", "Double"):
        return str(pyval)
    return '"' + pyval.replace("\\", "\\\\").replace('"', '\\"') + '"'

i = 0
while i < len(body_src):
    line = body_src[i]
    st = line.strip()
    if st == "" or st.startswith("//"):
        new_body.append(line); i += 1; continue
    # accumulate a full declaration
    decl = line; j = i
    while brace_delta_multi := True:
        # balanced when total brace delta over accumulated == 0 and has a '{'
        acc = "\n".join(body_src[i:j+1])
        d = 0; ok = False; k = 0
        while k < len(acc):
            c = acc[k]
            if c == '"':
                k = skip_string(acc, k); continue
            if c == '{': d += 1; ok = True
            elif c == '}': d -= 1
            k += 1
        if ok and d == 0:
            break
        j += 1
    text = "\n".join(body_src[i:j+1])
    i = j + 1

    m = re.match(r'^(\s*)(var|func)\s+(\w+)(\([^)]*\))?', text)
    indent, kind, name, params_str = m.group(1), m.group(2), m.group(3), m.group(4) or ""
    params = parse_params(params_str) if kind == "func" else []
    pmap = {nm: (idx + 1, ty) for idx, (nm, ty) in enumerate(params)}

    calls = find_s_calls(text)

    if name in MANUAL:
        # handled after loop; keep placeholder position
        new_body.append(("__MANUAL__", name, indent))
        # still need catalog entries via bespoke handling below
        continue

    assert len(calls) == 1, f"{name}: expected 1 s() call, got {len(calls)}"
    en_raw, ko_raw = calls[0]

    # determine exprs present
    has_interp = any(k == 'interp' for k, _ in iter_raw(en_raw)) or \
                 any(k == 'interp' for k, _ in iter_raw(ko_raw))
    will_format = has_interp

    catalog[name] = {
        "en": convert_to_catalog(en_raw, pmap, will_format),
        "ko": convert_to_catalog(ko_raw, pmap, will_format),
    }

    # build new body
    if kind == "var":
        new_body.append(f'{indent}var {name}: String {{ t("{name}") }}')
    else:
        sig = f'{indent}func {name}{params_str} -> String'
        if not has_interp:
            new_body.append(f'{sig} {{ t("{name}") }}')
        else:
            arglist = ", ".join(nm for nm, _ in params)
            new_body.append(f'{sig} {{ tf("{name}", {arglist}) }}')

    # golden expectations
    dummy = {}
    icount = 0
    for nm, ty in params:
        if ty == "String":
            dummy[nm] = (nm, ty)
        elif ty in ("Int", "Int32"):
            dummy[nm] = (7 + icount, ty); icount += 1
        elif ty == "Double":
            dummy[nm] = (1.25, ty)
    exp_en = convert_to_display(en_raw, dummy)
    exp_ko = convert_to_display(ko_raw, dummy)
    if kind == "var":
        call = f"l10n.{name}"
    elif not params:
        call = f"l10n.{name}()"
    else:
        call = f"l10n.{name}(" + ", ".join(swift_lit(dummy[nm][0], ty) for nm, ty in params) + ")"
    golden.append((call, exp_en, exp_ko, name))

# ---- bespoke: notifTaskCompleteBody ----
# original:
#   title.isEmpty ? s("Agent finished.","에이전트가 작업을 완료했습니다.")
#                 : s("\(title) complete","\(title) 완료")
catalog["notifTaskCompleteBodyEmpty"] = {"en": "Agent finished.", "ko": "에이전트가 작업을 완료했습니다."}
catalog["notifTaskCompleteBody"] = {"en": "%@ complete", "ko": "%@ 완료"}
MANUAL_BODY = {
    "notifTaskCompleteBody":
        'func notifTaskCompleteBody(_ title: String) -> String {\n'
        '        title.isEmpty ? t("notifTaskCompleteBodyEmpty") : tf("notifTaskCompleteBody", title)\n'
        '    }'
}
# golden for both branches
golden.append(('l10n.notifTaskCompleteBody("")', "Agent finished.", "에이전트가 작업을 완료했습니다.", "notifTaskCompleteBody(empty)"))
golden.append(('l10n.notifTaskCompleteBody("Build")', "Build complete", "Build 완료", "notifTaskCompleteBody(nonempty)"))

# ---- emit rewritten Localizable.swift ----
out_lines = list(header)
for entry in new_body:
    if isinstance(entry, tuple) and entry[0] == "__MANUAL__":
        _, nm, indent = entry
        out_lines.append(indent + MANUAL_BODY[nm])
    else:
        out_lines.append(entry)
out_lines.append("}")
open(SRC, "w", encoding="utf-8").write("\n".join(out_lines) + "\n")

# ---- emit xcstrings ----
strings_obj = {}
for key in sorted(catalog):
    strings_obj[key] = {
        "localizations": {
            "en": {"stringUnit": {"state": "translated", "value": catalog[key]["en"]}},
            "ko": {"stringUnit": {"state": "translated", "value": catalog[key]["ko"]}},
        }
    }
xc = {"sourceLanguage": "en", "strings": strings_obj, "version": "1.0"}
with open(XCSTRINGS, "w", encoding="utf-8") as f:
    json.dump(xc, f, ensure_ascii=False, indent=2)
    f.write("\n")

# ---- emit golden test ----
def sesc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")

gl = []
gl.append("import XCTest")
gl.append("@testable import DevIsland")
gl.append("")
gl.append("/// GENERATED by scripts/gen_l10n (do not edit by hand).")
gl.append("/// Verifies every L10n facade property/func resolves through the compiled")
gl.append("/// String Catalog to exactly the pre-migration en/ko text (byte-identical).")
gl.append("final class LocalizableCatalogGoldenTests: XCTestCase {")
gl.append("    private let l10n = L10n.shared")
gl.append("")
gl.append("    override func tearDown() {")
gl.append("        l10n.language = .system")
gl.append("        super.tearDown()")
gl.append("    }")
gl.append("")
gl.append("    func testEnglishCatalogMatchesLegacy() {")
gl.append("        l10n.language = .english")
for call, en, ko, nm in golden:
    gl.append(f'        XCTAssertEqual({call}, "{sesc(en)}", "{sesc(nm)}")')
gl.append("    }")
gl.append("")
gl.append("    func testKoreanCatalogMatchesLegacy() {")
gl.append("        l10n.language = .korean")
for call, en, ko, nm in golden:
    gl.append(f'        XCTAssertEqual({call}, "{sesc(ko)}", "{sesc(nm)}")')
gl.append("    }")
gl.append("}")
open(GOLDEN, "w", encoding="utf-8").write("\n".join(gl) + "\n")

print(f"entries in catalog: {len(catalog)}")
print(f"golden assertions:  {len(golden)} x2 langs")
print(f"manual entries:     {sorted(MANUAL)}")
