"""Grafana panel and dashboard JSON builders, plus a small YAML writer."""
import json
import re

PROM = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}
TAG = "plg-stack"

OK_ONLY = {"mode": "absolute", "steps": [{"color": "green", "value": None}]}
BAD_IF_ANY = {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "red", "value": 1}]}


def one_step(color, value):
    return {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": color, "value": value}]}


def value_mapping(*entries):
    """entries: (value, text, color) tuples."""
    options = {str(value): {"text": text, "color": color, "index": i} for i, (value, text, color) in enumerate(entries)}
    return [{"type": "value", "options": options}]


class Layout:
    """Places panels left to right on Grafana's 24-column grid."""

    def __init__(self):
        self.y = 0
        self.x = 0
        self.row_h = 0
        self.panels = []

    def add(self, panel, w, h):
        if self.x + w > 24:
            self.y += self.row_h
            self.x = 0
            self.row_h = 0
        panel["id"] = len(self.panels) + 1
        panel["gridPos"] = {"x": self.x, "y": self.y, "w": w, "h": h}
        self.x += w
        self.row_h = max(self.row_h, h)
        self.panels.append(panel)

    def row(self, title):
        if self.x:
            self.y += self.row_h
        self.x = 0
        self.row_h = 0
        self.panels.append({"type": "row", "title": title, "collapsed": False, "panels": [],
                            "id": len(self.panels) + 1, "gridPos": {"x": 0, "y": self.y, "w": 24, "h": 1}})
        self.y += 1


def target(expr, legend="", ref="A", instant=False, table=False, ds=PROM):
    t = {"refId": ref, "datasource": ds, "expr": expr}
    if ds is PROM:
        t["legendFormat"] = legend or "__auto"
        t["range"] = not instant
        t["instant"] = instant
        if table:
            t["format"] = "table"
    else:
        t["queryType"] = "instant" if instant else "range"
        if legend:
            t["legendFormat"] = legend
    return t


def data_link(title, uid, params):
    """params: (variable, value) pairs; values may hold Grafana link variables."""
    query = "".join(f"var-{name}={value}&" for name, value in params)
    return {"title": title, "url": f"/d/{uid}/{uid}?{query}${{__url_time_range}}"}


def field(name):
    """Value of another column on the same table row."""
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", name):
        raise ValueError(f"column {name!r} is used in a link, so it must be a single word")
    return "${__data.fields.%s}" % name


def timeseries(title, targets, unit="short", stack=False, minv=None, maxv=None, desc="", ds=PROM,
               thresholds=None, links=None, bars=False):
    custom = {"fillOpacity": 15 if stack else 8, "lineWidth": 1, "showPoints": "never",
              "stacking": {"mode": "normal" if stack else "none", "group": "A"}}
    if bars:
        custom.update({"drawStyle": "bars", "fillOpacity": 80, "barAlignment": 0})
    defaults = {"unit": unit, "custom": custom}
    if minv is not None:
        defaults["min"] = minv
    if maxv is not None:
        defaults["max"] = maxv
    if thresholds:
        defaults["thresholds"] = thresholds
        custom["thresholdsStyle"] = {"mode": "dashed"}
    if links:
        defaults["links"] = links
    return {"type": "timeseries", "title": title, "description": desc, "datasource": ds, "targets": targets,
            "fieldConfig": {"defaults": defaults, "overrides": []},
            "options": {"legend": {"displayMode": "table", "placement": "right", "showLegend": True,
                                   "calcs": ["lastNotNull", "max"]},
                        "tooltip": {"mode": "multi", "sort": "desc"}}}


def stat(title, expr, unit="short", thresholds=OK_ONLY, desc="", mappings=None, color_mode="value", legend="",
         ds=PROM, no_value=None, decimals=None):
    defaults = {"unit": unit, "thresholds": thresholds, "mappings": mappings or [], "color": {"mode": "thresholds"}}
    if no_value is not None:
        defaults["noValue"] = no_value
    if decimals is not None:
        defaults["decimals"] = decimals
    return {"type": "stat", "title": title, "description": desc, "datasource": ds,
            "targets": [target(expr, legend, instant=True, ds=ds)],
            "fieldConfig": {"defaults": defaults, "overrides": []},
            "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                        "colorMode": color_mode, "graphMode": "none", "textMode": "auto", "justifyMode": "center"}}


def bargauge(title, expr, legend, unit="short", desc="", ds=PROM, thresholds=None, maxv=None, join=False):
    """Without thresholds the bars use a continuous palette scaled to the largest value.

    join: merges the instant series of a Prometheus query into one frame,
    which keeps each bar labelled with its series name.
    """
    defaults = {"unit": unit, "min": 0}
    if maxv is not None:
        defaults["max"] = maxv
    if thresholds:
        defaults.update({"thresholds": thresholds, "color": {"mode": "thresholds"}})
    else:
        defaults.update({"thresholds": OK_ONLY, "color": {"mode": "continuous-BlYlRd"}})
    # Instant Loki queries come back as a table, one row per series.
    reduce = ({"values": True, "calcs": [], "fields": "/^Value/"} if ds is LOKI
              else {"calcs": ["lastNotNull"], "fields": "", "values": False})
    panel = {"type": "bargauge", "title": title, "description": desc, "datasource": ds,
             "targets": [target(expr, legend, instant=True, ds=ds)],
             "fieldConfig": {"defaults": defaults, "overrides": []},
             "options": {"displayMode": "gradient", "orientation": "horizontal", "showUnfilled": True,
                         "reduceOptions": reduce}}
    if join:
        panel["transformations"] = [{"id": "joinByField", "options": {"mode": "outer"}}]
    return panel


def logs(title, expr, desc=""):
    return {"type": "logs", "title": title, "description": desc, "datasource": LOKI,
            "targets": [target(expr, ds=LOKI)],
            "options": {"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending",
                        "enableLogDetails": True, "dedupStrategy": "none", "prettifyLogMessage": False,
                        "showLabels": False, "showCommonLabels": False}}


def table(title, queries, columns, overrides=(), desc="", sort_by=None, sort_desc=True):
    """queries: (ref, expr) pairs. columns: ordered {source field: display name}."""
    index = {}
    rename = {}
    for i, (src, dst) in enumerate(columns.items()):
        index[src] = i
        if dst != src:
            rename[src] = dst
    panel = {"type": "table", "title": title, "description": desc, "datasource": PROM,
             "targets": [target(expr, ref=ref, instant=True, table=True) for ref, expr in queries],
             "transformations": [
                 {"id": "merge", "options": {}},
                 {"id": "organize", "options": {"excludeByName": {"Time": True}, "indexByName": index,
                                                "renameByName": rename}},
                 {"id": "filterFieldsByName", "options": {"include": {"names": list(columns.values())}}},
             ],
             "fieldConfig": {"defaults": {"custom": {"align": "auto", "cellOptions": {"type": "auto"}},
                                          "thresholds": OK_ONLY}, "overrides": list(overrides)},
             "options": {"showHeader": True, "cellHeight": "sm",
                         "footer": {"show": False, "reducer": ["sum"], "fields": ""}}}
    if sort_by:
        panel["options"]["sortBy"] = [{"displayName": sort_by, "desc": sort_desc}]
    return panel


def state_timeline(title, expr, legend, mappings, desc="", interval=None):
    """States come from the value mappings; a thresholds color mode would
    override them and merge every value into one state."""
    panel = {"type": "state-timeline", "title": title, "description": desc, "datasource": PROM,
            "targets": [target(expr, legend)],
            "fieldConfig": {"defaults": {"mappings": mappings, "color": {"mode": "fixed", "fixedColor": "green"},
                                         "custom": {"lineWidth": 0, "fillOpacity": 80}},
                            "overrides": []},
            "options": {"mergeValues": True, "showValue": "never", "alignValue": "left", "rowHeight": 0.8,
                        "legend": {"showLegend": True, "displayMode": "list", "placement": "bottom"},
                        "tooltip": {"mode": "single", "sort": "none"}}}
    if interval:
        panel["interval"] = interval
    return panel


def column(name, *props):
    return {"matcher": {"id": "byName", "options": name}, "properties": list(props)}


def unit(u):
    return {"id": "unit", "value": u}


def decimals(n):
    return {"id": "decimals", "value": n}


def links(*items):
    return {"id": "links", "value": list(items)}


def colored(thresholds, mode="color-background"):
    cell = {"type": mode}
    if mode == "color-background":
        cell["mode"] = "gradient"
    return [{"id": "thresholds", "value": thresholds}, {"id": "custom.cellOptions", "value": cell}]


def query_var(name, label, query, ds=PROM, multi=True, all_value=".+", include_all=True):
    return {"type": "query", "name": name, "label": label, "datasource": ds, "query": query,
            "definition": query, "refresh": 2, "sort": 1, "multi": multi, "includeAll": include_all,
            "allValue": all_value if include_all else None,
            "current": {"selected": True, "text": ["All"], "value": ["$__all"]} if include_all else {},
            "options": []}


def custom_var(name, label, values, all_value=".+"):
    opts = [{"text": "All", "value": "$__all", "selected": True}] + [
        {"text": v, "value": v, "selected": False} for v in values]
    return {"type": "custom", "name": name, "label": label, "query": ",".join(values), "multi": True,
            "includeAll": True, "allValue": all_value,
            "current": {"selected": True, "text": ["All"], "value": ["$__all"]}, "options": opts}


def textbox(name, label):
    return {"type": "textbox", "name": name, "label": label, "query": "",
            "current": {"text": "", "value": ""}, "options": [{"selected": True, "text": "", "value": ""}]}


def dashboard_link(title, url, icon="dashboard", keep_time=True):
    return {"type": "link", "title": title, "url": url, "icon": icon, "tooltip": "", "asDropdown": False,
            "includeVars": False, "keepTime": keep_time, "targetBlank": False, "tags": []}


def dashboard(uid, title, description, variables, layout, time_from="now-6h", links=()):
    return {"uid": uid, "title": title, "description": description, "tags": [TAG],
            "timezone": "browser", "editable": True, "graphTooltip": 1, "schemaVersion": 39, "version": 1,
            "time": {"from": time_from, "to": "now"}, "refresh": "1m",
            "templating": {"list": variables}, "annotations": {"list": []},
            "links": [{"type": "dashboards", "tags": [TAG], "asDropdown": True, "title": "Dashboards",
                       "includeVars": False, "keepTime": True}, *links],
            "panels": layout.panels}


SIMPLE_KEY = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*")
# Strings YAML would read as something else when left unquoted.
NOT_PLAIN = re.compile(r"[-+]?[0-9._]+([eE][-+]?[0-9]+)?|0[xob][0-9a-fA-F_]+|[-+]?\.(inf|nan)|[0-9]{4}-.*|~"
                       r"|y|n|yes|no|on|off|true|false|null", re.IGNORECASE)
FLOW_WIDTH = 60


def to_yaml(value, indent=0):
    """Block-style YAML for dicts, lists and scalars.

    Strings are left unquoted where YAML reads them back unchanged, otherwise
    written as JSON strings (valid YAML double-quoted scalars); multi-line
    strings become literal blocks and small mappings of scalars stay on one
    line.
    """
    pad = " " * indent
    if isinstance(value, dict):
        out = []
        for key, item in value.items():
            entry = _yaml_entry(f"{pad}{_key(key)}:", item, indent)
            if indent == 0 and out and entry.count("\n") > 1:
                out.append("\n")
            out.append(entry)
        return "".join(out)
    if isinstance(value, list):
        out = []
        for item in value:
            if isinstance(item, dict) and item:
                body = to_yaml(item, indent + 2)
                if out and body.count("\n") > 8:
                    out.append("\n")
                out.append(f"{pad}- {body[indent + 2:]}")
            else:
                out.append(_yaml_entry(f"{pad}-", item, indent))
        return "".join(out)
    return f"{pad}{_scalar(value)}\n"


def _key(key):
    return key if SIMPLE_KEY.fullmatch(key) else json.dumps(key)


def _yaml_entry(head, item, indent):
    if isinstance(item, (dict, list)) and item:
        flow = _flow(item)
        if flow is not None:
            return f"{head} {flow}\n"
        return f"{head}\n{to_yaml(item, indent + 2)}"
    if isinstance(item, str) and "\n" in item.rstrip("\n") and not item.startswith(" "):
        body = "".join(f"{' ' * (indent + 2)}{line}\n" if line else "\n" for line in item.rstrip("\n").split("\n"))
        return f"{head} {'|' if item.endswith(chr(10)) else '|-'}\n{body}"
    return f"{head} {_scalar(item)}\n"


def _flow(value):
    """One-line form of a small mapping or list of scalars, or None."""
    if isinstance(value, dict):
        parts = []
        for key, item in value.items():
            inner = _flow(item) if isinstance(item, (dict, list)) else _scalar(item, flow=True)
            if inner is None:
                return None
            parts.append(f"{_key(key)}: {inner}")
        text = "{ " + ", ".join(parts) + " }"
    elif isinstance(value, list):
        if any(isinstance(item, (dict, list)) for item in value):
            return None
        text = "[" + ", ".join(_scalar(item, flow=True) for item in value) + "]"
    else:
        return None
    return text if len(text) <= FLOW_WIDTH else None


def _plain(text, flow):
    if flow:
        return bool(SIMPLE_KEY.fullmatch(text)) and not NOT_PLAIN.fullmatch(text)
    return (text != "" and text == text.strip() and text[0] not in "-?:,[]{}#&*!|>'\"%@`"
            and ":" not in text and " #" not in text and "\n" not in text and "\t" not in text
            and not NOT_PLAIN.fullmatch(text))


def _scalar(value, flow=False):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return json.dumps(value)
    if isinstance(value, (dict, list)):
        return "{}" if isinstance(value, dict) else "[]"
    return value if _plain(value, flow) else json.dumps(value, ensure_ascii=False)
