-- fluent-bit Lua hooks: enrichment, GELF flattening, level/timestamp normalization.
-- See README.md for the full pipeline. Each function is a [FILTER] lua callback.

local _ENV_PROJECT = os.getenv("COMPOSE_PROJECT_NAME") or "?"

-- Canonical docker_* fields for tail-input records (files have no docker driver
-- labels). host/hostname/docker_profile are set globally by [FILTER] modify Add.
local function _fill_common(record, service, tier, log_format, cn_suffix)
    record["docker_service"]   = service
    record["docker_tier"]      = tier
    record["log_format"]       = log_format
    record["docker_project"]   = _ENV_PROJECT
    record["docker_container"] = _ENV_PROJECT .. cn_suffix
    record["log_source"]       = "file"
end

-- MariaDB slowlog tail (mysqld can't write slowlog to stderr). Single source.
function enrich_mariadb_tail(tag, ts, record)
    _fill_common(record, "mariadb", "db", "mariadb-slowlog", "-mariadb")
    return 1, ts, record
end

-- Universal NDJSON tail. service = filename without .ndjson; tier/log_format
-- from the record if present, else "app"/service.
function enrich_jsonfile(tag, ts, record)
    local path = record["file"]
    local basename
    if type(path) == "string" then
        basename = path:match("([^/]+)$") or path
        basename = basename:gsub("%.ndjson$", "")
        record["file"] = nil
    else
        basename = tag:gsub("^service%.jsonfile%.?", "")
        if basename == "" then basename = "unknown" end
    end
    local service    = record["service"]    or basename
    local tier       = record["tier"]       or "app"
    local log_format = record["log_format"] or service
    record["service"] = nil
    record["tier"]    = nil
    _fill_common(record, service, tier, log_format, "-" .. basename)
    return 1, ts, record
end

-- Docker reports .Name with a leading "/" — strip it for a clean Graylog value.
function strip_container_name(tag, ts, record)
    local cn = record["docker_container"]
    if type(cn) == "string" and cn:sub(1, 1) == "/" then
        record["docker_container"] = cn:sub(2)
        return 1, ts, record
    end
    return 0, ts, record
end

-- Route services whose log_format has no specialized parser to "auto" → gl.auto
-- (generic multiline). Keep KNOWN in sync with service.d/<fmt>.conf. Identity
-- stays in docker_service.
local KNOWN_LOG_FORMAT = { php = true, nginx = true, mariadb = true, redis = true }

function route_unknown(tag, ts, record)
    local lf = record["log_format"]
    if lf and KNOWN_LOG_FORMAT[lf] then
        return 0, ts, record
    end
    record["log_format"] = "auto"
    return 1, ts, record
end

-- Split the nginx error "tail" (", client: <ip>, server: ..., request: \"...\"")
-- into discrete fields. Done in Lua: a single optional-group regex backtracks
-- badly in Onigmo. message keeps only the error description.
function parse_nginx_error_context(tag, ts, record)
    local msg = record["message"]
    if type(msg) ~= "string" then return 0, ts, record end

    local cut = string.find(msg, ", client: ", 1, true)
    if not cut then return 0, ts, record end

    local tail = string.sub(msg, cut + 2)
    record["message"] = string.sub(msg, 1, cut - 1)

    -- request: "..." first, as a whole (it contains spaces).
    local req = string.match(tail, 'request: "([^"]*)"')
    if req then
        local m, u, p = string.match(req, "^(%S+)%s+(%S+)%s+(HTTP/[%d%.]+)$")
        if m then
            record["request_method"] = m
            record["request_uri"]    = u
            record["request_proto"]  = p
        else
            record["request"] = req
        end
    end

    -- host → request_host ("host" is the GELF source field).
    local host = string.match(tail, 'host: "([^"]*)"')
    if host then record["request_host"] = host end

    local referrer = string.match(tail, 'referrer: "([^"]*)"')
    if referrer then record["referrer"] = referrer end

    local upstream = string.match(tail, 'upstream: "([^"]*)"')
    if upstream then record["upstream"] = upstream end

    local client = string.match(tail, "client: ([^,]+)")
    if client then record["client"] = client end

    local server = string.match(tail, "server: ([^,]+)")
    if server then record["server"] = server end

    return 1, ts, record
end

-- If "log" survives json_default the line wasn't JSON (raw stderr): tag it
-- log_kind=native so Graylog can separate it from structured logs.
function tag_native_stderr(tag, ts, record)
    if record["log"] == nil then return 0, ts, record end
    record["log_kind"] = "native"
    return 1, ts, record
end

-- Normalize level to the Monolog scale (level_name DEBUG..EMERGENCY, level_php
-- 100..600) and syslog_severity 0..7 for GELF (Gelf_Level_Key in OUTPUT; without
-- a 0..7 value fluent-bit errors "level is N, but should be in 0..7"). Source
-- order: Monolog JSON → nginx/mariadb level_str → keydb level_char → HTTP status → INFO.

local LEVEL_BY_NAME = {
    DEBUG     = 100,
    INFO      = 200,
    NOTICE    = 250,
    WARNING   = 300,
    ERROR     = 400,
    CRITICAL  = 500,
    ALERT     = 550,
    EMERGENCY = 600,
}

local SYSLOG_BY_NAME = {
    DEBUG     = 7,
    INFO      = 6,
    NOTICE    = 5,
    WARNING   = 4,
    ERROR     = 3,
    CRITICAL  = 2,
    ALERT     = 1,
    EMERGENCY = 0,
}

local NGINX_LEVEL = {
    debug  = "DEBUG",
    info   = "INFO",
    notice = "NOTICE",
    warn   = "WARNING",
    error  = "ERROR",
    crit   = "CRITICAL",
    alert  = "ALERT",
    emerg  = "EMERGENCY",
}

-- KeyDB: # warning, * notice, - verbose (~info), . debug.
local KEYDB_LEVEL = {
    ["#"] = "WARNING",
    ["*"] = "NOTICE",
    ["-"] = "INFO",
    ["."] = "DEBUG",
}

local MARIADB_LEVEL = {
    Note    = "NOTICE",
    Info    = "INFO",
    Warning = "WARNING",
    ERROR   = "ERROR",
}

local function set_level(record, name)
    record["level_name"] = name
    record["level_php"] = LEVEL_BY_NAME[name]
    record["syslog_severity"] = SYSLOG_BY_NAME[name]
end

function infer_level(tag, ts, record)
    -- 1) Monolog JSON already has level_name; move numeric level to level_php and
    -- free the GELF-reserved "level".
    if record["level_name"] then
        local name = string.upper(tostring(record["level_name"]))
        record["level_php"] = record["level"] or LEVEL_BY_NAME[name]
        record["level"] = nil
        record["syslog_severity"] = SYSLOG_BY_NAME[name] or 6
        return 1, ts, record
    end

    -- 2) nginx_error / mariadb_record parser (keep original under level_raw).
    local lvl_str = record["level_str"]
    if lvl_str then
        local name = NGINX_LEVEL[lvl_str] or MARIADB_LEVEL[lvl_str]
        if name then
            set_level(record, name)
            record["level_raw"] = lvl_str
            record["level_str"] = nil
            return 1, ts, record
        end
    end

    -- 3) keydb parser.
    local lvl_char = record["level_char"]
    if lvl_char then
        local name = KEYDB_LEVEL[lvl_char]
        if name then
            set_level(record, name)
            record["level_raw"] = lvl_char
            record["level_char"] = nil
            return 1, ts, record
        end
    end

    -- 4) nginx access JSON: derive from HTTP status.
    local status = record["status"]
    if status then
        local s = tonumber(status) or 0
        if s >= 500 then
            set_level(record, "ERROR")
        elseif s >= 400 then
            set_level(record, "WARNING")
        else
            set_level(record, "INFO")
        end
        return 1, ts, record
    end

    -- 5) Default.
    set_level(record, "INFO")
    return 1, ts, record
end

-- GELF requires scalar fields. Recursively flatten nested map/array into
-- parent_child keys (context.user.id -> context_user_id,
-- context.exception.trace[0] -> context_exception_trace_0).
local MAX_DEPTH  = 6
local SEP        = "_"
-- Service/scalar keys left untouched.
local SKIP = {
    container_id = true, docker_container = true, log_source = true,
    short_message = true, message = true, log = true,
    docker_service = true, docker_project = true, docker_image = true,
    docker_tier = true, docker_profile = true,
    log_format = true, log_kind = true,
    level_php = true, level_name = true, syslog_severity = true,
    channel = true, datetime = true, ["@timestamp"] = true,
}

local function is_array(t)
    if type(t) ~= "table" then return false end
    local n = 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    return n > 0
end

local function flatten(prefix, value, out, depth)
    if depth > MAX_DEPTH then
        out[prefix] = tostring(value)
        return
    end
    local t = type(value)
    if t == "table" then
        local has_keys = false
        if is_array(value) then
            for i, v in ipairs(value) do
                flatten(prefix .. SEP .. tostring(i - 1), v, out, depth + 1)
                has_keys = true
            end
        else
            for k, v in pairs(value) do
                local sk = tostring(k):gsub("[^%w]", "_")
                flatten(prefix .. SEP .. sk, v, out, depth + 1)
                has_keys = true
            end
        end
        if not has_keys then
            out[prefix] = ""
        end
    elseif t == "nil" then
        -- skip
    else
        out[prefix] = value
    end
end

function flatten_nested(tag, ts, record)
    local changed = false
    local additions = {}
    local removals  = {}
    for k, v in pairs(record) do
        if not SKIP[k] and type(v) == "table" then
            flatten(k, v, additions, 0)
            removals[#removals + 1] = k
            changed = true
        end
    end
    if not changed then
        return 0, ts, record
    end
    for _, k in ipairs(removals) do record[k] = nil end
    for k, v in pairs(additions)  do record[k] = v end
    return 1, ts, record
end

-- Event timestamp + GELF mandatory-field guards. Graylog rejects a record when
-- short_message is empty or "timestamp" is a string instead of a number.
-- Event ts comes from record.datetime (ISO 8601) or record.time_local (nginx);
-- otherwise the input ts (fluent-bit receive time) is kept.

local MONTH_NAME = {Jan=1,Feb=2,Mar=3,Apr=4,May=5,Jun=6,
                    Jul=7,Aug=8,Sep=9,Oct=10,Nov=11,Dec=12}

local function _is_leap(y)
    return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

-- Y-Mo-D h:m:s as UTC -> unix epoch (seconds).
local function _ymdhms_to_utc_epoch(Y, Mo, D, h, m, s)
    local md = {31,28,31,30,31,30,31,31,30,31,30,31}
    local days = 0
    for y = 1970, Y - 1 do
        days = days + (_is_leap(y) and 366 or 365)
    end
    for mo = 1, Mo - 1 do
        local d = md[mo]
        if mo == 2 and _is_leap(Y) then d = 29 end
        days = days + d
    end
    days = days + (D - 1)
    return days * 86400 + h * 3600 + m * 60 + s
end

-- TZ suffix ("Z" | "+03:00" | "-0500" | "") -> offset (sec); nil on bad input.
local function _parse_tz(tz)
    if not tz or tz == "" or tz == "Z" or tz == "z" then return 0 end
    local sign, hh, mm = tz:match("^([+%-])(%d%d):?(%d%d)$")
    if not sign then return nil end
    local off = (tonumber(hh) or 0) * 3600 + (tonumber(mm) or 0) * 60
    if sign == "+" then return off else return -off end
end

local function parse_iso8601(s)
    if type(s) ~= "string" or #s < 19 then return nil end
    -- "2026-05-04T22:42:37" + (".microsec")? + ("Z"|"+03:00"|"+0300"|"")
    local Y, Mo, D, h, m, sec, frac, tz =
        s:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)(%.?%d*)([Zz+%-][%d:]*)$")
    if not Y then
        Y, Mo, D, h, m, sec, frac =
            s:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)(%.?%d*)$")
        tz = ""
    end
    if not Y then return nil end
    local off = _parse_tz(tz)
    if off == nil then return nil end
    local epoch = _ymdhms_to_utc_epoch(tonumber(Y), tonumber(Mo), tonumber(D),
                                        tonumber(h), tonumber(m), tonumber(sec))
    local fr = (frac and frac ~= "" and tonumber(frac)) or 0
    return epoch + fr - off
end

local function parse_nginx_time(s)
    -- "04/May/2026:22:42:37 +0300"
    if type(s) ~= "string" then return nil end
    local D, Mname, Y, h, m, sec, sign, oh, om =
        s:match("^(%d%d)/(%a+)/(%d%d%d%d):(%d%d):(%d%d):(%d%d) ([+%-])(%d%d)(%d%d)$")
    if not D then return nil end
    local Mo = MONTH_NAME[Mname]
    if not Mo then return nil end
    local epoch = _ymdhms_to_utc_epoch(tonumber(Y), Mo, tonumber(D),
                                        tonumber(h), tonumber(m), tonumber(sec))
    local off = (tonumber(oh) * 3600 + tonumber(om) * 60)
    if sign == "-" then off = -off end
    return epoch - off
end

-- Fill short_message from the first non-empty source (empty strings rejected so
-- Graylog doesn't fail on "empty mandatory short_message field").
local function _coalesce_short_message(record)
    local sm = record["short_message"]
    if sm ~= nil and sm ~= "" then return false end
    for _, src in ipairs({"message", "msg", "log", "request_uri"}) do
        local v = record[src]
        if v ~= nil and v ~= "" then
            record["short_message"] = v
            -- The parser filter removes its source `message` key by default.
            -- For nginx access records that makes `request_uri` the fallback
            -- short_message source. Preserve it: it is a structured parsed
            -- field needed for Graylog search and aggregation, not a duplicate
            -- payload field like message/msg/log.
            if src ~= "request_uri" then record[src] = nil end
            return true
        end
    end
    record["short_message"] = "-"
    return true
end

function normalize_event_time(tag, ts, record)
    local dt = record["datetime"]
    local iso = parse_iso8601(dt)
    local new_ts = iso or parse_nginx_time(record["time_local"])

    local changed = false

    -- Non-ISO "datetime" (nginx-error/keydb/mariadb error) — DROP it. Moving it to
    -- "datetime_raw" backfired: OpenSearch date-detected that field from nginx-error's
    -- "yyyy/MM/dd HH:mm:ss" values (a default dynamic_date_format), so every non-matching
    -- value (mariadb "YYYY-MM-DD ...", keydb "DD Mon YYYY ...") failed bulk indexing and
    -- the WHOLE record was dropped. The numeric GELF timestamp (input ts = driver emission
    -- time) already carries event time; the printed string is redundant. Valid ISO8601 stays.
    if dt ~= nil and iso == nil then
        record["datetime"] = nil
        changed = true
    end

    -- Stray top-level "timestamp" → "timestamp_raw" (string would be read as the
    -- GELF-mandatory timestamp and fail the record).
    local stray_ts = record["timestamp"]
    if stray_ts ~= nil then
        record["timestamp_raw"] = stray_ts
        record["timestamp"] = nil
        changed = true
    end

    if _coalesce_short_message(record) then
        changed = true
    end

    if new_ts then
        return 2, new_ts, record
    elseif changed then
        return 1, ts, record
    end
    return 0, ts, record
end
