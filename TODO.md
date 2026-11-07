# TODO — RealWorld backend in Protos

## Current validated state

- Public routes: tags, article listing and details, profiles, and comments.
- Public article filtering by `tag`, `author`, and `favorited`, including sorting and pagination.
- Favorites are populated through test fixtures; authenticated favorite mutations are not implemented.
- Router and HTTP/1.1 unit tests use an in-memory duplex; the native two-Worker service also passed the Protos loopback TCP client for four requests (HTTP 200, 200, 404, 422).
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
- [ ] Verify simultaneous-request handling and add graceful drain/shutdown; evaluate `std:http/host` application-module loading separately.
- [ ] Implement registration, login, current-user lookup, validation, and authorization.
- [ ] Implement following/unfollowing, authenticated favorites, and the feed.
- [ ] Create, update, and delete articles and comments.
- [ ] Select and integrate durable storage; verify restarts and clean shutdown.
- [ ] Run the official RealWorld Hurl suite and record the exact revision and results.
- [ ] Finish startup instructions for a clean checkout.

Overall tracking: [I153 — RealWorld](https://github.com/guillermomolina/protos/issues/1068).

**Do not claim RealWorld conformance** until the official tests pass against a running server.
