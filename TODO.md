# TODO — RealWorld backend in Protos

## Current validated state

- Source layout: `src/main.protos` serves the app, `src/app/` holds its
  modules, and `src/tests/` holds the test corpus. `src/test-main.protos`
  and `src/lifecycle-main.protos` keep cross-directory imports inside the
  direct-file SOURCE root; no `.protos` files remain at repository root.

- Public routes: tags, article listing and details, profiles, and comments.
- Conduit-compatible JSON errors for missing profiles/articles (404) and unauthed protected routes (401); token validation and write operations remain unimplemented.
- Public article filtering by `tag`, `author`, and `favorited`, including sorting and pagination.
- Favorites are populated through test fixtures; authenticated favorite mutations are not implemented.
- Router and HTTP/1.1 unit tests use an in-memory duplex; the native two-Worker service has also passed real TCP requests (HTTP 200, 401, 404, 422).
- Workers snapshot complete HTTP requests for RootActor routing: raw target Bytes, method, version, ordered headers and decoded body Bytes; `std:http/server` enforces a 1 MiB request-body cap (HTTP 413). Application handlers do not interpret credentials or mutation bodies yet.
- Pure JSON request validation for future registration, login, article creation and comment creation: strict UTF-8, named object envelope, non-empty required strings, optional article tagList type. The helpers are not wired to public mutation routes.
- `make test` passed in a previous reported local run; `make test-http` passed on Protos `0.3.452-SNAPSHOT` (2026-11-07). The official RealWorld suite has not been run.

`make serve` starts a native TCP listener on `127.0.0.1:3000` using `--allow-network --service=service`. Two Worker Actors accept delegated TCP connections and request application responses from the RootActor, which alone owns `MemoryStore`. `make test-http` exercises the running service with a native Protos HTTP client. Authentication, durable storage, bounded-lifecycle hosting and graceful shutdown are still missing.

## Protos dependencies

- [x] [D247 — Network permission for the Native/JVM CLI](https://github.com/guillermomolina/protos/issues/1073): closed; the explicit CLI grant and native HTTP service have been verified without an external JDK.
- [x] [BUG035 — Standard Bytes Actor transfer](https://github.com/guillermomolina/protos/issues/1081): Protos `0.3.452-SNAPSHOT` passed the application's two-Worker native HTTP integration test.
- [ ] [D243 — Secure entropy](https://github.com/guillermomolina/protos/issues/1069).
- [ ] [D244 — HMAC and key handling](https://github.com/guillermomolina/protos/issues/1070).
- [ ] [D245 — Password hashing and verification](https://github.com/guillermomolina/protos/issues/1071).
- [ ] [D246 — JWT](https://github.com/guillermomolina/protos/issues/1072).

D247 is closed; D243–D246 remain open. Do not replace the missing cryptographic facilities with application-local implementations or a Java bootstrap.

## Remaining application work

- [x] Start a native HTTP/1.1 service with an explicit Network grant and `std:http/server`.
- [x] Add two TCP-accepting Worker Actors while retaining one RootActor-owned application store; validate native HTTP with Protos.
- [x] Run and record `make test-http-lifecycle` for deterministic two-Worker overlap, request-envelope transport, HTTP 413, drain and abort (reported PASS on 2026-11-07). Manual `quit` starts the RootActor-owned drain; signal-triggered shutdown and `std:http/host` application-module loading remain separate work.
- [ ] Implement registration, login, current-user lookup, validation, and authorization.
- [ ] Implement following/unfollowing, authenticated favorites, and the feed.
- [ ] Create, update, and delete articles and comments.
- [ ] Select and integrate durable storage; verify restarts and clean shutdown.
- [ ] Run the official RealWorld Hurl suite and record the exact revision and results.
- [ ] Finish startup instructions for a clean checkout.

Overall tracking: [RealWorld backend implementation](https://github.com/guillermomolina/protos/issues/1068).

**Do not claim RealWorld conformance** until the official tests pass against a running server.
