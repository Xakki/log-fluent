FLUENT_BIT_IMAGE ?= cr.fluentbit.io/fluent/fluent-bit:latest

.PHONY: fluent-bit-lua-probe fluent-bit-cnv143-test fluent-bit-config-check
fluent-bit-lua-probe:
	docker run --rm --network none \
		-v "$(CURDIR)/fluent-bit:/fluent-bit/etc:ro" \
		"$(FLUENT_BIT_IMAGE)" \
		/fluent-bit/bin/fluent-bit -c /fluent-bit/etc/tests/lua-decoder-probe.conf --dry-run

fluent-bit-cnv143-test:
	docker run --rm --network none \
		-v "$(CURDIR)/fluent-bit:/fluent-bit/etc:ro" \
		"$(FLUENT_BIT_IMAGE)" \
		/fluent-bit/bin/fluent-bit -c /fluent-bit/etc/tests/anonymous-identity-selftest.conf --dry-run

fluent-bit-config-check:
	docker run --rm --network none \
		-e TZ=UTC \
		-e HOST_IP=127.0.0.1 \
		-e HOST_NAME=fluent-bit-config-test \
		-e COMPOSE_PROJECT_NAME=fluent-bit-config-test \
		-e COMPOSE_PROFILES=test \
		-e GRAYLOG_HOST=graylog.invalid \
		-e GRAYLOG_URI=/gelf \
		-e GRAYLOG_PORT=443 \
		-v "$(CURDIR)/fluent-bit:/fluent-bit/etc:ro" \
		"$(FLUENT_BIT_IMAGE)" \
		/fluent-bit/bin/fluent-bit -c /fluent-bit/etc/fluent-bit.conf --dry-run
