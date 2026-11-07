# RealWorld backend in Protos

A small, readable [RealWorld (Conduit)](https://docs.realworld.show/specifications/backend/introduction/) backend, written in [Protos](https://github.com/guillermomolina/protos).

This project is **in development**. It is an example of composing ordinary Protos modules and its Standard Library, **not yet a fully conformant RealWorld backend**.

## Requirements

- Protos `0.3.452-SNAPSHOT` (includes the standard `Bytes` Actor-transfer fix required by the Worker server)
- `make`

## Run the tests

```sh
make test
```

The Makefile invokes:

```sh
protos -Dpolyglot.engine.WarnInterpreterOnly=false run-tests.protos
```

The Truffle option hides the interpreter-only diagnostic; it does not enable a compiler or suppress test failures. If using a different launcher, override `PROTOS` or `PROTOS_ARGS` on the `make` command line.

These tests call the HTTP router directly and exercise one HTTP/1.1 exchange over an **in-memory** duplex. They do not start a TCP listener. The separate `make test-http` command tests the running native server over real loopback TCP, using a client written in Protos.

## Run the native HTTP server

The native Protos CLI can grant explicit TCP authority to the initial RootActor. From the repository root, start the learning server without a Java bootstrap:

```sh
make serve
```

This runs `protos --allow-network --service=service server.protos` with the Makefile's configurable `PROTOS` and `PROTOS_ARGS`.

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

On Protos `0.3.452-SNAPSHOT`, this test passed for four native loopback requests with statuses 200, 200, 404 and 422. The in-memory store starts empty, so articles and tags are empty until populated. The server listens only on `127.0.0.1:3000`. Two Worker Actors accept connections through delegated `TcpAcceptor` capabilities and run `std:http/server` for one HTTP/1.1 exchange per connection. Each Worker requests its response from the RootActor through a `GroupRef`; the RootActor exclusively owns the mutable `MemoryStore`. This is a bounded learning server, not a production HTTP host. Ctrl-C ends the process; graceful drain/shutdown is not implemented. The current test confirms HTTP correctness, not simultaneous-request throughput or official RealWorld conformance.

`--allow-network` is explicit and applies only to the initial RootActor; it does not grant filesystem access, DNS resolution or Network authority to imported modules and child Actors. Running without the flag does not authorize TCP listening.

## Implemented so far

| Route | Behavior |
| --- | --- |
| `GET /api/tags` | Distinct tags from the current in-memory articles |
| `GET /api/articles` | Public article list, tag/author/favorited filters, ordering and pagination |
| `GET /api/articles/:slug` | Public article details |
| `GET /api/profiles/:username` | Public profile lookup |
| `GET /api/articles/:slug/comments` | Public comments for an article |

Public list responses omit the article body, as required by the current RealWorld contract. The tests also cover missing resources and unauthenticated access to the feed route.

All data currently comes from test fixtures. It is lost when the process ends. Public responses have not yet passed RealWorld's official Hurl test suite.

## Code layout

```text
src/
  Api.protos           HTTP route composition
  ArticleQuery.protos  Public article query selection
  Articles.protos      Article and profile JSON responses
  Comments.protos      Comment JSON responses
  MemoryStore.protos   Temporary in-memory repository
  HttpWorker.protos    Worker Actor HTTP connection service
  Responses.protos     HTTP response helpers

tests/
  slice01-smoke.protos
  slice01-wire-smoke.protos
  slice02-articles-query.protos
  slice03-public-content.protos
  native-http.protos  Native HTTP integration client (Protos)

server.protos        RootActor service and Worker bootstrap
run-tests.protos     Focused test entry point
Makefile             test, serve, and test-http commands
```

The application uses existing Protos facilities such as `std:http/router`, `std:http/server`, `std:json/json` and `std:collections/array`; it does not implement private replacements for those libraries.

See [TODO.md](TODO.md) for the remaining work and upstream Protos blockers.

## What is not implemented yet

- User registration, login, signed tokens and authenticated operations
- Following, authenticated favorite mutations, article mutations and comment mutations
- Durable storage
- Graceful drain/shutdown and optional integration with `std:http/host`
- Official RealWorld Hurl conformance

The native CLI now supports explicit TCP authority with `--allow-network` and the long-lived RootActor service entry with `--service=service` ([D247](https://github.com/guillermomolina/protos/issues/1073)). It does not grant Filesystem access; durable storage is still pending. The app currently composes delegated `TcpAcceptor` capabilities, two Worker Actors and `std:http/server` directly. It does not use `std:http/host`, whose Worker handler import contract is not wired to this standalone CLI application. Standard `Bytes` can cross the Actor boundary in the validated Protos version ([BUG035](https://github.com/guillermomolina/protos/issues/1081)).

The authentication work is waiting for reusable, approved Protos security-library designs rather than adding application-local cryptography. See [D243](https://github.com/guillermomolina/protos/issues/1069), [D244](https://github.com/guillermomolina/protos/issues/1070), [D245](https://github.com/guillermomolina/protos/issues/1071) and [D246](https://github.com/guillermomolina/protos/issues/1072).

## Contract and progress

The external API contract belongs to the [RealWorld backend specification](https://docs.realworld.show/specifications/backend/introduction/). Its OpenAPI and Hurl tests are the conformance authority; passing the local smoke tests is not a claim of complete conformance.

The corresponding Protos implementation work is tracked in [the RealWorld backend issue](https://github.com/guillermomolina/protos/issues/1068).
