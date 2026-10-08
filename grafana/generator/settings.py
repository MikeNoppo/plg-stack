"""Reads config.toml and the text catalog of the selected language."""
import re
import tomllib
from pathlib import Path

HERE = Path(__file__).resolve().parent
UNIT_SECONDS = {"w": 604800, "d": 86400, "h": 3600, "m": 60, "s": 1}
# {name} placeholders; Grafana's {{...}} templates and legends are left alone.
PLACEHOLDER = re.compile(r"(?<!\{)\{([a-z_]+)\}(?!\})")


def seconds(duration):
    match = re.fullmatch(r"(\d+)([smhdw])", str(duration))
    if not match:
        raise ValueError(f"invalid duration {duration!r}; use a number and s/m/h/d/w, e.g. 5m or 24h")
    return int(match[1]) * UNIT_SECONDS[match[2]]


def compact(total):
    """Seconds as the largest whole unit, e.g. 300 -> '5m'."""
    for suffix, size in UNIT_SECONDS.items():
        if total and total % size == 0:
            return f"{total // size}{suffix}"
    return "0s"


def number(value):
    return format(value, "g")


def flatten(table, prefix=""):
    out = {}
    for key, value in table.items():
        if isinstance(value, dict):
            out.update(flatten(value, f"{prefix}{key}."))
        else:
            out[f"{prefix}{key}"] = value
    return out


def load_catalog(language):
    path = HERE / "lang" / f"{language}.toml"
    if not path.exists():
        available = ", ".join(sorted(p.stem for p in (HERE / "lang").glob("*.toml")))
        raise ValueError(f"unknown language {language!r} (available: {available})")
    return flatten(tomllib.loads(path.read_text()))


class Settings:
    # Thresholds where a lower value is the worse one.
    LOWER_IS_WORSE = {"availability"}

    def __init__(self, config, language=None):
        self.config = config
        self.language = language or config.get("language", "id")
        self.catalog = load_catalog(self.language)
        overrides = flatten(config.get("text", {}))
        unknown = sorted(set(overrides) - set(self.catalog))
        if unknown:
            raise ValueError(f"[text] in config.toml overrides unknown keys: {', '.join(unknown)}")
        self.catalog.update(overrides)
        self.thresholds = config["thresholds"]
        for name in self.thresholds:
            self._check_levels(name)
        self.params = self._params()

    @classmethod
    def load(cls, path, language=None):
        return cls(tomllib.loads(Path(path).read_text()), language)

    def t(self, key):
        try:
            text = self.catalog[key]
        except KeyError:
            raise KeyError(f"text {key!r} is missing from lang/{self.language}.toml") from None

        def fill(match):
            name = match[1]
            if name not in self.params:
                raise KeyError(f"text {key!r} uses unknown placeholder {{{name}}}")
            return self.params[name]

        return PLACEHOLDER.sub(fill, text)

    def human(self, duration):
        """'24h' -> '24 jam' / '24 hours', in the unit it is written in."""
        seconds(duration)
        amount, suffix = int(duration[:-1]), duration[-1]
        names = self.catalog[f"units.{suffix}"]
        if isinstance(names, list):
            return f"{amount} {names[0] if amount == 1 else names[1]}"
        return f"{amount} {names}"

    def level(self, name, level):
        """A threshold value; durations are returned in seconds."""
        value = self.thresholds[name][level]
        return seconds(value) if isinstance(value, str) else value

    def steps(self, name):
        """Grafana thresholds: orange from `warning`, red from `critical`."""
        warning, critical = self.level(name, "warning"), self.level(name, "critical")
        if name in self.LOWER_IS_WORSE:
            return {"mode": "absolute", "steps": [{"color": "red", "value": None},
                                                  {"color": "orange", "value": critical},
                                                  {"color": "green", "value": warning}]}
        return {"mode": "absolute", "steps": [{"color": "green", "value": None},
                                              {"color": "orange", "value": warning},
                                              {"color": "red", "value": critical}]}

    def duration(self, section, key):
        value = self.config[section][key]
        seconds(value)
        return value

    def alert_for(self, uid):
        return self.duration("alert_for", uid)

    def _check_levels(self, name):
        levels = self.thresholds[name]
        if set(levels) != {"warning", "critical"}:
            raise ValueError(f"thresholds.{name} needs exactly `warning` and `critical`")
        warning, critical = self.level(name, "warning"), self.level(name, "critical")
        worse_is_lower = name in self.LOWER_IS_WORSE
        if (warning <= critical) if worse_is_lower else (warning >= critical):
            relation = "above" if worse_is_lower else "below"
            raise ValueError(f"thresholds.{name}: warning must be {relation} critical")

    def _params(self):
        params = {}
        for name, levels in self.thresholds.items():
            for level, value in levels.items():
                params[f"{name}_{level}"] = self.human(value) if isinstance(value, str) else number(value)
        params["silent_after"] = self.human(self.duration("reporting", "silent_after"))
        params["forget_after"] = self.human(self.duration("reporting", "forget_after"))
        params["not_reporting_after"] = self.human(compact(
            seconds(self.duration("reporting", "silent_after")) + seconds(self.alert_for("host-not-reporting"))))
        params["forecast_lookback"] = self.human(self.duration("disk_forecast", "lookback"))
        params["forecast_horizon"] = self.human(self.duration("disk_forecast", "horizon"))
        params["forecast_min_usage"] = number(self.config["disk_forecast"]["min_usage"])
        params["restart_window"] = self.human(self.duration("container_restarts", "window"))
        params["restart_max"] = number(self.config["container_restarts"]["max_per_replica"])
        for uid in self.config["alert_for"]:
            params["for_" + uid.replace("-", "_")] = self.human(self.alert_for(uid))
        return params
