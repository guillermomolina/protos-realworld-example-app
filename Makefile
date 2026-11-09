PROTOS ?= protos
PROTOS_ARGS ?= -Dpolyglot.engine.WarnInterpreterOnly=false
REALWORLD_SPEC ?= /tmp/realworld-spec
HOST ?= http://127.0.0.1:3000

.PHONY: test serve test-http test-http-lifecycle test-hurl

test:
	$(PROTOS) $(PROTOS_ARGS) --allow-entropy --allow-clock src/test-main.protos

serve:
	@set -eu; \
	if [ "$${REALWORLD_JWT_KEY_BASE64URL+x}" != x ]; then \
		generated_key=$$(openssl rand -base64 32); \
		REALWORLD_JWT_KEY_BASE64URL=$$(printf '%s' "$$generated_key" | tr '+/' '-_' | tr -d '=\n'); \
		printf '%s\n' 'Using a temporary development JWT key (changes on restart).'; \
	fi; \
	export REALWORLD_JWT_KEY_BASE64URL; \
	exec $(PROTOS) $(PROTOS_ARGS) --allow-network --allow-entropy --allow-clock --service=service src/main.protos

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
