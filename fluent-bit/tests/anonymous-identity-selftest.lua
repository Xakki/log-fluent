-- Unit assertions for the sanitize_php_fpm_anonymous_identity callback.
-- Runs inside a real fluent-bit process (see anonymous-identity-selftest.conf):
-- --dry-run does NOT load Lua scripts, so a dry-run "test" proves nothing.
-- The legacy php-fpm envelope is covered end-to-end by anonymous-identity-pipeline.conf,
-- where the php_fpm_anonymous_identity parser decodes it without a Lua JSON decoder.
dofile("/fluent-bit/etc/cleanup.lua")

local has_cjson = pcall(require, "cjson")

local function assert_equal(actual, expected, label)
    if actual ~= expected then
        error(label)
    end
end

local function run(record)
    local code, _, output = sanitize_php_fpm_anonymous_identity("gl.php", 0, record)
    return code, output
end

local function run_assertions()
    -- Already decoded by the php_fpm_anonymous_identity parser: typed fields set,
    -- raw wrapper gone, only the native marker left to clear.
    local parsed = {
        auth_identity_type = "anonymous_ip",
        identity_opaque = true,
        log_kind = "native",
        docker_service = "php",
    }
    local code, output = run(parsed)
    assert_equal(code, 1, "natively parsed record was not accepted")
    assert_equal(output["identity_opaque"], true, "parsed opaque marker missing")
    assert_equal(output["log_kind"], nil, "parsed native marker leaked")
    assert_equal(output["docker_service"], "php", "parsed metadata was lost")

    -- Types cast lost somewhere upstream: the string form is normalized back to boolean.
    local parsed_string_bool = {
        auth_identity_type = "anonymous_ip",
        identity_opaque = "true",
        log_kind = "native",
    }
    code, output = run(parsed_string_bool)
    assert_equal(code, 1, "string-boolean record was not accepted")
    assert_equal(output["identity_opaque"], true, "string boolean was not normalized")

    -- json_default has already expanded this direct structured PHP record.
    local direct_json = {
        message = "Anonymous API identity resolved",
        context = { auth_identity_type = "anonymous_ip", identity_opaque = true },
        log_kind = "native",
        docker_service = "php",
    }
    code, output = run(direct_json)
    assert_equal(code, 1, "positive record was not sanitized")
    assert_equal(output["auth_identity_type"], "anonymous_ip", "direct identity type missing")
    assert_equal(output["identity_opaque"], true, "direct opaque marker missing")
    assert_equal(output["context"], nil, "direct nested context leaked")
    assert_equal(output["log_kind"], nil, "direct native marker leaked")
    assert_equal(output["message"], "Anonymous API identity resolved", "direct message was lost")
    assert_equal(output["docker_service"], "php", "standard metadata was lost")

    -- Any context key outside the allowlist -> untouched record.
    local unknown_direct_context = {
        message = "Anonymous API identity resolved",
        context = { auth_identity_type = "anonymous_ip", identity_opaque = true, remote_ip = "198.51.100.7" },
    }
    code, output = run(unknown_direct_context)
    assert_equal(code, 0, "unknown direct context was accepted")
    assert_equal(output["context"]["remote_ip"], "198.51.100.7", "unknown direct context changed")

    local other_direct_event = {
        message = "Other event",
        context = { auth_identity_type = "anonymous_ip", identity_opaque = true },
    }
    code, output = run(other_direct_event)
    assert_equal(code, 0, "nonmatching direct event was accepted")
    assert_equal(output["context"] ~= nil, true, "nonmatching direct event was changed")

    -- Legacy wrapper: handled by the parser filter in production. In Lua it is only
    -- the cjson fallback, which self-disables when the image ships no cjson.
    local wrapped = {
        log = 'NOTICE: PHP message: [debug] {"message":"Anonymous API identity resolved","context":{"auth_identity_type":"anonymous_ip","identity_opaque":true}}',
        log_kind = "native",
    }
    code, output = run(wrapped)
    if has_cjson then
        assert_equal(code, 1, "wrapped record was not sanitized with cjson present")
        assert_equal(output["auth_identity_type"], "anonymous_ip", "wrapped identity type missing")
        assert_equal(output["log"], nil, "wrapped raw log leaked")
    else
        assert_equal(code, 0, "wrapped record was changed without a JSON decoder")
        assert_equal(output["log"] ~= nil, true, "wrapped record lost its raw log")
    end

    -- Duplicate/escaped keys stay fail-closed on the cjson path.
    local duplicate = {
        log = 'NOTICE: PHP message: {"message":"Anonymous API identity resolved","context":{"auth_identity_type":"anonymous_ip","auth_identity_type":"anonymous_ip","identity_opaque":true}}',
    }
    code, output = run(duplicate)
    assert_equal(code, 0, "duplicate key record was accepted")
    assert_equal(output["log"] ~= nil, true, "duplicate key record was changed")

    local escaped = {
        log = 'NOTICE: PHP message: {"message":"Anonymous API identity resolved","context":{"note":"\\"auth_identity_type\\":\\"anonymous_ip\\"","identity_opaque":true}}',
    }
    code, output = run(escaped)
    assert_equal(code, 0, "escaped marker record was accepted")
    assert_equal(output["log"] ~= nil, true, "escaped marker record was changed")
end

function anonymous_identity_selftest(tag, ts, record)
    run_assertions()
    return 1, ts, { cnv143_assertions = "passed" }
end
