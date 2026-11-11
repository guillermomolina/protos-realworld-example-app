# Contributing to the Protos RealWorld example

Thanks for your interest. This repository is an independent example application; changes to the Protos language or Standard Library belong in [guillermomolina/protos](https://github.com/guillermomolina/protos).

## Start with an issue

For bugs, include your Protos version (the documented baseline is `0.3.459-SNAPSHOT`), operating system, reproducible request or Protos snippet, expected and actual behavior, and the relevant command's outcome. Never include signing keys, passwords, Authorization headers or unredacted credential records.

For proposed architectural changes, open an issue before undertaking a large refactor. The application deliberately prioritizes Protos-first implementations and RootActor-owned security/mutable state.

## Development checks

- `make test`: app module and endpoint tests.
- `make test-http`: authenticated TCP HTTP checks, requiring a separately running fresh `make serve`.
- `make test-http-lifecycle`: independent Worker/concurrency/shutdown checks.
- `make test-restart`: real restart, SIGKILL, lock and corruption checks in a disposable directory (Python 3 test driver, installed Protos).
- `make test-hurl`: requires Hurl and an external RealWorld checkout. The local command applies a documented token-refresh adjustment to a temporary copy of one Hurl file; do not represent its result as an unmodified official-suite pass.

Preserve the distinctions between local tests, externally adapted tests and upstream official conformance. Avoid application-specific cryptography, automatic ambient authority, and sharing mutable application state across Actors.

## Scope and licensing

Durable storage is implemented as an application-owned Protos journal (see docs/persistence.md) and still awaits validation; keep it free of database dependencies and ambient filesystem authority. Production deployment hardening is future work. This independent example application is distributed under the MIT license (see LICENSE).
