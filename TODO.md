# TODO — RealWorld backend in Protos

## Implementation prepared (not yet validated)

SQLite persistence is implemented in code, with SQLite as the only source of
truth. None of the checks below has been run yet. This section describes the
code that exists; it does not record a validation.

- `SqliteDatabase`: explicit open/create, WAL, `synchronous=FULL`, foreign
  keys, busy timeout, schema version 1, structural/integrity checks,
  transactions and handling of an uncertain COMMIT.
- `SqliteStore` and `SqliteCredentials`: the production repositories.
  Identity and credentials share one transaction.
- `AuthStore`/`Auth`: the persistent credential repository is selected at
  construction. Update tokens are prepared before the commit.
- `main.protos`: the startup order and fail-closed checks, close on shutdown,
  and stopping service when the connection becomes unusable.
- Tests prepared: `make test-sqlite`, `make test-sqlite-restart`,
  `make test-sqlite-failures`.

## Validation pending

- [ ] `make test` still passes with the in-memory fixtures after the shared
  `AuthStore`/`Auth`/`IdentityStore`/`ContentStore` changes.
- [ ] `make test-sqlite`: repositories, transactions, rollback and persistent
  authentication against real SQLite.
- [ ] Restart validation, `make test-sqlite-restart`: data, IDs, credentials
  and token revocation across independent processes and a server restart.
- [ ] Recovery after errors and crashes, `make test-sqlite-restart` and
  `make test-sqlite-failures`: SIGKILL during an open transaction and after a
  confirmed commit, lock contention, unknown or incompatible schema, foreign
  content, missing authorization or provider, a corrupt file.
- [ ] `make test-http` and `make test-http-lifecycle` against the persistent
  server.
- [ ] Native Image execution (Protos `0.4.192-SNAPSHOT` or newer with I170)
  using the integrated FFM provider, without a provider JAR or JVM.
- [ ] SQLite authorization through `--allow-library sqlite3=…` (both CLI
  spellings) under Native.
- [ ] Persistent reopen and WAL behavior under Native.
- [ ] SIGKILL and recovery under Native.
- [ ] HTTP restart and JWT revocation under Native.
- [ ] Absent `sqlite3` authorization rejected under Native.
- [ ] JVM compatibility with the external provider
  (`PROTOS_ARGS="--foreign-provider-path …"`).
- [ ] Missing external provider detected in JVM mode (the `no-ffm-provider`
  scenario; not applicable to integrated-provider runners).
- [ ] Official Hurl conformance, `make test-hurl` (unmodified suite), still to
  be verified. Report `make test-hurl-adjusted` separately, as a compatibility
  variant only.

## Optional work for production deployment

These tasks are needed for a production deployment, not to run the learning
example locally:

- [ ] Configure HTTPS and deployment supervision.
- [ ] Add request/rate limits appropriate to the deployment. The existing HTTP
  request-body size limit is already implemented.
- [ ] Define secure storage and rotation of the production JWT signing key.
- [ ] Define database backup/restore procedures, including the WAL companion
  files.
- [ ] Connect process shutdown signals to graceful drain. The manual `quit`
  command and the drain/abort lifecycle already exist.
- [ ] Consider SQL-side filtering and pagination if article volume grows. The
  current repository materializes rows and applies the shared Protos query
  algorithm.

Using `std:http/host` is a possible future refactor, not a missing feature or a
requirement for completing this example.

## Hurl compatibility note

`make test-hurl-adjusted` applies the tracked token-refresh patch to a temporary
copy of the external tests. After a password change, the next request uses the
token returned by that change, because the application revokes the previous
token. This keeps the token-revocation requirement intact and does not modify
the external checkout. A result from this variant is not an official-suite
result.
