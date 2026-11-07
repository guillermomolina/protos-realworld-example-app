# RealWorld backend in Protos

A small, readable [RealWorld (Conduit)](https://docs.realworld.show/specifications/backend/introduction/) backend, written in [Protos](https://github.com/guillermomolina/protos).

This project is **in development**. It is an example of composing ordinary Protos modules and its Standard Library, **not yet a fully conformant RealWorld backend**.

## Requirements

- Protos `0.3.452-SNAPSHOT` (includes the standard `Bytes` Actor-transfer fix required by the Worker server)
- `make`

## Source-tree layout

All `.protos` files live below `src/`. Application modules are in `src/app/`,
and test cases in `src/tests/`; `src/` also holds CLI entrypoints.
Protos direct-file imports are confined to the entry file's directory: the
test and lifecycle wrappers in `src/` allow tests to import `../app/`
without escaping the authorized SOURCE root. Run the documented `make`
targets rather than executing `src/tests/main.protos` directly.

## Run the tests

```sh
make test
```

The Makefile invokes:

```sh
protos -Dpolyglot.engine.WarnInterpreterOnly=false src/test-main.protos
```

The Truffle option hides the interpreter-only diagnostic; it does not enable a compiler or suppress test failures. If using a different launcher, override `PROTOS` or `PROTOS_ARGS` on the `make` command line.

These tests call the HTTP router directly and exercise one HTTP/1.1 exchange over an **in-memory** duplex. They do not start a TCP listener. The separate `make test-http` command tests the running native server over real loopback TCP, using a client written in Protos.

## Run the native HTTP server

The native Protos CLI can grant explicit TCP authority to the initial RootActor. From the repository root, start the learning server without a Java bootstrap:

```sh
make serve
```

This runs `protos --allow-network --service=service src/main.protos` with the Makefile's configurable `PROTOS` and `PROTOS_ARGS`.

After the listener has opened, the application prints `REALWORLD_HTTP_READY=127.0.0.1:3000`. In another terminal, try:

```sh
curl -i http://127.0.0.1:3000/api/tags
curl -i http://127.0.0.1:3000/api/articles
curl -i http://127.0.0.1:3000/api/profiles/unknown
curl -i 'http://127.0.0.1:3000/api/articles?limit=0'
```

With `make serve` still running, run the focused Protos HTTP integration test from a second terminal:

```sh
make test-http
```

For a self-contained concurrency and shutdown regression, without a separately
running `make serve`, run:

```sh
make test-http-lifecycle
```

The native Protos fixture uses an ephemeral loopback listener and the **same**
`src/app/HttpWorker.protos` used by the server. It holds a request header incomplete
until a Worker acknowledges accepting it, verifies a second Worker completes a
real HTTP request meanwhile, then initiates drain **before** completing the
first request. It also verifies cross-Actor HTTP headers and body transport, chunked body
decoding, an empty request body and early HTTP 413 rejection, then exercises
cancellation-based abort on a second listener.
`timeout` bounds potential deadlocks in this native-only integration test.
The native lifecycle run reports `REALWORLD_HTTP_ENVELOPE=PASS` and
`REALWORLD_HTTP_LIMIT=PASS` when the new checks pass.

On Protos `0.3.452-SNAPSHOT`, this test passed for four native loopback requests with statuses 200, 200, 404 and 422. The in-memory store starts empty, so articles and tags are empty until populated. The server listens only on `127.0.0.1:3000`. Two Worker Actors accept connections through delegated `TcpAcceptor` capabilities and run `std:http/server` for one HTTP/1.1 exchange per connection. Each Worker requests its response from the RootActor through a `GroupRef`; the RootActor exclusively owns the mutable `MemoryStore`. This is a bounded learning server, not a production HTTP host. Type `quit` and press Enter in the server terminal to request graceful drain: the RootActor closes the listener, waits for admitted sessions, stops both Workers, and then stops itself. Ctrl-C is host termination and is **not** guaranteed to drain. The current `make test-http` verifies HTTP correctness but does not itself establish simultaneous-request throughput or official RealWorld conformance.

`--allow-network` is explicit and applies only to the initial RootActor; it does not grant filesystem access, DNS resolution or Network authority to imported modules and child Actors. Running without the flag does not authorize TCP listening.

## Implemented so far

| Route | Behavior |
| --- | --- |
| `POST /api/users` | JSON validation (422), otherwise explicit 501 until secure registration exists |
| `POST /api/users/login` | JSON validation (422), otherwise explicit 501 until secure login exists |
| `GET /api/tags` | Distinct tags from the current in-memory articles |
| `GET /api/articles` | Public article list, tag/author/favorited filters, ordering and pagination |
| `GET /api/articles/:slug` | Public article details |
| `GET /api/profiles/:username` | Public profile lookup |
| `GET /api/articles/:slug/comments` | Public comments for an article |

The native Worker now snapshots complete HTTP requests (method, raw target,
version, ordered and duplicate-preserving header pairs, and decoded body bytes)
before sending them to the RootActor. It reads the session-owned body locally
and caps it at **1 MiB** using `std:http/server` limits; over-limit requests
are rejected with HTTP 413. Only transferable data crosses the Actor boundary:
no TCP connection, stream or mutable application store is transferred.
Registration and login now validate these body bytes, but do not create users or issue tokens.

`src/app/RequestJson.protos` separately validates UTF-8 JSON `user`, `article` and
`comment` envelopes, required non-empty string fields, and optional article
`tagList` arrays. It returns structured validation results that existing
`Responses.error` can render as Conduit-style 422 errors. These helpers were first tested independently; the public identity routes now
validate request bodies without creating users, issuing tokens, or
enabling authenticated writes.
Registration and login now call these validators in the HTTP router. Invalid
request bodies return Conduit-style HTTP 422 errors; structurally valid
requests return an explicit HTTP 501 `errors.service` response without
creating credentials or changing state. Protected routes continue to
return HTTP 401 before interpreting untrusted mutation bodies. Email
syntax/policy, password security, and successful mutation responses remain
unimplemented.

An additional `src/app/IdentityStore.protos` keeps credential-free identity
metadata (stable IDs, exact unique usernames/emails, nullable profile fields)
in Actor-local memory. Its fixture-only insert/update operations reject
collisions without partial writes and return independent snapshots; the
public profile projection never includes email, password, token or ID.
`MemoryStore` consults this identity repository for public profile reads,
falling back to older article/comment fixtures. No HTTP identity write or
authentication behavior is enabled by these internal methods. RealWorld
email normalization and secure credentials remain future work.

`src/app/FollowStore.protos` holds fixture-only follow relationships by
stable identity ID. It rejects unknown identities and self-follow, and
makes repeated follow/unfollow operations idempotent. `MemoryStore`
exposes internal following/follower queries and selects a feed from the
articles of followed identities using `ArticleQuery` ordering and
pagination. Article fixtures linked to existing identities retain a
stable author association after username changes; old fixtures without
a link can be matched by their author username when the identity appears.
The public article author of legacy fixtures is still the historical
snapshot. **This does not enable HTTP follow/unfollow or
`/api/articles/feed`**: those routes remain HTTP 401 until an
authenticated principal exists.

`src/app/ContentStore.protos` implements fixture-only ownership checks
and article/comment creation, partial article updates and deletion. It
uses stable identity IDs; managed article/comment snapshots resolve
current public author names without exposing email or credentials.
Managed content appears in existing public GETs, tag and author filters,
and internal followed-author feed selection. Article deletion removes
managed comments and favorite edges. Callers supply collision-free
slugs and canonical timestamps; title duplicates are valid with
different slugs. Legacy fixture records remain readable, but only
managed content participates in the new mutation operations. No
HTTP write route is enabled.

Public list responses omit the article body, as required by the current RealWorld contract. Public 404 responses identify the missing `article` or `profile` in a JSON `errors` envelope. Protected operations without an authenticated principal return the Conduit 401 `errors.token` envelope; this is not an implementation of token validation or authenticated mutations. The tests also cover missing resources and unauthenticated access to the feed route.

All data currently comes from test fixtures. It is lost when the process ends. Public responses have not yet passed RealWorld's official Hurl test suite.

## Code layout

```text
src/
  main.protos                Native HTTP server entry
  test-main.protos           Focused test suite entry
  lifecycle-main.protos      Network-capable lifecycle test bootstrap
  app/
    Api.protos               HTTP route composition
    ArticleQuery.protos      Public article query selection
    Articles.protos          Article and profile JSON responses
    Comments.protos          Comment JSON responses
    MemoryStore.protos       Actor-local in-memory repository
    IdentityStore.protos     Credential-free identity metadata repository
    FollowStore.protos       Stable-ID follow relationships (fixtures only)
    ContentStore.protos      Owned article/comment domain mutations (fixtures only)
    HttpWorker.protos        Worker HTTP connection service
    HttpWorkers.protos       Worker lifecycle controller
    Responses.protos         HTTP response helpers
    RequestJson.protos       Pure JSON envelope validation
  tests/
    main.protos              Imports focused test cases
    slice01-smoke.protos
    slice01-wire-smoke.protos
    slice02-articles-query.protos
    slice03-public-content.protos
    slice04-public-errors.protos
    slice06-json-contract.protos
    slice07-identity-routing.protos
    slice08-identity-store.protos
    slice09-social-feed.protos
    slice10-content-mutations.protos
    native-http.protos       Running-server integration client
    native-http-lifecycle.protos  Native concurrency/drain/abort fixture

Makefile                    Stable test, serve and integration commands
```

The application uses existing Protos facilities such as `std:http/router`, `std:http/server`, `std:json/json` and `std:collections/array`; it does not implement private replacements for those libraries.

See [TODO.md](TODO.md) for the remaining work and upstream Protos blockers.

## What is not implemented yet

- User registration, login, signed tokens and authenticated operations
- Authenticated HTTP following, favorites, article and comment writes
- Durable storage
- Signal-triggered graceful drain and optional integration with `std:http/host` (the current manual `quit` command uses native drain)
- Official RealWorld Hurl conformance

The native CLI now supports explicit TCP authority with `--allow-network` and the long-lived RootActor service entry with `--service=service` ([D247](https://github.com/guillermomolina/protos/issues/1073)). It does not grant Filesystem access; durable storage is still pending. The app currently composes delegated `TcpAcceptor` capabilities, two Worker Actors and `std:http/server` directly. It does not use `std:http/host`, whose Worker handler import contract is not wired to this standalone CLI application. Standard `Bytes` can cross the Actor boundary in the validated Protos version ([BUG035](https://github.com/guillermomolina/protos/issues/1081)).

The authentication work is waiting for reusable, approved Protos security-library designs rather than adding application-local cryptography. See [D243](https://github.com/guillermomolina/protos/issues/1069), [D244](https://github.com/guillermomolina/protos/issues/1070), [D245](https://github.com/guillermomolina/protos/issues/1071) and [D246](https://github.com/guillermomolina/protos/issues/1072).

## Contract and progress

The external API contract belongs to the [RealWorld backend specification](https://docs.realworld.show/specifications/backend/introduction/). Its OpenAPI and Hurl tests are the conformance authority; passing the local smoke tests is not a claim of complete conformance.

The corresponding Protos implementation work is tracked in [the RealWorld backend issue](https://github.com/guillermomolina/protos/issues/1068).
