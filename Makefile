PROTOS ?= protos
PROTOS_ARGS ?= -Dpolyglot.engine.WarnInterpreterOnly=false

.PHONY: test serve test-http

test:
	$(PROTOS) $(PROTOS_ARGS) run-tests.protos

serve:
	$(PROTOS) $(PROTOS_ARGS) --allow-network --service=service server.protos

test-http:
	$(PROTOS) $(PROTOS_ARGS) --allow-network tests/native-http.protos
