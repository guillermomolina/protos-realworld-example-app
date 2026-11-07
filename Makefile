PROTOS ?= protos
PROTOS_ARGS ?= -Dpolyglot.engine.WarnInterpreterOnly=false

.PHONY: test
test:
	$(PROTOS) $(PROTOS_ARGS) run-tests.protos
