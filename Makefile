PROTOS ?= protos
PROTOS_ARGS ?= -Dpolyglot.engine.WarnInterpreterOnly=false

.PHONY: test serve test-http test-http-lifecycle

test:
	$(PROTOS) $(PROTOS_ARGS) src/test-main.protos

serve:
	$(PROTOS) $(PROTOS_ARGS) --allow-network --service=service src/main.protos

test-http:
	$(PROTOS) $(PROTOS_ARGS) --allow-network src/tests/native-http.protos

# Self-contained Protos-only integration: ephemeral listener, parallel Workers,
# graceful drain and abort. Timeout bounds hangs when a regression deadlocks.
test-http-lifecycle:
	timeout 45s $(PROTOS) $(PROTOS_ARGS) --allow-network --service=service src/lifecycle-main.protos
