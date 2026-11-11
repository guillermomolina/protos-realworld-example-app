PROTOS ?= protos
PROTOS_ARGS ?= -Dpolyglot.engine.WarnInterpreterOnly=false
REALWORLD_SPEC ?= /tmp/realworld-spec
HOST ?= http://127.0.0.1:3000
# Persistent application data. The server receives ONLY this directory as its
# Filesystem authority (--allow-filesystem). Override per environment.
REALWORLD_DATA_DIR ?= var/realworld-data
JOURNAL_FILE = realworld.journal
LOCK_FILE = realworld.journal.lock
# Installed Python interpreter, used only as the external restart test driver.
PYTHON ?= python3

.PHONY: test serve init-data test-http test-http-lifecycle test-hurl \
	test-persistence test-restart

test:
	$(PROTOS) $(PROTOS_ARGS) --allow-entropy --allow-clock src/test-main.protos

# Preprovision persistent application data WITHOUT resetting existing data:
# the directory and an empty journal are created only when absent. An existing
# journal is never truncated, rewritten or replaced by this target.
init-data:
	@set -eu; \
	data_dir="$(REALWORLD_DATA_DIR)"; \
	test -n "$$data_dir" || { echo 'REALWORLD_DATA_DIR must not be empty' >&2; exit 2; }; \
	mkdir -p "$$data_dir"; \
	if [ -e "$$data_dir/$(JOURNAL_FILE)" ]; then \
		test -f "$$data_dir/$(JOURNAL_FILE)" || { echo 'journal path exists but is not a regular file' >&2; exit 2; }; \
		printf '%s\n' 'Existing journal kept unchanged.'; \
	else \
		( set -C; : > "$$data_dir/$(JOURNAL_FILE)" ); \
		printf '%s\n' 'Empty journal provisioned.'; \
	fi

# Durable service. Requires `make init-data` first. It never creates, resets or
# truncates the journal and never falls back to an in-memory store. Restarting
# with a DIFFERENT JWT key keeps all data but rejects previously issued tokens:
# set REALWORLD_JWT_KEY_BASE64URL to a stable key for restart authentication.
serve:
	@set -eu; \
	data_dir="$(REALWORLD_DATA_DIR)"; \
	test -n "$$data_dir" || { echo 'REALWORLD_DATA_DIR must not be empty' >&2; exit 2; }; \
	test -d "$$data_dir" || { echo 'missing data directory; run: make init-data' >&2; exit 2; }; \
	test -f "$$data_dir/$(JOURNAL_FILE)" || { echo 'missing journal; run: make init-data' >&2; exit 2; }; \
	if [ -e "$$data_dir/$(LOCK_FILE)" ]; then \
		echo 'journal lock present: a server is running, or a crashed server left it.' >&2; \
		echo 'See docs/persistence.md (stale-lock recovery); it is never removed automatically.' >&2; \
		exit 2; \
	fi; \
	if [ "$${REALWORLD_JWT_KEY_BASE64URL+x}" != x ]; then \
		generated_key=$$(openssl rand -base64 32); \
		REALWORLD_JWT_KEY_BASE64URL=$$(printf '%s' "$$generated_key" | tr '+/' '-_' | tr -d '=\n'); \
		printf '%s\n' 'Using a temporary development JWT key (changes on restart; old tokens stop working).'; \
	fi; \
	export REALWORLD_JWT_KEY_BASE64URL; \
	exec $(PROTOS) $(PROTOS_ARGS) --allow-network --allow-entropy --allow-clock \
		--allow-filesystem="$$data_dir" --service=service src/main.protos

# Pure in-memory persistence groups (codec, recovery, coordinator, injected
# File faults, durable HTTP) run inside `make test`; no Filesystem grant.
test-persistence: test

# Real process restart, SIGKILL, lock and corruption acceptance in a disposable
# temporary directory created by the harness. Requires an installed Protos
# runtime and Python 3 (test driver only); it never touches REALWORLD_DATA_DIR.
test-restart:
	PROTOS="$(PROTOS)" PROTOS_ARGS="$(PROTOS_ARGS)" $(PYTHON) src/tests/restart-integration.py

# Registers fixed accounts: run against a server started on a FRESH data
# directory (for example REALWORLD_DATA_DIR=var/http-test make init-data serve).
test-http:
	$(PROTOS) $(PROTOS_ARGS) --allow-network src/tests/native-http.protos

# Requires make serve in another terminal, plus Hurl and the external spec.
# Refresh the password-change token in a disposable copy of the suite.
test-hurl:
	@set -eu; \
	test_dir=$$(mktemp -d); \
	trap 'rm -rf "$$test_dir"' EXIT HUP INT TERM; \
	cp "$(REALWORLD_SPEC)/specs/api/hurl/"*.hurl "$$test_dir/"; \
	patch --batch --forward "$$test_dir/errors_auth.hurl" < src/tests/hurl-refresh-token.patch; \
	HOST="$(HOST)" bash "$(REALWORLD_SPEC)/specs/api/run-api-tests-hurl.sh" "$$test_dir/"*.hurl

# Self-contained Protos-only integration: ephemeral listener, parallel Workers,
# graceful drain and abort. Timeout bounds hangs when a regression deadlocks.
test-http-lifecycle:
	timeout 45s $(PROTOS) $(PROTOS_ARGS) --allow-network --service=service src/lifecycle-main.protos
