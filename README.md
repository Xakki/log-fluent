# fluent-log

Drop-in [fluent-bit](https://fluentbit.io/) configuration that ships Docker container
logs and on-disk log files to [Graylog](https://www.graylog.org/) over GELF, and exposes
fluent-bit's own metrics to Prometheus.

It normalizes heterogeneous sources (PHP/Monolog JSON, nginx, MariaDB, Redis/KeyDB, raw
stderr) into a consistent GELF record: a Monolog-style level, a correct event timestamp,
and GELF-safe flat fields.

## Integration

This is a **config bundle**, not application code. You consume it by `include:`-ing its
`docker-fluent.yml` into your Compose stack and adding a thin overlay (an `x-logging` anchor
+ per-service labels). The `fluent-bit`/`logrotate` services, their volumes and the config
bind-mounts (`./fluent-bit`, `./logrotate`, `./service.d`) all come from the include —
**configs are used verbatim, never copied into your repo**. Update = bump the pinned version.

Compose resolves relative paths *inside* `docker-fluent.yml` relative to its own directory, so
they point into the vendored copy; the `include:` path itself is relative to your project root
(cwd where compose runs). Requires Docker Compose ≥ 2.20.

Vendor the bundle one of two ways:

### A) Composer (PHP projects)

```sh
composer require xakki/fluent-log
```

Lands at `vendor/xakki/fluent-log/`. In your logging overlay:

```yaml
include:
    - vendor/xakki/fluent-log/docker-fluent.yml
```

Companion PHP loggers that emit the structured logs this config expects:

- Laravel / Monolog — [Xakki/LaraLog](https://github.com/Xakki/LaraLog)
- Plain PHP (PSR only) — [Xakki/PHPErrorCatcher](https://github.com/Xakki/PHPErrorCatcher)

### B) git submodule (any stack — Python, Go, Node, …)

For projects without Composer. Pin a release tag:

```sh
git submodule add https://github.com/Xakki/FluentLog.git infra/fluent-log
git -C infra/fluent-log checkout v0.1.3
```

```yaml
include:
    - infra/fluent-log/docker-fluent.yml
```

A fresh clone must hydrate the submodule (the include path is empty otherwise and compose
fails): `git clone --recurse-submodules`, or `git submodule update --init --recursive`. In
GitLab/GitHub CI set `GIT_SUBMODULE_STRATEGY: recursive`. Bump = `git -C infra/fluent-log
checkout <newtag>` then commit the submodule pointer.

### The overlay (both cases)

Keep **only** the anchor + per-service labels in your file:

```yaml
include:
    - infra/fluent-log/docker-fluent.yml          # or vendor/xakki/fluent-log/...

x-logging: &_logging
    logging:
        driver: fluentd
        options:
            fluentd-address: "${EXT_FLUENT_PORT:-127.0.0.1:24224}"
            fluentd-async: "true"
            tag: "service.{{.Name}}"
            # Forwarded as flat docker_* + log_format. Do NOT use env: — host/hostname/
            # docker_profile are set globally from fluent-bit's own env (see Configuration).
            labels: "com.docker.compose.service,com.docker.compose.project,com.docker.compose.image,tier,log_format"

services:
    app:
        <<: *_logging
        labels: { tier: "web", log_format: "php" }   # omit log_format → service name → auto
    mariadb:
        <<: *_logging
        labels: { tier: "db", log_format: "mariadb" }
        depends_on: { fluent-bit: { condition: service_started } }
```

Then provide the env the bundle needs (`GRAYLOG_*`, `HOST_NAME`, `HOST_IP`,
`COMPOSE_PROJECT_NAME`, …) — see [Configuration](#configuration). Live examples:
[profmatrix](https://github.com/Xakki) uses path **A**, `proxy-service` uses path **B**.

## Pipeline

```
Docker fluentd-driver ─┐
  tag service.<container>│         ┌─ json_default (JSON auto-detect, all gl.*)
                        ├─ rewrite ─┤
tail /var/log/json/*    │  gl.<fmt> ├─ service.d/<fmt>.conf (per-type parsing)
tail mariadb slowlog ───┘          └─ level / timestamp / GELF-flatten
                                         └─ OUTPUT  GELF/HTTP → Graylog
                                            metrics → Prometheus (:2021)
```

1. **Ingest.** Two paths:
   - **Docker logging driver** (`forward` input, `:24224`). Containers with
     `logging.driver: fluentd` send here, tagged `service.<container>`.
   - **File tail** — universal NDJSON (`/var/log/json/*.ndjson`) and the MariaDB
     slowlog (mysqld can't write it to stderr).
2. **Flatten metadata.** Driver labels (`com.docker.compose.*`, `tier`, `log_format`)
   become flat `docker_*` fields. `host`/`hostname`/`docker_profile` are added globally
   from the fluent-bit container's env (`host` is mandatory — otherwise GELF would use the
   docker-bridge IP).
3. **Route by `log_format`** → tag `gl.<log_format>` (see below).
4. **Parse JSON globally.** `json_default` tries every record as JSON and silently leaves
   non-JSON lines intact (marked `log_kind=native`).
5. **Per-type parsing** in `service.d/<log_format>.conf`.
6. **Normalize** level (`level_name`/`level_php`/`syslog_severity`), event timestamp, and
   flatten nested maps/arrays into `parent_child` keys (GELF has no nested fields).
7. **Output** GELF over HTTPS to Graylog; `internal_metrics` to a Prometheus exporter.

## Routing by `log_format`

`log_format` selects the parser set; it is **not** tied to the container or service name.

- Default = the compose service name (`Copy docker_service log_format`, only-if-absent —
  an explicit label overrides it).
- Set it explicitly with a Docker label: `log_format: "<fmt>"`.
- Records are routed to the tag `gl.<log_format>`.

A `log_format` that has no matching `service.d/<fmt>.conf` is rewritten to **`auto`**
(`route_unknown` in `cleanup.lua`) and routed to `gl.auto`, where a generic, JSON-safe
multiline filter joins native stack traces. JSON is already handled by the global
`json_default`, so unmarked services need no configuration. The original service identity
stays in `docker_service`.

> `gl.auto` is a single shared multiline buffer for all unmarked services, so lines from
> different containers can in principle cross-merge. For a noisy multi-line service, set an
> explicit `log_format` label to give it its own tag.

### Supported formats

| `log_format`      | Source                                  | Parsing |
|-------------------|-----------------------------------------|---------|
| `php`             | PHP/Monolog (JSON) + raw stderr         | JSON; multiline join of Fatal/Stack trace/dumps; fpm noise dropped |
| `nginx`           | access JSON + error text                | request split; error-tail fields (client/upstream/…) |
| `mariadb`         | error log (stderr)                      | multiline join; record regex |
| `redis`           | Redis / KeyDB                           | line regex |
| `auto` (fallback) | any unmarked service                    | global JSON + generic multiline |
| `mariadb-slowlog` | slowlog file tail                       | multiline on input |

NDJSON files (`/var/log/json/*.ndjson`) are not a `log_format` of their own — each file's
`log_format` is the filename (or a per-line override), so it routes to a known type or
`auto`. See [JSON file logging](#json-file-logging-ndjson).

## Adding a service

Attach the logging driver (see `docker-fluent.yml` for the `x-logging` anchor and examples)
and label the service:

```yaml
services:
  myapp:
    <<: *_logging
    labels:
      tier: "web"
      log_format: "php"   # omit to use the service name / auto fallback
```

**A brand-new log type** with dedicated parsing needs two edits:

1. Create `fluent-bit/service.d/<fmt>.conf` matching `gl.<fmt>`.
2. Add `<fmt>` to `KNOWN_LOG_FORMAT` in `fluent-bit/cleanup.lua` (otherwise it routes to
   `auto`).

Services that don't need special parsing require neither — `gl.auto` handles JSON and
generic multiline automatically.

## JSON file logging (NDJSON)

Write one JSON object per line to `<JSON_LOG_PATH>/<service>.ndjson`. The filename becomes
`docker_service`/`log_format`; a record may override `log_format` and `tier` per line. Used
for app logs that go to a file instead of stdout/stderr.

## Configuration

Set these in `.env` (see `.env_example`):

| Variable                 | Meaning                                         | Example |
|--------------------------|-------------------------------------------------|---------|
| `TZ`                     | container timezone                              | `UTC` |
| `JSON_LOG_PATH`          | host dir tailed at `/var/log/json`              | `/var/log/` |
| `MYSQL_SLOWLOG_PATH`     | host dir tailed at `/var/log/mysql_logs`        | `/var/log/` |
| `HARBOR_LOG_PATH`        | host dir tailed at `/var/log/harbor` (optional)  | `/var/log/harbor` |
| `EXT_FLUENT_PORT`        | forward bind (host:port)                        | `127.0.0.1:24224` |
| `EXT_FLUENT_METRIC_PORT` | metrics/health bind                             | `127.0.0.1:2020` |
| `GRAYLOG_HOST`           | Graylog GELF/HTTP host                          | `graylog.example.com` |
| `GRAYLOG_URI`            | GELF endpoint                                   | `/gelf` |
| `GRAYLOG_PORT`           | GELF/HTTP port                                  | `443` |
| `HOST_NAME`              | logical host name (GELF `hostname`)             | `example_host` |
| `HOST_IP`                | host IP (GELF `host` / source)                  | `127.0.0.1` |
| `COMPOSE_PROJECT_NAME`   | project name (container/field prefix)           | `example` |
| `COMPOSE_PROFILES`       | profile → `docker_profile`                      | `dev` |

`HOST_NAME` / `HOST_IP` are typically supplied from a `Makefile`:

```makefile
HOST_NAME ?= $(shell hostname)
# first external IP
HOST_IP   ?= $(shell hostname -I 2>/dev/null | awk '{print $$1}' || echo unknown)
```

If `JSON_LOG_PATH` / `MYSQL_SLOWLOG_PATH` / `HARBOR_LOG_PATH` are unset, empty named volumes
are mounted so the stack still starts (the matching tail input simply finds no files).

When `docker-fluent.yml` is pulled into another compose file with `include:`, note that a
relative path inside it resolves against **this file's** directory, and that the including
project's `.env` outranks the `env_file:` given on the `include:` entry — pin any clashing
variable (e.g. `TZ`) in the overriding service block.

## Log rotation

`logrotate/logrotate.conf` rotates `*.log` (mysql) and `*.ndjson`/`*.json` (json) with
`copytruncate` — mandatory because fluent-bit holds the file inode open on tail; a rename
would detach it. Edit the config, then restart the `logrotate` container (it copies the
config to a root-owned path at startup).

Rotation state lives in the named volume `logrotate_state` (`/logrotate-status`) so it
survives a container recreate; without it logrotate re-learns every file and skips a cycle.

## Ports

| Port   | Purpose |
|--------|---------|
| `24224`| fluentd `forward` input (TCP/UDP) |
| `2020` | HTTP server — health / metrics |
| `2021` | Prometheus exporter (internal; proxied by nginx) |
