"""The PLG Stack dashboards. Text comes from the language catalog, thresholds from config.toml."""
from builders import (BAD_IF_ANY, LOKI, Layout, bargauge, colored, column, custom_var, dashboard,
                      dashboard_link, data_link, decimals, field, links, logs, one_step, query_var, stat,
                      state_timeline, table, target, textbox, timeseries, unit, value_mapping)
from settings import number

ENV = 'env=~"$env"'
NODE = f'job="node", {ENV}'
DATABASE_UP = 'pg_up|mysql_up|redis_up|mongodb_up'
LEVELS = ["emerg", "alert", "crit", "error", "warning", "notice", "info", "debug"]
# The sent timestamp is 0 until an agent that restarted has sent something;
# without the filter that reads as decades of delay.
LAG = ('max by (host) (prometheus_remote_storage_highest_timestamp_in_seconds{job="alloy"%s})'
       ' - max by (host) (prometheus_remote_storage_queue_highest_sent_timestamp_seconds{job="alloy"%s} > 0)')
HISTORY = '{from="state-history"}'
FIRING = '| json | current=~"Alerting.*" | labels_severity=~"$severity"'


def disk_pct(selector):
    return f'100 * (1 - node_filesystem_avail_bytes{{{selector}}} / node_filesystem_size_bytes{{{selector}}})'


def silent(S, selector):
    """Servers seen within `forget_after` that sent nothing for `silent_after`."""
    forget = S.duration("reporting", "forget_after")
    quiet = S.duration("reporting", "silent_after")
    return (f'group by (host, env) (max_over_time(up{{{selector}}}[{forget}])) '
            f'unless group by (host, env) (max_over_time(up{{{selector}}}[{quiet}]))')


class Links:
    """Data links that open another dashboard filtered on one server."""

    def __init__(self, S):
        self.t = S.t

    def host_detail(self, host, env=None):
        params = [("env", env)] if env else []
        return data_link(self.t("link.host_detail"), "host-detail", params + [("host", host)])

    def containers(self, host, env=None):
        params = [("env", env)] if env else []
        return data_link(self.t("link.containers"), "containers", params + [("host", host)])

    def logs(self, host, env=None, title="link.logs", **filters):
        params = [("env", env)] if env else []
        return data_link(self.t(title), "logs", params + [("host", host)] + list(filters.items()))

    def uptime(self, host, env=None):
        params = [("env", env)] if env else []
        return data_link(self.t("link.uptime"), "uptime", params + [("host", host)])

    def per_series(self):
        """For time series panels: the server under the cursor."""
        return [self.host_detail("${__field.labels.host}")]


def level_var(S):
    return custom_var("level", S.t("var.level"), LEVELS, all_value=".*")


def fleet(S):
    t = S.t
    go = Links(S)
    L = Layout()
    down = silent(S, NODE)
    L.add(stat(t("fleet.active_servers"), f'count(group by (host) (up{{{NODE}}}))'), 4, 4)
    L.add(stat(t("fleet.silent_servers"), f"count({down}) or vector(0)", thresholds=BAD_IF_ANY,
               desc=t("fleet.silent_servers_desc"), color_mode="background"), 4, 4)
    L.add(stat(t("fleet.full_filesystems"),
               f'count({disk_pct(NODE)} > {number(S.level("disk", "warning"))}) or vector(0)',
               thresholds=BAD_IF_ANY, color_mode="background"), 4, 4)
    L.add(stat(t("common.running_containers"), f'count(container_start_time_seconds{{job="cadvisor", {ENV}}}) or vector(0)'),
          4, 4)
    L.add(stat(t("fleet.databases_down"),
               f'count(min by (host, job) ({{__name__=~"{DATABASE_UP}", {ENV}}}) < 1) or vector(0)',
               thresholds=BAD_IF_ANY, color_mode="background"), 4, 4)
    L.add(stat(t("fleet.total_vcpu"), f'count(node_cpu_seconds_total{{{NODE}, mode="idle"}})'), 4, 4)

    host, env = t("col.host"), t("col.env")
    cpu, ram, disk = t("col.cpu"), t("col.ram"), t("fleet.col.fullest_disk")
    row_host, row_env = "${__value.raw}", field(env)
    L.add(table(t("fleet.all_servers"), [
        ("A", f'100 * (1 - avg by (host, env) (rate(node_cpu_seconds_total{{{NODE}, mode="idle"}}[5m])))'),
        ("B", f'100 * (1 - max by (host, env) (node_memory_MemAvailable_bytes{{{NODE}}} / node_memory_MemTotal_bytes{{{NODE}}}))'),
        ("C", f'max by (host, env) ({disk_pct(NODE)})'),
        ("D", f'max by (host, env) (node_load5{{{NODE}}})'),
        ("E", f'count by (host, env) (node_cpu_seconds_total{{{NODE}, mode="idle"}})'),
        ("F", f'max by (host, env) (node_memory_MemTotal_bytes{{{NODE}}})'),
        ("G", f'max by (host, env) (node_time_seconds{{{NODE}}} - node_boot_time_seconds{{{NODE}}})'),
        ("H", f'max by (host, env, version) (alloy_build_info{{job="alloy", {ENV}}})'),
    ], {"host": host, "env": env, "Value #A": cpu, "Value #B": ram, "Value #C": disk,
        "Value #D": t("col.load5"), "Value #E": "vCPU", "Value #F": t("col.ram_total"), "Value #G": t("col.uptime"),
        "version": t("fleet.col.agent")},
        overrides=[column(cpu, unit("percent"), decimals(1), *colored(S.steps("cpu"))),
                   column(ram, unit("percent"), decimals(1), *colored(S.steps("memory"))),
                   column(disk, unit("percent"), decimals(1), *colored(S.steps("disk"))),
                   column(t("col.ram_total"), unit("bytes")), column(t("col.uptime"), unit("s")),
                   column(t("col.load5"), decimals(2)),
                   column(host, links(go.host_detail(row_host, row_env), go.containers(row_host, row_env),
                                      go.logs(row_host, row_env), go.uptime(row_host, row_env)))],
        desc=t("fleet.all_servers_desc"), sort_by=cpu), 24, 10)
    L.add(table(t("fleet.silent_servers"), [("A", down)], {"host": host, "env": env},
                overrides=[column(host, links(go.logs(row_host, row_env, title="link.last_logs"),
                                              go.host_detail(row_host, row_env), go.uptime(row_host, row_env)))],
                desc=t("fleet.silent_table_desc")), 24, 5)

    L.row(t("fleet.trends"))
    per_host = go.per_series()
    L.add(timeseries(t("fleet.cpu_per_server"),
                     [target(f'100 * (1 - avg by (host) (rate(node_cpu_seconds_total{{{NODE}, mode="idle"}}[$__rate_interval])))', "{{host}}")],
                     unit="percent", minv=0, maxv=100, thresholds=S.steps("cpu"), links=per_host), 12, 8)
    L.add(timeseries(t("fleet.ram_per_server"),
                     [target(f'100 * (1 - max by (host) (node_memory_MemAvailable_bytes{{{NODE}}} / node_memory_MemTotal_bytes{{{NODE}}}))', "{{host}}")],
                     unit="percent", minv=0, maxv=100, thresholds=S.steps("memory"), links=per_host), 12, 8)
    L.add(timeseries(t("fleet.network_in"),
                     [target(f'sum by (host) (rate(node_network_receive_bytes_total{{{NODE}}}[$__rate_interval]))', "{{host}}")],
                     unit="Bps", links=per_host), 12, 8)
    L.add(timeseries(t("fleet.network_out"),
                     [target(f'sum by (host) (rate(node_network_transmit_bytes_total{{{NODE}}}[$__rate_interval]))', "{{host}}")],
                     unit="Bps", links=per_host), 12, 8)
    L.add(table(t("fleet.duplicate_names"),
                [("A", 'count by (host) (count by (host, machine_id) (alloy_build_info{job="alloy", env=~"$env"})) > 1')],
                {"host": host, "Value": t("fleet.col.machines")},
                overrides=[column(host, links(go.host_detail(row_host)))],
                desc=t("fleet.duplicate_names_desc")), 24, 5)
    return dashboard("fleet-overview", t("fleet.title"), t("fleet.description"),
                     [query_var("env", t("var.env"), 'label_values(up{job="node"}, env)')], L)


def host_detail(S):
    t = S.t
    H = 'job="node", host="$host"'
    L = Layout()
    L.add(stat(t("col.uptime"), f'node_time_seconds{{{H}}} - node_boot_time_seconds{{{H}}}', unit="s"), 4, 4)
    L.add(stat("vCPU", f'count(node_cpu_seconds_total{{{H}, mode="idle"}})'), 3, 4)
    L.add(stat(t("col.ram_total"), f'node_memory_MemTotal_bytes{{{H}}}', unit="bytes"), 3, 4)
    L.add(stat(t("col.cpu"), f'100 * (1 - avg(rate(node_cpu_seconds_total{{{H}, mode="idle"}}[5m])))', unit="percent",
               thresholds=S.steps("cpu")), 3, 4)
    L.add(stat(t("col.ram"), f'100 * (1 - node_memory_MemAvailable_bytes{{{H}}} / node_memory_MemTotal_bytes{{{H}}})',
               unit="percent", thresholds=S.steps("memory")), 3, 4)
    L.add(stat(t("host.disk_root"), disk_pct(f'{H}, mountpoint="/"'), unit="percent", thresholds=S.steps("disk")), 3, 4)
    L.add(stat(t("host.load_per_vcpu"),
               f'node_load5{{{H}}} / scalar(count(node_cpu_seconds_total{{{H}, mode="idle"}}))',
               unit="percentunit", thresholds=S.steps("load")), 5, 4)

    L.row(t("host.cpu_ram"))
    L.add(timeseries(t("host.cpu_per_mode"),
                     [target(f'100 * sum by (mode) (rate(node_cpu_seconds_total{{{H}, mode!="idle"}}[$__rate_interval])) '
                             f'/ scalar(count(node_cpu_seconds_total{{{H}, mode="idle"}}))', "{{mode}}")],
                     unit="percent", stack=True, minv=0, maxv=100, thresholds=S.steps("cpu")), 12, 8)
    L.add(timeseries(t("host.load_average"), [
        target(f'node_load1{{{H}}}', "1m"), target(f'node_load5{{{H}}}', "5m", "B"),
        target(f'node_load15{{{H}}}', "15m", "C"),
        target(f'count(node_cpu_seconds_total{{{H}, mode="idle"}})', "vCPU", "D")]), 12, 8)
    L.add(timeseries(t("col.ram"), [
        target(f'node_memory_MemTotal_bytes{{{H}}} - node_memory_MemAvailable_bytes{{{H}}}', t("host.legend.used")),
        target(f'node_memory_Cached_bytes{{{H}}} + node_memory_Buffers_bytes{{{H}}}', t("host.legend.cache"), "B"),
        target(f'node_memory_MemAvailable_bytes{{{H}}}', t("host.legend.available"), "C"),
        target(f'node_memory_SwapTotal_bytes{{{H}}} - node_memory_SwapFree_bytes{{{H}}}', t("host.legend.swap_used"), "D")],
        unit="bytes", minv=0), 12, 8)
    L.add(timeseries(t("host.processes"), [
        target(f'node_procs_running{{{H}}}', "Running"),
        target(f'node_procs_blocked{{{H}}}', t("host.legend.blocked"), "B")]), 12, 8)

    L.row(t("host.disk"))
    L.add(bargauge(t("host.filesystem_usage"), disk_pct(H), "{{mountpoint}}", unit="percent",
                   thresholds=S.steps("disk"), maxv=100), 8, 8)
    L.add(timeseries(t("host.disk_throughput"), [
        target(f'sum by (device) (rate(node_disk_read_bytes_total{{{H}}}[$__rate_interval]))', t("host.legend.read")),
        target(f'-sum by (device) (rate(node_disk_written_bytes_total{{{H}}}[$__rate_interval]))', t("host.legend.write"), "B")],
        unit="Bps"), 8, 8)
    L.add(timeseries(t("host.disk_busy"), [
        target(f'100 * rate(node_disk_io_time_seconds_total{{{H}}}[$__rate_interval])', "{{device}}")],
        unit="percent", minv=0, maxv=100), 8, 8)

    L.row(t("host.network"))
    L.add(timeseries(t("host.traffic"), [
        target(f'rate(node_network_receive_bytes_total{{{H}}}[$__rate_interval])', t("host.legend.in")),
        target(f'-rate(node_network_transmit_bytes_total{{{H}}}[$__rate_interval])', t("host.legend.out"), "B")],
        unit="Bps"), 12, 8)
    L.add(timeseries(t("host.tcp"), [
        target(f'node_netstat_Tcp_CurrEstab{{{H}}}', "Established"),
        target(f'node_sockstat_TCP_tw{{{H}}}', "Time wait", "B")]), 12, 8)

    L.row(t("host.processes"))
    L.add(timeseries(t("host.cpu_per_process"), [target(
        '100 * sum by (groupname) (rate(namedprocess_namegroup_cpu_seconds_total{job="process", host="$host"}[$__rate_interval]))',
        "{{groupname}}")], unit="percent", desc=t("host.cpu_per_process_desc")), 12, 8)
    L.add(timeseries(t("host.ram_per_process"), [target(
        'sum by (groupname) (namedprocess_namegroup_memory_bytes{job="process", host="$host", memtype="resident"})',
        "{{groupname}}")], unit="bytes", desc=t("host.ram_per_process_desc")), 12, 8)

    L.row(t("host.agent"))
    lag = LAG % (', host="$host"', ', host="$host"')
    L.add(timeseries(t("host.agent_lag"), [target(lag, t("host.legend.pending"))], unit="s", minv=0,
                     thresholds=S.steps("agent_lag"), desc=t("host.agent_lag_desc")), 12, 8)
    L.add(timeseries(t("host.retries"), [
        target('sum(rate(prometheus_remote_storage_samples_retried_total{job="alloy", host="$host"}[$__rate_interval]))',
               t("host.legend.metrics_retried")),
        target('sum(rate(loki_write_batch_retries_total{job="alloy", host="$host"}[$__rate_interval]))',
               t("host.legend.log_batches_retried"), "B"),
        target('sum(rate(prometheus_remote_storage_samples_failed_total{job="alloy", host="$host"}[$__rate_interval]))',
               t("host.legend.metrics_dropped"), "C"),
        target('sum(rate(loki_write_dropped_entries_total{job="alloy", host="$host"}[$__rate_interval]))',
               t("host.legend.logs_dropped"), "D")], unit="ops", desc=t("host.retries_desc")), 12, 8)

    L.row(t("host.journal"))
    L.add(logs("Journald", '{host="$host", source="journal", level=~"$level"} |~ "(?i)$search"'), 24, 14)

    return dashboard("host-detail", t("host.title"), t("host.description"), [
        query_var("env", t("var.env"), 'label_values(up{job="node"}, env)'),
        query_var("host", t("var.host"), 'label_values(up{job="node", env=~"$env"}, host)', multi=False, include_all=False),
        level_var(S),
        textbox("search", t("var.search")),
    ], L, links=[
        dashboard_link(t("link.containers"), "/d/containers/containers?var-host=$host"),
        dashboard_link(t("link.logs"), "/d/logs/logs?var-host=$host"),
        dashboard_link(t("link.uptime"), "/d/uptime/uptime?var-host=$host"),
    ])


def containers(S):
    t = S.t
    go = Links(S)
    C = 'job="cadvisor", env=~"$env", host=~"$host", service=~"$service"'
    L = Layout()
    L.add(stat(t("common.running_containers"), f'count(container_start_time_seconds{{{C}}}) or vector(0)'), 6, 4)
    L.add(stat(t("containers.total_cpu"), f'sum(rate(container_cpu_usage_seconds_total{{{C}}}[5m]))',
               desc=t("containers.total_cpu_desc")), 6, 4)
    L.add(stat(t("containers.total_ram"), f'sum(container_memory_working_set_bytes{{{C}}})', unit="bytes"), 6, 4)
    L.add(stat(t("containers.recreated"),
               f'(sum(changes(container_start_time_seconds{{{C}}}[$__range])) + '
               f'count(count_over_time(container_start_time_seconds{{{C}}}[$__range])) - '
               f'count(container_start_time_seconds{{{C}}})) or vector(0)',
               thresholds=one_step("orange", 1)), 6, 4)

    host, service, cpu = t("col.host"), t("col.service"), t("containers.col.cpu")
    L.add(table(t("containers.table"), [
        ("A", f'max by (host, service, container, image) (time() - container_start_time_seconds{{{C}}})'),
        ("B", f'100 * max by (host, service, container, image) (rate(container_cpu_usage_seconds_total{{{C}}}[5m]))'),
        ("C", f'max by (host, service, container, image) (container_memory_working_set_bytes{{{C}}})'),
        ("D", f'max by (host, service, container, image) (container_spec_memory_limit_bytes{{{C}}} > 0)'),
    ], {"host": host, "service": service, "container": "Container", "image": "Image",
        "Value #B": cpu, "Value #C": t("col.ram"), "Value #D": t("containers.col.ram_limit"), "Value #A": t("col.uptime")},
        overrides=[column(cpu, unit("percent"), decimals(1)),
                   column(t("col.ram"), unit("bytes")), column(t("containers.col.ram_limit"), unit("bytes")),
                   column(t("col.uptime"), unit("s")),
                   column(host, links(go.host_detail("${__value.raw}"))),
                   column(service, links(go.logs(field(host), title="link.service_logs",
                                                 service="${__value.raw}", source="docker")))],
        sort_by=t("col.ram")), 24, 10)

    service_logs = [go.logs("${__field.labels.host}", title="link.service_logs",
                            service="${__field.labels.service}", source="docker")]
    L.row(t("containers.per_service"))
    L.add(timeseries(t("containers.cpu_per_service"),
                     [target(f'100 * sum by (host, service) (rate(container_cpu_usage_seconds_total{{{C}}}[$__rate_interval]))',
                             "{{service}} @ {{host}}")], unit="percent", desc=t("containers.cpu_per_service_desc"),
                     links=service_logs), 12, 9)
    L.add(timeseries(t("containers.ram_per_service"),
                     [target(f'sum by (host, service) (container_memory_working_set_bytes{{{C}}})', "{{service}} @ {{host}}")],
                     unit="bytes", links=service_logs), 12, 9)
    L.add(timeseries(t("containers.network_in"),
                     [target(f'sum by (host, service) (rate(container_network_receive_bytes_total{{{C}}}[$__rate_interval]))',
                             "{{service}} @ {{host}}")], unit="Bps", links=service_logs), 12, 8)
    L.add(timeseries(t("containers.network_out"),
                     [target(f'sum by (host, service) (rate(container_network_transmit_bytes_total{{{C}}}[$__rate_interval]))',
                             "{{service}} @ {{host}}")], unit="Bps", links=service_logs), 12, 8)

    L.row(t("containers.logs"))
    L.add(logs(t("common.logs"), '{source="docker", level=~"$level", env=~"$env", host=~"$host", service=~"$service"} |~ "(?i)$search"'),
          24, 14)

    return dashboard("containers", t("containers.title"), t("containers.description"), [
        query_var("env", t("var.env"), 'label_values(container_start_time_seconds{job="cadvisor"}, env)'),
        query_var("host", t("var.host"), 'label_values(container_start_time_seconds{job="cadvisor", env=~"$env"}, host)'),
        query_var("service", t("var.service"),
                  'label_values(container_start_time_seconds{job="cadvisor", env=~"$env", host=~"$host"}, service)',
                  all_value=".*"),
        level_var(S),
        textbox("search", t("var.search")),
    ], L, time_from="now-3h")


def logs_dashboard(S):
    t = S.t
    go = Links(S)
    F = 'level=~"$level", env=~"$env", host=~"$host", source=~"$source", service=~"$service"'
    L = Layout()
    L.add(timeseries(t("logs.volume_per_host"),
                     [target(f'sum by (host) (count_over_time({{{F}}} |~ "(?i)$search" [$__auto]))', "{{host}}", ds=LOKI)],
                     stack=True, ds=LOKI, links=go.per_series()), 12, 7)
    L.add(timeseries(t("logs.errors_per_host"),
                     [target(f'sum by (host) (count_over_time({{{F}}} |~ "(?i)(error|fatal|panic|exception|critical)" [$__auto]))',
                             "{{host}}", ds=LOKI)],
                     stack=True, ds=LOKI, desc=t("logs.errors_per_host_desc"), links=go.per_series()), 12, 7)
    L.add(logs(t("common.logs"), f'{{{F}}} |~ "(?i)$search"'), 24, 20)
    return dashboard("logs", t("logs.title"), t("logs.description"), [
        query_var("env", t("var.env"), 'label_values(env)', ds=LOKI),
        query_var("host", t("var.host"), 'label_values({env=~"$env"}, host)', ds=LOKI),
        custom_var("source", t("var.source"), ["docker", "journal", "file"]),
        query_var("service", t("var.service"), 'label_values({env=~"$env", host=~"$host"}, service)', ds=LOKI, all_value=".*"),
        level_var(S),
        textbox("search", t("var.search")),
    ], L, time_from="now-1h")


def databases(S):
    t = S.t
    go = Links(S)
    D = 'env=~"$env", host=~"$host"'
    L = Layout()
    host, database = t("col.host"), t("col.database")
    L.add(table(t("databases.status"), [
        ("A", f'min by (host, env, job) ({{__name__=~"{DATABASE_UP}", {D}}})')],
        {"host": host, "env": t("col.env"), "job": database, "Value": t("col.status")},
        overrides=[column(t("col.status"), {"id": "mappings", "value": value_mapping((0, "DOWN", "red"), (1, "UP", "green"))},
                          {"id": "custom.cellOptions", "value": {"type": "color-background"}}),
                   column(host, links(go.host_detail("${__value.raw}"))),
                   column(database, links(go.logs(field(host), title="link.database_logs",
                                                  service="${__value.raw}", source="file")))]), 24, 6)

    L.row("PostgreSQL")
    L.add(timeseries(t("databases.connections_per_db"),
                     [target(f'sum by (host, datname) (pg_stat_database_numbackends{{{D}}})', "{{datname}} @ {{host}}"),
                      target(f'max by (host) (pg_settings_max_connections{{{D}}})', "max @ {{host}}", "B")]), 8, 8)
    L.add(timeseries(t("databases.transactions"),
                     [target(f'sum by (host) (rate(pg_stat_database_xact_commit{{{D}}}[$__rate_interval]))', "commit @ {{host}}"),
                      target(f'sum by (host) (rate(pg_stat_database_xact_rollback{{{D}}}[$__rate_interval]))', "rollback @ {{host}}", "B")],
                     unit="ops"), 8, 8)
    L.add(timeseries(t("databases.size"),
                     [target(f'max by (host, datname) (pg_database_size_bytes{{{D}}})', "{{datname}} @ {{host}}")],
                     unit="bytes"), 8, 8)

    L.row("MySQL / MariaDB")
    L.add(timeseries(t("databases.connections"),
                     [target(f'max by (host) (mysql_global_status_threads_connected{{{D}}})', t("databases.legend.connected")),
                      target(f'max by (host) (mysql_global_variables_max_connections{{{D}}})', "max @ {{host}}", "B")]), 8, 8)
    L.add(timeseries(t("databases.queries"),
                     [target(f'sum by (host) (rate(mysql_global_status_queries{{{D}}}[$__rate_interval]))', "{{host}}")],
                     unit="ops"), 8, 8)
    L.add(timeseries(t("databases.slow_queries"),
                     [target(f'sum by (host) (rate(mysql_global_status_slow_queries{{{D}}}[$__rate_interval]))', "{{host}}")],
                     unit="ops"), 8, 8)

    L.row("Redis")
    L.add(timeseries(t("databases.memory"), [target(f'max by (host) (redis_memory_used_bytes{{{D}}})', "{{host}}")],
                     unit="bytes"), 8, 8)
    L.add(timeseries(t("databases.clients"), [target(f'max by (host) (redis_connected_clients{{{D}}})', "{{host}}")]), 8, 8)
    L.add(timeseries(t("databases.commands"),
                     [target(f'sum by (host) (rate(redis_commands_processed_total{{{D}}}[$__rate_interval]))', "{{host}}")],
                     unit="ops"), 8, 8)

    L.row("MongoDB")
    L.add(timeseries(t("databases.connections"),
                     [target(f'max by (host) (mongodb_ss_connections{{{D}, conn_type="current"}})', "{{host}}")]), 12, 8)
    L.add(timeseries(t("databases.operations"),
                     [target(f'sum by (host, legacy_op_type) (rate(mongodb_ss_opcounters{{{D}}}[$__rate_interval]))',
                             "{{legacy_op_type}} @ {{host}}")], unit="ops"), 12, 8)

    L.row(t("databases.logs"))
    L.add(logs(t("common.logs"), '{source="file", env=~"$env", host=~"$host", service=~"postgres|mysql|redis|mongodb"} |~ "(?i)$search"'),
          24, 12)

    return dashboard("databases", t("databases.title"), t("databases.description"), [
        query_var("env", t("var.env"), f'label_values({{__name__=~"{DATABASE_UP}"}}, env)'),
        query_var("host", t("var.host"), f'label_values({{__name__=~"{DATABASE_UP}", env=~"$env"}}, host)'),
        textbox("search", t("var.search")),
    ], L)


def stack_health(S):
    t = S.t
    go = Links(S)
    P = 'job="plg-prometheus"'
    LK = 'job="plg-loki"'
    L = Layout()
    up_down = value_mapping((0, "DOWN", "red"), (1, "UP", "green"))
    L.add(stat(t("health.components"), 'up{job=~"plg-.*"}', mappings=up_down, legend="{{job}}",
               thresholds={"mode": "absolute", "steps": [{"color": "red", "value": None}, {"color": "green", "value": 1}]},
               color_mode="background"), 10, 4)
    L.add(stat(t("health.active_agents"), 'count(count by (host) (alloy_build_info{job="alloy"}))'), 3, 4)
    L.add(stat(t("health.active_series"), f'prometheus_tsdb_head_series{{{P}}}'), 3, 4)
    L.add(stat(t("health.metrics_disk_pct"),
               f'100 * (prometheus_tsdb_storage_blocks_bytes{{{P}}} + prometheus_tsdb_wal_storage_size_bytes{{{P}}})'
               f' / prometheus_tsdb_retention_limit_bytes{{{P}}}',
               unit="percent", thresholds=S.steps("metrics_disk"), desc=t("health.metrics_disk_pct_desc")), 4, 4)
    L.add(stat(t("health.metrics_disk"),
               f'prometheus_tsdb_storage_blocks_bytes{{{P}}} + prometheus_tsdb_wal_storage_size_bytes{{{P}}}',
               unit="bytes"), 4, 4)

    L.row(t("health.metrics_ingest"))
    L.add(timeseries(t("health.samples_in"),
                     [target(f'rate(prometheus_tsdb_head_samples_appended_total{{{P}}}[$__rate_interval])', "{{type}}")],
                     unit="ops"), 8, 8)
    L.add(timeseries(t("health.remote_write_status"),
                     [target(f'sum by (code) (rate(prometheus_http_requests_total{{{P}, handler="/api/v1/write"}}[$__rate_interval]))',
                             "HTTP {{code}}")], unit="reqps"), 8, 8)
    L.add(timeseries(t("health.late_samples"), [
        target(f'sum(rate(prometheus_tsdb_head_out_of_order_samples_appended_total{{{P}}}[$__rate_interval]))',
               t("health.legend.late_accepted")),
        target(f'sum(rate(prometheus_tsdb_out_of_order_samples_total{{{P}}}[$__rate_interval]))',
               t("health.legend.rejected_order"), "B"),
        target(f'sum(rate(prometheus_tsdb_out_of_bound_samples_total{{{P}}}[$__rate_interval]))',
               t("health.legend.rejected_bounds"), "C"),
        target(f'sum(rate(prometheus_tsdb_too_old_samples_total{{{P}}}[$__rate_interval]))',
               t("health.legend.rejected_old"), "D")],
        unit="ops", desc=t("health.late_samples_desc")), 8, 8)
    L.add(bargauge(t("health.samples_per_server"), 'sum by (host) (scrape_samples_scraped{host!=""})', "{{host}}",
                   desc=t("health.samples_per_server_desc"), join=True), 24, 7)

    L.row(t("health.logs_ingest"))
    L.add(timeseries(t("health.logs_in"), [
        target(f'sum(rate(loki_distributor_bytes_received_total{{{LK}}}[$__rate_interval]))', t("health.legend.bytes_per_s")),
        target(f'sum(rate(loki_distributor_lines_received_total{{{LK}}}[$__rate_interval]))', t("health.legend.lines_per_s"), "B")],
        unit="short"), 12, 8)
    L.add(timeseries(t("health.logs_rejected"), [
        target(f'sum by (reason) (rate(loki_discarded_samples_total{{{LK}}}[$__rate_interval]))', "{{reason}}")],
        unit="ops", desc=t("health.logs_rejected_desc")), 12, 8)
    L.add(bargauge(t("health.log_volume_per_server"), 'sum by (host) (bytes_over_time({host=~".+"}[$__range]))',
                   "{{host}}", unit="bytes", ds=LOKI, desc=t("health.log_volume_per_server_desc")), 24, 7)

    L.row(t("health.agents"))
    host, lag = t("col.host"), t("health.col.lag")
    dropped = BAD_IF_ANY
    L.add(table(t("health.agent_status"), [
        ("A", 'max by (host, version) (alloy_build_info{job="alloy"})'),
        ("B", LAG % ("", "")),
        ("C", 'sum by (host) (increase(prometheus_remote_storage_samples_failed_total{job="alloy"}[1h]))'),
        ("D", 'sum by (host) (increase(loki_write_dropped_entries_total{job="alloy"}[1h]))'),
        ("E", 'sum by (host) (increase(loki_process_dropped_lines_total{job="alloy"}[1h]))'),
    ], {"host": host, "version": t("health.col.version"), "Value #B": lag,
        "Value #C": t("health.col.metrics_dropped"), "Value #D": t("health.col.logs_dropped"),
        "Value #E": t("health.col.logs_filtered")},
        overrides=[column(lag, unit("s"), *colored(S.steps("agent_lag"))),
                   column(t("health.col.metrics_dropped"), *colored(dropped, "color-text")),
                   column(t("health.col.logs_dropped"), *colored(dropped, "color-text")),
                   column(host, links(go.host_detail("${__value.raw}")))],
        desc=t("health.agent_status_desc"), sort_by=lag), 24, 9)
    L.add(timeseries(t("health.lag_per_server"), [target(LAG % ("", ""), "{{host}}")], unit="s", minv=0,
                     thresholds=S.steps("agent_lag"), desc=t("health.lag_per_server_desc"), links=go.per_series()), 24, 8)

    return dashboard("plg-stack-health", t("health.title"), t("health.description"), [], L)


def uptime(S):
    t = S.t
    go = Links(S)
    U = 'job="node", env=~"$env", host=~"$host"'
    # 1 for every whole minute a server sent at least one sample.
    present = f'(max by (host, env) (present_over_time(up{{{U}}}[1m])))[$__range:1m]'
    minutes_up = f'sum_over_time({present})'
    # Minutes from the server's first sample (or the start of the range) until
    # now, counted like minutes_up, so a server added mid-range is not counted
    # as down before it existed. Ranges exclude their start, hence the 1 ms.
    first = f'clamp_min(min by (host, env) (min_over_time(timestamp(up{{{U}}})[$__range:1m])), time() - $__range_s + 0.001)'
    minutes_total = f'(scalar(floor(vector(time() / 60))) - ceil({first} / 60) + 1)'
    availability = f'100 * clamp_max({minutes_up} / {minutes_total}, 1)'
    down = f'60 * clamp_min({minutes_total} - {minutes_up}, 0)'
    reboots = f'sum by (host, env) (resets((node_time_seconds{{{U}}} - node_boot_time_seconds{{{U}}})[$__range:1m]))'

    L = Layout()
    L.add(stat(t("uptime.average"), f'avg({availability})', unit="percent", decimals=2,
               thresholds=S.steps("availability"), desc=t("uptime.average_desc")), 6, 4)
    L.add(stat(t("uptime.servers"), f'count({availability})'), 6, 4)
    L.add(stat(t("uptime.total_down"), f'sum({down})', unit="s", thresholds=one_step("orange", 60)), 6, 4)
    L.add(stat(t("uptime.reboots"), f'sum({reboots}) or vector(0)', thresholds=one_step("orange", 1),
               desc=t("uptime.reboots_desc")), 6, 4)

    host, avail = t("col.host"), t("uptime.col.availability")
    row_host, row_env = "${__value.raw}", field(t("col.env"))
    L.add(table(t("uptime.per_server"), [
        ("A", availability),
        ("B", down),
        ("C", reboots),
        ("D", f'max by (host, env) (node_time_seconds{{{U}}} - node_boot_time_seconds{{{U}}})'),
        # The latest sample when there is one; the per-minute subquery only
        # for servers that have been silent for longer than the lookback.
        ("E", f'time() - max by (host, env) (timestamp(up{{{U}}}) or max_over_time(timestamp(up{{{U}}})[$__range:1m]))'),
    ], {"host": host, "env": t("col.env"), "Value #A": avail, "Value #B": t("uptime.col.down"),
        "Value #C": t("uptime.col.reboots"), "Value #D": t("col.uptime"), "Value #E": t("uptime.col.last_seen")},
        overrides=[column(avail, unit("percent"), decimals(2), *colored(S.steps("availability"))),
                   column(t("uptime.col.down"), unit("s")), column(t("uptime.col.reboots"), decimals(0)),
                   column(t("col.uptime"), unit("s")), column(t("uptime.col.last_seen"), unit("s")),
                   column(host, links(go.host_detail(row_host, row_env), go.logs(row_host, row_env)))],
        desc=t("uptime.per_server_desc"), sort_by=avail, sort_desc=False), 24, 9)

    # Per minute like minutes_up: 1 if the server sent data, 0 from its first
    # sample on if it did not. A bar is red if any of its minutes is 0.
    since_first = f'min by (host) (min_over_time(timestamp(up{{{U}}})[$__range:1m] @ end())) <= time()'
    reporting = (f'min_over_time((max by (host) (present_over_time(up{{{U}}}[1m])) or 0 * ({since_first}))'
                 f'[$__interval:1m])')
    L.add(state_timeline(t("uptime.timeline"), reporting, "{{host}}",
                         value_mapping((0, t("uptime.not_reporting"), "red"), (1, t("uptime.reporting"), "green")),
                         desc=t("uptime.timeline_desc"), interval="1m"), 24, 9)

    L.row(t("uptime.services"))
    database = t("col.database")
    L.add(table(t("uptime.databases"), [
        ("A", f'100 * avg_over_time((min by (host, env, job) ({{__name__=~"{DATABASE_UP}", env=~"$env", host=~"$host"}}))[$__range:1m])')],
        {"host": host, "env": t("col.env"), "job": database, "Value": avail},
        overrides=[column(avail, unit("percent"), decimals(2), *colored(S.steps("availability"))),
                   column(host, links(go.host_detail(row_host))),
                   column(database, links(go.logs(field(host), title="link.database_logs",
                                                  service="${__value.raw}", source="file")))],
        desc=t("uptime.databases_desc"), sort_by=avail, sort_desc=False), 12, 8)
    L.add(stat(t("uptime.components"), '100 * avg_over_time(up{job=~"plg-.*"}[$__range])', unit="percent",
               decimals=2, legend="{{job}}", thresholds=S.steps("availability"), color_mode="background",
               desc=t("uptime.components_desc")), 12, 8)

    return dashboard("uptime", t("uptime.title"), t("uptime.description"), [
        query_var("env", t("var.env"), 'label_values(up{job="node"}, env)'),
        query_var("host", t("var.host"), 'label_values(up{job="node", env=~"$env"}, host)'),
    ], L, time_from="now-7d")


def alert_history(S):
    t = S.t
    G = 'job="plg-grafana"'
    L = Layout()
    L.add(stat(t("alerts.firing_now"), f'sum(grafana_alerting_alerts{{{G}, state="alerting"}}) or vector(0)',
               thresholds=BAD_IF_ANY, color_mode="background"), 5, 4)
    L.add(stat(t("alerts.pending_now"), f'sum(grafana_alerting_alerts{{{G}, state="pending"}}) or vector(0)',
               thresholds=one_step("orange", 1), desc=t("alerts.pending_now_desc")), 5, 4)
    L.add(stat(t("alerts.fired_in_range"), f'sum(count_over_time({HISTORY} {FIRING} [$__range])) or vector(0)',
               ds=LOKI, desc=t("alerts.fired_in_range_desc")), 5, 4)
    L.add(stat(t("alerts.history_failed"),
               f'round(sum(increase(grafana_alerting_state_history_writes_failed_total{{{G}}}[$__range]))) or vector(0)',
               thresholds=BAD_IF_ANY, desc=t("alerts.history_failed_desc")), 5, 4)
    L.add(stat(t("alerts.evaluation_failures"),
               f'round(sum(increase(grafana_alerting_rule_evaluation_failures_total{{{G}}}[$__range]))) or vector(0)',
               thresholds=BAD_IF_ANY, desc=t("alerts.evaluation_failures_desc")), 4, 4)

    L.add(timeseries(t("alerts.fired_per_rule"),
                     [target(f'sum by (ruleTitle) (count_over_time({HISTORY} {FIRING} [$__auto]))', "{{ruleTitle}}",
                             ds=LOKI)], ds=LOKI, stack=True, bars=True), 16, 8)
    L.add(bargauge(t("alerts.most_frequent"),
                   f'topk(10, sum by (ruleTitle) (count_over_time({HISTORY} {FIRING} [$__range])))', "{{ruleTitle}}",
                   ds=LOKI), 8, 8)

    line = ('{{.previous}} → {{.current}}  {{.ruleTitle}}'
            '{{with .labels_host}}  host={{.}}{{end}}{{with .labels_env}} ({{.}}){{end}}'
            '{{with .labels_mountpoint}}  {{.}}{{end}}{{with .labels_service}}  service={{.}}{{end}}'
            '{{with .labels_job}}  job={{.}}{{end}}'
            '{{with .values_A}}  ' + t("alerts.value") + '={{.}}{{end}}')
    # Rules log Normal -> Normal (NoData) whenever Grafana starts; only real
    # changes are listed.
    L.add(logs(t("alerts.changes"),
               f'{HISTORY} |~ "(?i)$search" | json | current=~"(${{state}}).*" | labels_severity=~"$severity" '
               f'| (current !~ "Normal.*" or previous !~ "Normal.*") | line_format `{line}`',
               desc=t("alerts.changes_desc")), 24, 16)

    return dashboard("alert-history", t("alerts.title"), t("alerts.description"), [
        custom_var("severity", t("var.severity"), ["critical", "warning"], all_value=".*"),
        custom_var("state", t("var.state"), ["Alerting", "Pending", "Normal", "NoData", "Error", "Recovering"],
                   all_value=".*"),
        textbox("search", t("var.search")),
    ], L, time_from="now-7d", links=[
        dashboard_link(t("link.alert_rules"), "/alerting/list", icon="bolt", keep_time=False),
        dashboard_link(t("link.grafana_history"), "/alerting/history", icon="doc", keep_time=False),
    ])


DASHBOARDS = {
    "fleet-overview": fleet,
    "host-detail": host_detail,
    "containers": containers,
    "logs": logs_dashboard,
    "databases": databases,
    "plg-stack-health": stack_health,
    "uptime": uptime,
    "alert-history": alert_history,
}


def build(S):
    return {uid: make(S) for uid, make in DASHBOARDS.items()}
