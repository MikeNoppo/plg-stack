"""Alert rules, sharing their thresholds with the dashboards through config.toml."""
from settings import number, seconds

FOLDER = "Alerts"
DISK_PCT = '100 * (1 - node_filesystem_avail_bytes{job="node"} / node_filesystem_size_bytes{job="node"})'


def rule(S, uid, title, expr, condition, severity, relative=600, summary=None, description=None):
    """condition: (operator, value) of the threshold expression, e.g. ("gt", 90)."""
    op, value = condition
    annotations = {"summary": S.t(summary)}
    if description:
        annotations["description"] = S.t(description)
    return {
        "uid": uid,
        "title": S.t(title),
        "condition": "C",
        "data": [
            {"refId": "A", "relativeTimeRange": {"from": relative, "to": 0}, "datasourceUid": "prometheus",
             "model": {"refId": "A", "instant": True, "expr": expr}},
            {"refId": "C", "datasourceUid": "__expr__",
             "model": {"refId": "C", "type": "threshold", "expression": "A",
                       "conditions": [{"evaluator": {"type": op, "params": [value]}}]}},
        ],
        "for": S.alert_for(uid),
        "noDataState": "OK",
        "execErrState": "Error",
        "labels": {"severity": severity},
        "annotations": annotations,
    }


def group(name, rules):
    return {"orgId": 1, "name": name, "folder": FOLDER, "interval": "1m", "rules": rules}


def build(S):
    forget = S.duration("reporting", "forget_after")
    quiet = S.duration("reporting", "silent_after")
    lookback = S.duration("disk_forecast", "lookback")
    horizon = seconds(S.duration("disk_forecast", "horizon"))
    window = S.duration("container_restarts", "window")
    hosts = [
        # A server that is retired on purpose stops alerting after `forget_after`.
        rule(S, "host-not-reporting", "alert.host_not_reporting.title",
             f'group by (host, env) (max_over_time(up{{job="node"}}[{forget}]))\n'
             f'unless\n'
             f'group by (host, env) (max_over_time(up{{job="node"}}[{quiet}]))\n',
             ("gt", 0), "critical", summary="alert.host_not_reporting.summary",
             description="alert.host_not_reporting.description"),
        rule(S, "disk-usage-high", "alert.disk_high.title", DISK_PCT, ("gt", S.level("disk", "warning")), "warning",
             summary="alert.disk_usage.summary"),
        rule(S, "disk-usage-critical", "alert.disk_critical.title", DISK_PCT, ("gt", S.level("disk", "critical")),
             "critical", summary="alert.disk_usage.summary"),
        rule(S, "disk-fill-24h", "alert.disk_fill.title",
             f'predict_linear(node_filesystem_avail_bytes{{job="node"}}[{lookback}], {horizon}) < 0\n'
             f'and\n'
             f'{DISK_PCT} > {number(S.config["disk_forecast"]["min_usage"])}\n',
             ("lt", 0), "warning", relative=seconds(lookback), summary="alert.disk_fill.summary"),
        rule(S, "memory-high", "alert.memory_high.title",
             '100 * (1 - node_memory_MemAvailable_bytes{job="node"} / node_memory_MemTotal_bytes{job="node"})',
             ("gt", S.level("memory", "warning")), "warning", summary="alert.memory_high.summary"),
        rule(S, "cpu-high", "alert.cpu_high.title",
             '100 * (1 - avg by (host, env) (rate(node_cpu_seconds_total{job="node", mode="idle"}[5m])))',
             ("gt", S.level("cpu", "warning")), "warning", relative=900, summary="alert.cpu_high.summary"),
    ]
    containers = [
        # Compose restarts keep the container name (start time changes);
        # Swarm/Dokploy replaces the container (a new series appears).
        # Dividing by running replicas keeps a rolling redeploy, which
        # replaces each replica once, under the threshold.
        rule(S, "container-restarting", "alert.container_restarting.title",
             '(\n'
             f'  sum by (host, env, service) (changes(container_start_time_seconds{{job="cadvisor"}}[{window}]))\n'
             '  +\n'
             '  (\n'
             f'    count by (host, env, service) (count_over_time(container_start_time_seconds{{job="cadvisor"}}[{window}]))\n'
             '    - count by (host, env, service) (container_start_time_seconds{job="cadvisor"})\n'
             '  )\n'
             ')\n'
             '/ count by (host, env, service) (container_start_time_seconds{job="cadvisor"})\n',
             ("gt", S.config["container_restarts"]["max_per_replica"]), "warning", relative=seconds(window),
             summary="alert.container_restarting.summary"),
    ]
    databases = [
        rule(S, "database-down", "alert.database_down.title",
             'min by (host, env, job) ({__name__=~"pg_up|mysql_up|redis_up|mongodb_up"})',
             ("lt", 1), "critical", summary="alert.database_down.summary",
             description="alert.database_down.description"),
    ]
    return {"apiVersion": 1,
            "groups": [group("hosts", hosts), group("containers", containers), group("databases", databases)]}
