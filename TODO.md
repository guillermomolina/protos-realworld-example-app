# TODO — RealWorld backend in Protos

## Current validated state

- Public routes: tags, article listing and details, profiles, and comments.
- Public article filtering by `tag`, `author`, and `favorited`, including sorting and pagination.
- Favorites are populated through test fixtures; authenticated favorite mutations are not implemented.
- Router and HTTP/1.1 tests use an in-memory duplex, without opening a TCP socket.
- `make test` passed in the last reported local run; the official RealWorld suite has not been run.

There is no TCP server launchable from the native Protos CLI yet, no authenticated users, and no durable storage.

## Pending Protos dependencies

- [ ] [D247 — Network permission for the Native/JVM CLI](https://github.com/guillermomolina/protos/issues/1073): select the permission model and demonstrate real HTTP over the native executable without an external JDK.
- [ ] [D243 — Secure entropy](https://github.com/guillermomolina/protos/issues/1069).
- [ ] [D244 — HMAC and key handling](https://github.com/guillermomolina/protos/issues/1070).
- [ ] [D245 — Password hashing and verification](https://github.com/guillermomolina/protos/issues/1071).
- [ ] [D246 — JWT](https://github.com/guillermomolina/protos/issues/1072).

These five design decisions are still open. Do not replace them with application-local cryptography or a Java bootstrap.

## Remaining application work

- [ ] Start and shut down an HTTP service using `std:http/host` and an explicit Network grant.
- [ ] Implement registration, login, current-user lookup, validation, and authorization.
- [ ] Implement following/unfollowing, authenticated favorites, and the feed.
- [ ] Create, update, and delete articles and comments.
- [ ] Select and integrate durable storage; verify restarts and clean shutdown.
- [ ] Run the official RealWorld Hurl suite and record the exact revision and results.
- [ ] Finish startup instructions for a clean checkout.

Overall tracking: [I153 — RealWorld](https://github.com/guillermomolina/protos/issues/1068).

**Do not claim RealWorld conformance** until the official tests pass against a running server.
