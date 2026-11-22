PROTOS ?= protos
# Optional execution arguments, forwarded unchanged. Empty by default: the
# default runner is the installed Native executable selected by PROTOS, whose
# FFM provider is integrated. For the portable JVM distribution, add e.g.
#   PROTOS_ARGS="-Dpolyglot.engine.WarnInterpreterOnly=false --foreign-provider-path /absolute/path/protos-ffm-provider.jar"
PROTOS_ARGS ?=
REALWORLD_SPEC ?= /tmp/realworld-spec
HOST ?= http://127.0.0.1:3000
# SQLite authorization, kept apart from PROTOS_ARGS. Select another library
# target with SQLITE_LIBRARY, or replace the grant entirely with SQLITE_ARGS.
SQLITE_LIBRARY ?= libsqlite3.so.0
SQLITE_ARGS ?= --allow-library sqlite3=$(SQLITE_LIBRARY)

.PHONY: test serve check-sqlite-args test-http test-http-lifecycle \
	test-sqlite test-sqlite-restart test-sqlite-failures \
	test-hurl test-hurl-official test-hurl-adjusted

# In-memory fixture suite. Needs no FFM provider and opens no native library.
test:
	$(PROTOS) $(PROTOS_ARGS) --allow-entropy --allow-clock src/test-main.protos

# The effective SQLite arguments, $(PROTOS_ARGS) followed by $(SQLITE_ARGS),
# must contain a nonempty authorization of the alias sqlite3, in either form:
#   --allow-library sqlite3=<library>   or   --allow-library=sqlite3=<library>
# Other aliases are allowed. No provider JAR is required or inserted here.
check-sqlite-args:
	@set -eu; found=0; previous=''; \
	for word in $(PROTOS_ARGS) $(SQLITE_ARGS); do \
		mapping=''; \
		if [ "$$previous" = --allow-library ]; then mapping="$$word"; fi; \
		case "$$word" in --allow-library=*) mapping="$${word#--allow-library=}" ;; esac; \
		if [ "$$previous" = --allow-library ] || [ -n "$$mapping" ]; then \
			case "$$mapping" in \
				sqlite3=*=*|sqlite3=|sqlite3) echo "malformed sqlite3 authorization: $$mapping" >&2; exit 2 ;; \
				sqlite3=?*) found=1 ;; \
				?*=?*) ;; \
				*) echo "malformed --allow-library mapping: $$mapping" >&2; exit 2 ;; \
			esac; \
		fi; \
		previous="$$word"; \
	done; \
	if [ "$$previous" = --allow-library ]; then echo 'empty --allow-library mapping' >&2; exit 2; fi; \
	if [ "$$found" != 1 ]; then echo 'SQLITE_ARGS (or PROTOS_ARGS) must include --allow-library sqlite3=<library>' >&2; exit 2; fi

# Persistent server. The host supplies the database path and a stable JWT key;
# nothing is generated here. Set REALWORLD_DB_CREATE=1 only to initialize a
# database file that does not exist yet.
serve: check-sqlite-args
	@set -eu; \
	if [ -z "$${REALWORLD_DB_PATH:-}" ]; then \
		echo 'REALWORLD_DB_PATH must name the SQLite database file' >&2; exit 2; \
	fi; \
	if [ -z "$${REALWORLD_JWT_KEY_BASE64URL:-}" ]; then \
		echo 'REALWORLD_JWT_KEY_BASE64URL must contain the stable Base64url signing key' >&2; exit 2; \
	fi; \
	exec $(PROTOS) $(PROTOS_ARGS) $(SQLITE_ARGS) --allow-network --allow-entropy --allow-clock --service=service src/main.protos

# Requires a running server (make serve) on a fresh, disposable database.
test-http:
	$(PROTOS) $(PROTOS_ARGS) --allow-network src/tests/native-http.protos

# Repository, transaction and authentication tests against real SQLite files
# in a fresh temporary directory.
test-sqlite: check-sqlite-args
	@set -eu; \
	test_dir=$$(mktemp -d); \
	trap 'rm -rf "$$test_dir"' EXIT HUP INT TERM; \
	$(PROTOS) $(PROTOS_ARGS) $(SQLITE_ARGS) --allow-entropy --allow-clock src/sqlite-test-main.protos "$$test_dir"

# Persistence across independent processes, SIGKILL recovery and HTTP restart.
# Uses port 3000: no other server may be running.
test-sqlite-restart: check-sqlite-args
	PROTOS='$(PROTOS)' PROTOS_ARGS='$(PROTOS_ARGS)' SQLITE_ARGS='$(SQLITE_ARGS)' bash src/tests/test-sqlite-processes.sh restart

# Authorization denial, external-provider absence (JVM mode only), lock
# contention, invalid schema and corruption.
test-sqlite-failures: check-sqlite-args
	PROTOS='$(PROTOS)' PROTOS_ARGS='$(PROTOS_ARGS)' SQLITE_ARGS='$(SQLITE_ARGS)' bash src/tests/test-sqlite-processes.sh failures

# Hurl targets require a running server on a fresh database, Hurl and the
# external spec checkout. test-hurl is the official, unmodified suite.
test-hurl: test-hurl-official

test-hurl-official:
	HOST="$(HOST)" bash "$(REALWORLD_SPEC)/specs/api/run-api-tests-hurl.sh" "$(REALWORLD_SPEC)/specs/api/hurl/"*.hurl

# Compatibility variant, not official conformance: a disposable copy of the
# suite reuses the token returned by the password change, because the
# application revokes the previous token.
test-hurl-adjusted:
	@set -eu; \
	test_dir=$$(mktemp -d); \
	trap 'rm -rf "$$test_dir"' EXIT HUP INT TERM; \
	cp "$(REALWORLD_SPEC)/specs/api/hurl/"*.hurl "$$test_dir/"; \
	patch --batch --forward --fuzz=0 "$$test_dir/errors_auth.hurl" < src/tests/hurl-refresh-token.patch; \
	HOST="$(HOST)" bash "$(REALWORLD_SPEC)/specs/api/run-api-tests-hurl.sh" "$$test_dir/"*.hurl

# Self-contained Protos-only integration: ephemeral listener, parallel Workers,
# graceful drain and abort. Timeout bounds hangs when a regression deadlocks.
test-http-lifecycle:
	timeout 45s $(PROTOS) $(PROTOS_ARGS) --allow-network --service=service src/lifecycle-main.protos
