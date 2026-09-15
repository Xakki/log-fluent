# Test harness. NEVER use --dry-run here: it validates the config text only and does
# not load Lua scripts or initialize filters, so a broken script still reports
# "configuration test is successful" (that is how the missing-cjson crash reached prod).
# Every one-off container: --rm + explicit mem/cpu limits.
FLUENT_BIT_IMAGE ?= cr.fluentbit.io/fluent/fluent-bit:5.0.9
RUN_LIMITS       ?= --memory 128m --cpus 0.5
RUN_MOUNT        ?= -v "$(CURDIR)/fluent-bit:/fluent-bit/etc:ro"

.PHONY: test fluent-bit-php-json-pipeline-test fluent-bit-config-check fluent-bit-contract-test

test: fluent-bit-php-json-pipeline-test fluent-bit-config-check fluent-bit-contract-test ## Run every fluent-bit check

# End-to-end: real parsers.conf + production PHP filters over four synthetic
# records (see the conf header). Runs until the timeout — dummy inputs never EOF.
fluent-bit-php-json-pipeline-test: ## Generic PHP-FPM wrapped JSON pipeline test
	@output=$$(timeout 6 docker run --rm --network none $(RUN_LIMITS) $(RUN_MOUNT) \
		"$(FLUENT_BIT_IMAGE)" -c /fluent-bit/etc/tests/php-fpm-json-pipeline.conf 2>&1); \
	fail() { printf '%s\n%s\n' "$$1" "$$output" >&2; exit 1; }; \
	wrapped=$$(printf '%s\n' "$$output" | grep '"short_message":"Wrapped JSON event"' || true); \
	direct=$$(printf '%s\n' "$$output" | grep '"short_message":"Direct JSON event"' || true); \
	[ "$$(printf '%s\n' "$$wrapped" | grep -c '"short_message"')" = 1 ] \
		|| fail "expected one decoded wrapped JSON event"; \
	printf '%s\n' "$$wrapped" | grep -q '"context_safe_flag":true' \
		|| fail "wrapped JSON boolean field was not preserved"; \
	printf '%s\n' "$$wrapped" | grep -q '"context_sequence":7' \
		|| fail "wrapped JSON integer field was not preserved"; \
	printf '%s\n' "$$wrapped" | grep -q '"level_name":"INFO"' \
		|| fail "wrapped JSON level was not preserved"; \
	printf '%s\n' "$$wrapped" | grep -q '"log_kind"' \
		&& fail "decoded wrapped JSON remained marked native"; \
	printf '%s\n' "$$wrapped" | grep -q '"log"' \
		&& fail "decoded wrapped JSON retained its raw envelope"; \
	printf '%s\n' "$$direct" | grep -q '"context_safe_flag":true' \
		|| fail "direct JSON behavior regressed"; \
	[ "$$(printf '%s\n' "$$output" | grep -c '"short_message":"NOTICE: PHP message: not-json"')" = 1 ] \
		|| fail "non-JSON PHP-FPM output was not preserved"; \
	printf '%s\n' "$$output" | grep '"short_message":"NOTICE: PHP message: not-json"' | grep -q '"log_kind":"native"' \
		|| fail "non-JSON PHP-FPM output lost its native marker"; \
	printf '%s\n' "$$output" | grep '"short_message":"{not-json}"' | grep -q '"log_kind":"native"' \
		|| fail "malformed wrapped JSON was not preserved as native output"; \
	echo "php json pipeline: OK"

fluent-bit-contract-test: ## Test fail-closed shell and native parser contracts
	@./fluent-bit/tests/makefile-config-check-test.sh

# Boot the production config for real (tmpfs for the tail state DB; tail paths are
# absent here, their warnings are expected). Fails on any init error.
fluent-bit-config-check: ## Boot the production config
	@output=$$(timeout 8 docker run --rm --network none $(RUN_LIMITS) $(RUN_MOUNT) \
		--tmpfs /var/lib/fluent-bit \
		-e TZ=UTC -e HOST_IP=127.0.0.1 -e HOST_NAME=fluent-bit-config-test \
		-e COMPOSE_PROJECT_NAME=fluent-bit-config-test -e COMPOSE_PROFILES=test \
		-e GRAYLOG_HOST=graylog.invalid -e GRAYLOG_URI=/gelf -e GRAYLOG_PORT=443 \
		"$(FLUENT_BIT_IMAGE)" -v -c /fluent-bit/etc/fluent-bit.conf 2>&1); \
	status=$$?; \
	initialized=$$(printf '%s\n' "$$output" | grep -cE '\[engine\] started \(pid=[0-9]+\)|\[input:[^]]+\] (read error|initialized)' || true); \
	if printf '%s\n' "$$output" | grep -Eq 'initialization failed|invalid lua content|aborting'; then printf '%s\n' "$$output" >&2; exit 1; fi; \
	if [ "$$status" -ne 0 ] && [ "$$status" -ne 124 ]; then printf '%s\n' "$$output" >&2; exit 1; fi; \
	if [ "$$initialized" -eq 0 ]; then printf '%s\n' "$$output" >&2; exit 1; fi; \
	echo "config check: OK"
