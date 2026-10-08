#!/usr/bin/env bash
# Tests for grafana/generator: the generated files are current, the dashboards
# are well-formed, and panels and alert rules share their thresholds.
source "$(dirname "$0")/lib.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
GEN="$ROOT/grafana/generator"
DASH="grafana/dashboards/PLG Stack"
RULES="grafana/provisioning/alerting/rules.yaml"

generate() { python3 "$GEN/generate.py" "$@" >/dev/null; }

assert_ok "committed dashboards and alert rules match the generator" python3 "$GEN/generate.py" --check

for lang in id en; do
	assert_ok "language $lang renders" generate --out "$TMP/$lang" --language "$lang"
done
assert_fails "English titles differ from Indonesian ones" cmp -s "$TMP/id/$DASH/fleet-overview.json" "$TMP/en/$DASH/fleet-overview.json"

# --- structure ------------------------------------------------------------------

problems="$(python3 - "$GEN" "$TMP/id/$DASH" "$TMP/en/$DASH" 2>&1 <<'EOF' || echo "checker failed"
import json, re, sys, tomllib
from pathlib import Path

gen, *dirs = sys.argv[1:]
problems = []
catalogs = {lang: tomllib.loads((Path(gen) / "lang" / f"{lang}.toml").read_text()) for lang in ("id", "en")}

def flat(table, prefix=""):
    out = {}
    for k, v in table.items():
        out.update(flat(v, f"{prefix}{k}.") if isinstance(v, dict) else {f"{prefix}{k}": v})
    return out

id_text, en_text = flat(catalogs["id"]), flat(catalogs["en"])
if set(id_text) != set(en_text):
    problems.append(f"catalog keys differ: {sorted(set(id_text) ^ set(en_text))}")
placeholder = re.compile(r"(?<!\{)\{([a-z_]+)\}(?!\})")
for key in set(id_text) & set(en_text):
    texts = id_text[key], en_text[key]
    if all(isinstance(t, str) for t in texts) and len({frozenset(placeholder.findall(t)) for t in texts}) > 1:
        problems.append(f"{key}: placeholders differ between id and en")

config = tomllib.loads((Path(gen) / "config.toml").read_text())
seconds = {"s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800}
def value(v):
    return int(v[:-1]) * seconds[v[-1]] if isinstance(v, str) else v
pairs = {(value(t["warning"]), value(t["critical"])) for t in config["thresholds"].values()}
pairs |= {(value(t["critical"]), value(t["warning"])) for t in config["thresholds"].values()}

for folder in dirs:
    boards = {json.loads(p.read_text())["uid"]: json.loads(p.read_text()) for p in Path(folder).glob("*.json")}
    variables = {uid: {v["name"] for v in d["templating"]["list"]} for uid, d in boards.items()}
    for uid, d in boards.items():
        ids = [p["id"] for p in d["panels"]]
        if len(ids) != len(set(ids)):
            problems.append(f"{uid}: duplicate panel ids")
        cells = set()
        for p in d["panels"]:
            g = p["gridPos"]
            if g["x"] + g["w"] > 24:
                problems.append(f"{uid}: panel {p['title']!r} is wider than the grid")
            for x in range(g["x"], g["x"] + g["w"]):
                for y in range(g["y"], g["y"] + g["h"]):
                    if (x, y) in cells:
                        problems.append(f"{uid}: panel {p['title']!r} overlaps another panel")
                        break
                    cells.add((x, y))
                else:
                    continue
                break
            text = json.dumps(p)
            for name in re.findall(r"\$\{?([A-Za-z_]\w*)", text):
                if not name.startswith("__") and name not in variables[uid]:
                    problems.append(f"{uid}: panel {p['title']!r} uses undefined variable ${name}")
            for ds in re.findall(r'"uid": "([^"]+)"', json.dumps(p.get("datasource", {})) + json.dumps(p.get("targets", []))):
                if ds not in ("prometheus", "loki"):
                    problems.append(f"{uid}: panel {p['title']!r} uses unknown datasource {ds}")
            for th in re.findall(r'"steps": (\[[^\]]*\])', text):
                steps = json.loads(th)
                levels = [s["value"] for s in steps if s["value"] is not None]
                colors = {s["color"] for s in steps}
                if len(levels) == 2 and {"orange", "red"} <= colors and tuple(levels) not in pairs:
                    problems.append(f"{uid}: panel {p['title']!r} has thresholds {levels} that are not in config.toml")
        for url in re.findall(r'"url": "([^"]+)"', json.dumps(d)):
            match = re.match(r"/d/([^/?]+)/[^?]*\??(.*)", url)
            if not match:
                continue
            target, query = match.groups()
            if target not in boards:
                problems.append(f"{uid}: link to unknown dashboard {target}")
                continue
            for name in re.findall(r"var-(\w+)=", query):
                if name not in variables[target]:
                    problems.append(f"{uid}: link sets var-{name}, which {target} does not have")
print("\n".join(dict.fromkeys(problems)))
EOF
)"
assert_eq "" "$problems" "dashboards are well-formed and use config thresholds"

# --- one config for panels and alerts ---------------------------------------------

sed -e 's/^cpu = { warning = 90, critical = 95 }/cpu = { warning = 70, critical = 80 }/' \
	-e 's/^silent_after = "3m"/silent_after = "7m"/' "$GEN/config.toml" >"$TMP/config.toml"
assert_ok "a changed config renders" generate --config "$TMP/config.toml" --out "$TMP/changed"
cpu_rule="$(sed -n '/uid: cpu-high/,/for:/p' "$TMP/changed/$RULES")"
assert_contains "$cpu_rule" "params: [70]" "the CPU alert follows thresholds.cpu.warning"
assert_contains "$(cat "$TMP/changed/$DASH/host-detail.json")" '"value": 70' "the CPU panel follows the same threshold"
assert_contains "$(cat "$TMP/changed/$RULES")" "[7m]" "the not-reporting alert follows reporting.silent_after"
assert_contains "$(cat "$TMP/changed/$DASH/fleet-overview.json")" "[7m]" "Fleet Overview uses the same silence window"

sed 's/^memory = { warning = 90, critical = 95 }/memory = { warning = 95, critical = 90 }/' "$GEN/config.toml" >"$TMP/bad-order.toml"
assert_fails "warning above critical is rejected" generate --config "$TMP/bad-order.toml" --out "$TMP/bad" 2>/dev/null
printf '\n"no.such.key" = "x"\n' | cat "$GEN/config.toml" - >"$TMP/bad-text.toml"
assert_fails "overriding unknown text is rejected" generate --config "$TMP/bad-text.toml" --out "$TMP/bad" 2>/dev/null
printf '\n"fleet.title" = "Semua Server"\n' | cat "$GEN/config.toml" - >"$TMP/text.toml"
generate --config "$TMP/text.toml" --out "$TMP/text"
assert_contains "$(cat "$TMP/text/$DASH/fleet-overview.json")" '"title": "Semua Server"' "text overrides replace catalog text"

mkdir -p "$TMP/foreign/$DASH"
generate --out "$TMP/foreign"
echo '{}' >"$TMP/foreign/$DASH/custom.json"
assert_fails "files the generator does not own are reported" \
	python3 "$GEN/generate.py" --check --out "$TMP/foreign" 2>/dev/null

# --- YAML writer -------------------------------------------------------------------

yaml() {
	python3 -c 'import json, sys; sys.path.insert(0, sys.argv[1]); from builders import to_yaml; print(to_yaml(json.loads(sys.argv[2])), end="")' \
		"$GEN" "$1"
}
assert_eq 'a: plain text (ok)' "$(yaml '{"a": "plain text (ok)"}')" "plain strings stay unquoted"
assert_eq 'a: "yes"' "$(yaml '{"a": "yes"}')" "boolean-like strings are quoted"
assert_eq 'a: "10"' "$(yaml '{"a": "10"}')" "number-like strings are quoted"
assert_eq 'a: 5m' "$(yaml '{"a": "5m"}')" "durations stay unquoted"
assert_eq 'a: "x: y"' "$(yaml '{"a": "x: y"}')" "colons are quoted"
assert_eq 'a: "#x"' "$(yaml '{"a": "#x"}')" "leading indicators are quoted"
assert_eq 'a: "say \"hi\" # now"' "$(yaml '{"a": "say \"hi\" # now"}')" "comments markers are quoted"
assert_eq $'a: |\n  one\n  two' "$(yaml '{"a": "one\ntwo\n"}')" "multi-line strings become literal blocks"
assert_eq 'a: { b: 1, c: [x, "1"] }' "$(yaml '{"a": {"b": 1, "c": ["x", "1"]}}')" "small maps stay on one line"
assert_eq $'- b: 1\n  c: 2' "$(yaml '[{"b": 1, "c": 2}]')" "list items keep their first key on the dash line"

finish
