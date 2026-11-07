PROTOS ?= protos
PROTOS_ARGS ?= -Dpolyglot.engine.WarnInterpreterOnly=false

.PHONY: test serve test-http test-http-lifecycle

test:
	$(PROTOS) $(PROTOS_ARGS) run-tests.protos

serve:
	$(PROTOS) $(PROTOS_ARGS) --allow-network --service=service server.protos

test-http:
	$(PROTOS) $(PROTOS_ARGS) --allow-network tests/native-http.protos

# Self-contained Protos-only integration: ephemeral listener, parallel Workers,
# graceful drain and abort. Timeout bounds hangs when a regression deadlocks.
test-http-lifecycle:
	timeout 45s $(PROTOS) $(PROTOS_ARGS) --allow-network --service=service native-http-lifecycle.protos
