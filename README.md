# RealWorld backend in Protos

A small, readable [RealWorld (Conduit)](https://docs.realworld.show/specifications/backend/introduction/) backend, written in [Protos](https://github.com/guillermomolina/protos).

This project is **in development**. It is an example of composing ordinary Protos modules and its Standard Library, **not yet a fully conformant RealWorld backend**.

## Requirements

- Protos `0.3.451-SNAPSHOT` (required for the native HTTP service entry point)
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

The tests call the HTTP router directly, and also exercise one HTTP/1.1 exchange over an **in-memory** duplex. They do not start a TCP listener.

## Run the native HTTP server

The native Protos CLI can grant explicit TCP authority to the initial RootActor. From the repository root, start the learning server without a Java bootstrap:

```sh
protos --allow-network --service=service server.protos
```

After the listener has opened, the application prints `REALWORLD_HTTP_READY=127.0.0.1:3000`. In another terminal, try:

```sh
curl -i http://127.0.0.1:3000/api/tags
curl -i http://127.0.0.1:3000/api/articles
curl -i http://127.0.0.1:3000/api/profiles/unknown
curl -i 'http://127.0.0.1:3000/api/articles?limit=0'
```

These four native loopback requests were verified with HTTP statuses 200, 200, 404 and 422 respectively. The in-memory store starts empty, so articles and tags are empty until populated. The server listens only on `127.0.0.1:3000` and handles one HTTP/1.1 request per connection **sequentially** through `std:http/server`. This is a learning entry point, not a concurrent production host. Ctrl-C ends the process; graceful drain/shutdown is not implemented.

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
  Responses.protos     HTTP response helpers

tests/
  slice01-smoke.protos
  slice01-wire-smoke.protos
  slice02-articles-query.protos
  slice03-public-content.protos

server.protos        Native HTTP/1.1 service entry point
run-tests.protos     Focused test entry point
Makefile             Test command
```

The application uses existing Protos facilities such as `std:http/router`, `std:http/server`, `std:json/json` and `std:collections/array`; it does not implement private replacements for those libraries.

See [TODO.md](TODO.md) for the remaining work and upstream Protos blockers.

## What is not implemented yet

- User registration, login, signed tokens and authenticated operations
- Following, authenticated favorite mutations, article mutations and comment mutations
- Durable storage
- Concurrent hosting and graceful shutdown (for example with `std:http/host`)
- Official RealWorld Hurl conformance

The native CLI now supports explicit TCP authority with `--allow-network` and the long-lived RootActor service entry with `--service=service` ([D247](https://github.com/guillermomolina/protos/issues/1073)). It does not grant Filesystem access; durable storage is still pending. `std:http/host` is available for bounded concurrent hosting, but this first application entry point intentionally uses a sequential accept-and-serve loop.

The authentication work is waiting for reusable, approved Protos security-library designs rather than adding application-local cryptography. See [D243](https://github.com/guillermomolina/protos/issues/1069), [D244](https://github.com/guillermomolina/protos/issues/1070), [D245](https://github.com/guillermomolina/protos/issues/1071) and [D246](https://github.com/guillermomolina/protos/issues/1072).

## Contract and progress

The external API contract belongs to the [RealWorld backend specification](https://docs.realworld.show/specifications/backend/introduction/). Its OpenAPI and Hurl tests are the conformance authority; passing the local smoke tests is not a claim of complete conformance.

The corresponding Protos implementation work is tracked in [the RealWorld backend issue](https://github.com/guillermomolina/protos/issues/1068).
