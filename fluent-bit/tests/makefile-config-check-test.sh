#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
fake_bin=$(mktemp -d)
trap 'rm -rf "$fake_bin"' EXIT

cat >"$fake_bin/docker" <<'SCRIPT'
#!/bin/sh
printf '%s\n' "${DOCKER_OUTPUT:-}"
exit "${DOCKER_STATUS:-0}"
SCRIPT
cat >"$fake_bin/timeout" <<'SCRIPT'
#!/bin/sh
shift
exec "$@"
SCRIPT
chmod +x "$fake_bin/docker" "$fake_bin/timeout"

if grep -Eq 'cjson|php_fpm_json_payload|has_ambiguous_json_keys' \
    "$repo_dir/fluent-bit/cleanup.lua"; then
    printf '%s\n' 'cleanup.lua still contains a wrapper JSON decoder' >&2
    exit 1
fi

if grep -Eqi 'anonymous[ _-]?identity|anonid|auth_identity_type|identity_opaque' \
    "$repo_dir/fluent-bit/cleanup.lua" \
    "$repo_dir/fluent-bit/parsers.conf" \
    "$repo_dir/fluent-bit/service.d/php.conf"; then
    printf '%s\n' 'shared Fluent Bit config contains an application-specific identity contract' >&2
    exit 1
fi

if PATH="$fake_bin:$PATH" DOCKER_STATUS=1 DOCKER_OUTPUT='configuration test is successful' \
    make -s -C "$repo_dir" fluent-bit-config-check \
    FLUENT_BIT_IMAGE=test-image RUN_LIMITS= RUN_MOUNT=; then
    printf '%s\n' 'config check accepted a failed container' >&2
    exit 1
fi

if PATH="$fake_bin:$PATH" DOCKER_STATUS=0 DOCKER_OUTPUT='[engine] started (pid=1)' \
    make -s -C "$repo_dir" fluent-bit-config-check \
    FLUENT_BIT_IMAGE=test-image RUN_LIMITS= RUN_MOUNT= \
    >/dev/null; then
    :
else
    printf '%s\n' 'config check rejected an initialized container' >&2
    exit 1
fi

printf '%s\n' 'makefile config-check contract: OK'