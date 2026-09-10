# Test harness. NEVER use --dry-run here: it validates the config text only and does
# not load Lua scripts or initialize filters, so a broken script still reports
# "configuration test is successful" (that is how the missing-cjson crash reached prod).
# Every one-off container: --rm + explicit mem/cpu limits.
FLUENT_BIT_IMAGE ?= cr.fluentbit.io/fluent/fluent-bit:5.0.9
RUN_LIMITS       ?= --memory 128m --cpus 0.5
RUN_MOUNT        ?= -v "$(CURDIR)/fluent-bit:/fluent-bit/etc:ro"

.PHONY: test fluent-bit-cnv143-test fluent-bit-anonid-pipeline-test fluent-bit-config-check

test: fluent-bit-cnv143-test fluent-bit-anonid-pipeline-test fluent-bit-config-check ## Run every fluent-bit check

# Unit assertions for the sanitize_php_fpm_anonymous_identity callback. stdin input +
# Exit_On_Eof: the process ends by itself; a failed assertion aborts filter init instead
# of emitting the marker record.
fluent-bit-cnv143-test: ## Lua allowlist unit test
	@output=$$(printf '{"message":"synthetic"}\n' | docker run --rm -i --network none \
		$(RUN_LIMITS) $(RUN_MOUNT) "$(FLUENT_BIT_IMAGE)" \
		-c /fluent-bit/etc/tests/anonymous-identity-selftest.conf 2>&1); \
	case "$$output" in \
		*'cnv143_assertions'*) echo "cnv143 selftest: OK" ;; \
		*) printf '%s\n' "$$output" >&2; exit 1 ;; \
	esac

# End-to-end: real parsers.conf + parser filter + Lua allowlist over three synthetic
# records (see the conf header). Runs until the timeout — dummy inputs never EOF.
fluent-bit-anonid-pipeline-test: ## Anonymous-identity pipeline test
	@output=$$(timeout 6 docker run --rm --network none $(RUN_LIMITS) $(RUN_MOUNT) \
		"$(FLUENT_BIT_IMAGE)" -c /fluent-bit/etc/tests/anonymous-identity-pipeline.conf 2>&1); \
	fail() { printf '%s\n%s\n' "$$1" "$$output" >&2; exit 1; }; \
	[ "$$(printf '%s\n' "$$output" | grep -c '"auth_identity_type":"anonymous_ip"')" = 2 ] \
		|| fail "expected exactly 2 sanitized records"; \
	printf '%s\n' "$$output" | grep -q '"identity_opaque":true' || fail "identity_opaque is not a boolean"; \
	printf '%s\n' "$$output" | grep -q '"log":"NOTICE: PHP message.*remote_ip' \
		|| fail "record with an extra context key must pass through untouched"; \
	printf '%s\n' "$$output" | grep '"auth_identity_type"' | grep -q 'remote_ip' \
		&& fail "context leaked into a sanitized record"; \
	printf '%s\n' "$$output" | grep '"auth_identity_type"' | grep -q 'log_kind' \
		&& fail "native marker leaked into a sanitized record"; \
	echo "anonid pipeline: OK"

# Boot the production config for real (tmpfs for the tail state DB; tail paths are
# absent here, their warnings are expected). Fails on any init error.
fluent-bit-config-check: ## Boot the production config
	@output=$$(timeout 8 docker run --rm --network none $(RUN_LIMITS) $(RUN_MOUNT) \
		--tmpfs /var/lib/fluent-bit \
		-e TZ=UTC -e HOST_IP=127.0.0.1 -e HOST_NAME=fluent-bit-config-test \
		-e COMPOSE_PROJECT_NAME=fluent-bit-config-test -e COMPOSE_PROFILES=test \
		-e GRAYLOG_HOST=graylog.invalid -e GRAYLOG_URI=/gelf -e GRAYLOG_PORT=443 \
		"$(FLUENT_BIT_IMAGE)" -c /fluent-bit/etc/fluent-bit.conf 2>&1); \
	case "$$output" in \
		*"initialization failed"*|*"invalid lua content"*|*"aborting"*) printf '%s\n' "$$output" >&2; exit 1 ;; \
		*) echo "config check: OK" ;; \
	esac
