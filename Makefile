# Test harness. NEVER use --dry-run here: it validates the config text only and does
# not load Lua scripts or initialize filters, so a broken script still reports
# "configuration test is successful" (that is how the missing-cjson crash reached prod).
# Every one-off container: --rm + explicit mem/cpu limits.
FLUENT_BIT_IMAGE ?= harbor.xakki.ru/external/fluent-bit:5
RUN_LIMITS       ?= --memory 128m --cpus 0.5
RUN_MOUNT        ?= -v "$(CURDIR)/fluent-bit:/fluent-bit/etc:ro"

# Project-specific third-party image: mirrored by `make harbor-pub` into the shared Harbor
# project `library`. docker-fluent.yml reads LOGROTATE_IMAGE.
HARBOR_REGISTRY ?= harbor.xakki.ru
HARBOR_PROJECT  ?= library
LOGROTATE_SRC   ?= blacklabelops/logrotate:latest
LOGROTATE_DST   ?= $(HARBOR_REGISTRY)/$(HARBOR_PROJECT)/logrotate:latest

.PHONY: test fluent-bit-harbor-test fluent-bit-host-nginx-testfluent-bit-nginx-pipeline-test fluent-bit-nginx-utf8-test fluent-bit-php-json-pipeline-test fluent-bit-config-check fluent-bit-contract-test harbor-pub

test: fluent-bit-harbor-test fluent-bit-host-nginx-testfluent-bit-nginx-pipeline-test fluent-bit-nginx-utf8-test fluent-bit-php-json-pipeline-test fluent-bit-config-check fluent-bit-contract-test ## Run every fluent-bit check

# Invalid UTF-8 in a request is percent-encoded, valid multibyte text stays intact.
fluent-bit-nginx-utf8-test: ## invalid UTF-8 bytes must not be dropped or mangled
	@output=$$(timeout 8 docker run --rm --network none $(RUN_LIMITS) $(RUN_MOUNT) \
		"$(FLUENT_BIT_IMAGE)" -c /fluent-bit/etc/tests/nginx-utf8.conf 2>&1); \
	fail() { printf '%s\n%s\n' "$$1" "$$output" >&2; exit 1; }; \
	[ "$$(printf '%s\n' "$$output" | grep -c '"short_message"')" = 3 ] || fail "expected 3 records"; \
	printf '%s\n' "$$output" | grep -q '"request_uri":"/a?q=%FF%FE%D0"' || fail "invalid request bytes were not percent-encoded"; \
	printf '%s\n' "$$output" | grep -q '"user_agent":"UA %C3( bad"' || fail "invalid user-agent byte was not percent-encoded"; \
	printf '%s\n' "$$output" | grep -qF '"user_agent":"\u0422\u0435\u0441\u0442 \ud83d\ude00"' || fail "valid multibyte text was altered"; \
	echo "nginx utf8: OK"

# Harbor tail: only warning and above survives, level derived from each component's native shape.
fluent-bit-harbor-test: ## harbor level derivation and warning-and-above filter test
	@output=$$(timeout 10 docker run --rm --network none $(RUN_LIMITS) $(RUN_MOUNT) \
		"$(FLUENT_BIT_IMAGE)" -c /fluent-bit/etc/tests/harbor.conf 2>&1); \
	fail() { printf '%s\n%s\n' "$$1" "$$output" >&2; exit 1; }; \
	[ "$$(printf '%s\n' "$$output" | grep -c '"docker_project":"harbor"')" = 5 ] || fail "expected 5 surviving harbor records"; \
	printf '%s\n' "$$output" | grep '"docker_service":"core"' | grep -q '"level_name":"ERROR"' || fail "go [ERROR] was not kept"; \
	auth=$$(printf '%s\n' "$$output" | grep 'failed to authenticate user'); \
	printf '%s\n' "$$auth" | grep -q '"file":"/server/middleware/security/basic_auth.go:72"' || fail "harbor file:line was not parsed"; \
	printf '%s\n' "$$auth" | grep -q '"client_ip":"fd00:c6::1, 10.210.0.43"' || fail "harbor client_ip was not parsed"; \
	printf '%s\n' "$$auth" | grep -q '"request_id":"977e0d44-b9f3-4f22-9175-e8a459c34434"' || fail "harbor request_id was not parsed"; \
	printf '%s\n' "$$auth" | grep -q '"user_agent":"curl/8.14.1"' || fail "harbor user_agent was not parsed"; \
	printf '%s\n' "$$auth" | grep -q "\"message\":\"failed to authenticate user:log-test-nonexistent, error:Failed to authenticate user, due to error 'Invalid credentials'\"" || fail "harbor message was not stripped to the text"; \
	printf '%s\n' "$$auth" | grep -q '"datetime":"2026-11-04T14:26:19Z"' || fail "harbor event time was not parsed"; \
	printf '%s\n' "$$output" | grep '"message":"response completed with error"' | grep -q '"level_name":"ERROR"' || fail "registry msg was not extracted"; \
	printf '%s\n' "$$output" | grep -q '"level_name":"WARNING"' || fail "go [WARNING] was not kept"; \
	printf '%s\n' "$$output" | grep '"docker_service":"registry"' | grep -q '"level_name":"ERROR"' || fail "registry level=error was not kept"; \
	printf '%s\n' "$$output" | grep '"docker_service":"proxy"' | grep -q '"level_name":"ERROR"' || fail "5xx access line was not kept as ERROR"; \
	if printf '%s\n' "$$output" | grep -q 'payload ok\|authorized request\|GET / HTTP'; then fail "info noise was not dropped"; fi; \
	echo "harbor: OK"

# Host nginx files (access JSON + error text) tailed into the same nginx path.
fluent-bit-host-nginx-test: ## host nginx tail test
	@output=$$(timeout 10 docker run --rm --network none $(RUN_LIMITS) $(RUN_MOUNT) \
		"$(FLUENT_BIT_IMAGE)" -c /fluent-bit/etc/tests/host-nginx.conf 2>&1); \
	fail() { printf '%s\n%s\n' "$$1" "$$output" >&2; exit 1; }; \
	[ "$$(printf '%s\n' "$$output" | grep -c '"docker_service":"host-nginx"')" = 2 ] || fail "expected 2 host-nginx records"; \
	printf '%s\n' "$$output" | grep '"request_uri":"/go"' | grep -q '"remote_addr":"1.2.3.4"' || fail "host access line was not parsed"; \
	printf '%s\n' "$$output" | grep '"request_uri":"/x"' | grep -q '"remote_addr":"5.6.7.8"' || fail "host error context was not parsed"; \
	printf '%s\n' "$$output" | grep '"request_uri":"/go"' | grep -q '"log_source":"stdout"' || fail "host access must look like stdout"; \
	printf '%s\n' "$$output" | grep '"request_uri":"/x"' | grep -q '"log_source":"stderr"' || fail "host error must look like stderr"; \
	if printf '%s\n' "$$output" | grep -q '"file":'; then fail "tail Path_Key leaked"; fi; \
	echo "host nginx: OK"

# End-to-end nginx normalization: legacy keys, request_line, numeric coercion, noise drop.
fluent-bit-nginx-pipeline-test: ## nginx access/error normalization and noise filter test
	@output=$$(timeout 6 docker run --rm --network none $(RUN_LIMITS) $(RUN_MOUNT) \
		"$(FLUENT_BIT_IMAGE)" -c /fluent-bit/etc/tests/nginx-pipeline.conf 2>&1); \
	fail() { printf '%s\n%s\n' "$$1" "$$output" >&2; exit 1; }; \
	[ "$$(printf '%s\n' "$$output" | grep -c '"short_message"')" = 5 ] \
		|| fail "expected 5 surviving records (3 access + 1 failing system call + 1 error)"; \
	printf '%s\n' "$$output" | grep '"request_uri":"/orders"' | grep -q '"user_agent":"UA/1"' \
		|| fail "legacy http_user_agent was not renamed"; \
	printf '%s\n' "$$output" | grep '"request_uri":"/orders"' | grep -q '"request_host":"a.example"' \
		|| fail "legacy http_host was not renamed to request_host"; \
	printf '%s\n' "$$output" | grep '"request_uri":"/orders"' | grep -q '"request_time":0.123' \
		|| fail "request_time was not coerced to a number"; \
	printf '%s\n' "$$output" | grep '"request_uri":"/orders"' | grep -q '"upstream_response_time":0.02' \
		|| fail "multi-value upstream time was not reduced to the last value"; \
	printf '%s\n' "$$output" | grep '"request_uri":"/api/v1/convert?x=1"' | grep -q '"request_method":"POST"' \
		|| fail "request_line was not split into request_method"; \
	if printf '%s\n' "$$output" | grep -q 'command-pending'; then fail "healthy system endpoint was not dropped"; fi; \
	printf '%s\n' "$$output" | grep '"request_uri":"/gelf"' | grep -q '"status":502' \
		|| fail "failing system endpoint was dropped"; \
	if printf '%s\n' "$$output" | grep -q 'SIGCHLD'; then fail "notice-level error was not dropped"; fi; \
	if printf '%s\n' "$$output" | grep -q 'buffered to a temporary file'; then fail "buffering noise was not dropped"; fi; \
	printf '%s\n' "$$output" | grep '"request_uri":"/x"' | grep -q '"request_method":"GET"' \
		|| fail "error-log request context was not parsed"; \
	if printf '%s\n' "$$output" | grep -q '"time_local"'; then fail "time_local duplicate was not removed"; fi; \
	printf '%s\n' "$$output" | grep '"request_uri":"/x"' | grep -q '"remote_addr":"1.2.3.4"' \
		|| fail "error-log client was not renamed to remote_addr"; \
	if printf '%s\n' "$$output" | grep -q '"client"'; then fail "error-log client duplicate remained"; fi; \
	if printf '%s\n' "$$output" | grep '"request_uri":"/x"' | grep -q '"server_name"'; then fail "server_name equal to host was kept"; fi; \
	if printf '%s\n' "$$output" | grep -q 'realip_remote_addr'; then fail "realip_remote_addr was not dropped"; fi; \
	echo "nginx pipeline: OK"

harbor-pub: ## Mirror the logrotate image (all platforms) into Harbor library; needs docker login
	docker buildx imagetools create -t $(LOGROTATE_DST) $(LOGROTATE_SRC)

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
