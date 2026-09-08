-- Synthetic privacy tests run during Fluent Bit --dry-run without live logs.
dofile("/fluent-bit/etc/cleanup.lua")

local function assert_equal(actual, expected, label)
    if actual ~= expected then
        error(label)
    end
end

local function run(record)
    local code, _, output = sanitize_php_fpm_anonymous_identity("gl.php", 0, record)
    return code, output
end

local positive = {
    log = 'NOTICE: PHP message: [debug] {"message":"Anonymous API identity resolved","context":{"auth_identity_type":"anonymous_ip","identity_opaque":true,"remote_ip":"198.51.100.7"}}',
    log_kind = "native",
}
local code, output = run(positive)
assert_equal(code, 1, "positive record was not sanitized")
assert_equal(output["auth_identity_type"], "anonymous_ip", "missing identity type")
assert_equal(output["identity_opaque"], true, "missing opaque marker")
assert_equal(output["log"], nil, "raw wrapper leaked")
assert_equal(output["log_kind"], nil, "native marker leaked")
assert_equal(output["remote_ip"], nil, "context field leaked")

local duplicate = {
    log = 'NOTICE: PHP message: {"message":"Anonymous API identity resolved","context":{"auth_identity_type":"anonymous_ip","auth_identity_type":"anonymous_ip","identity_opaque":true}}',
}
code, output = run(duplicate)
assert_equal(code, 0, "duplicate key record was accepted")
assert_equal(output["log"] ~= nil, true, "duplicate key record was changed")

local duplicate_message = {
    log = 'NOTICE: PHP message: {"message":"Other event","message":"Anonymous API identity resolved","context":{"auth_identity_type":"anonymous_ip","identity_opaque":true}}',
}
code, output = run(duplicate_message)
assert_equal(code, 0, "duplicate message record was accepted")
assert_equal(output["log"] ~= nil, true, "duplicate message record was changed")

local duplicate_context = {
    log = 'NOTICE: PHP message: {"message":"Anonymous API identity resolved","context":{"auth_identity_type":"wrong","identity_opaque":false},"context":{"auth_identity_type":"anonymous_ip","identity_opaque":true}}',
}
code, output = run(duplicate_context)
assert_equal(code, 0, "duplicate context record was accepted")
assert_equal(output["log"] ~= nil, true, "duplicate context record was changed")

local escaped = {
    log = 'NOTICE: PHP message: {"message":"Anonymous API identity resolved","context":{"note":"\\\"auth_identity_type\\\":\\\"anonymous_ip\\\"","identity_opaque":true}}',
}
code, output = run(escaped)
assert_equal(code, 0, "escaped marker record was accepted")
assert_equal(output["log"] ~= nil, true, "escaped marker record was changed")

local direct_json = {
    log = '{"message":"Anonymous API identity resolved","context":{"auth_identity_type":"anonymous_ip","identity_opaque":true}}',
}
code, output = run(direct_json)
assert_equal(code, 0, "direct JSON record was changed")
assert_equal(output["log"] ~= nil, true, "direct JSON record lost raw log")

local nonmatching_wrapper = {
    log = 'NOTICE: PHP message: {"message":"Other event","context":{"auth_identity_type":"anonymous_ip","identity_opaque":true}}',
}
code, output = run(nonmatching_wrapper)
assert_equal(code, 0, "nonmatching wrapper was changed")
assert_equal(output["log"] ~= nil, true, "nonmatching wrapper lost raw log")

function anonymous_identity_selftest(tag, ts, record)
    return 0, ts, record
end
