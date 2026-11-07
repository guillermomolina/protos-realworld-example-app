# RealWorld backend in Protos

A small, readable [RealWorld (Conduit)](https://docs.realworld.show/specifications/backend/introduction/) backend, written in [Protos](https://github.com/guillermomolina/protos).

This project is **in development**. It is an example of composing ordinary Protos modules and its Standard Library, **not yet a fully running or conformant RealWorld backend**.

## Requirements

- Protos `0.3.449-SNAPSHOT` (the version used for the currently validated tests)
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

## Implemented so far

| Route | Behavior |
| --- | --- |
| `GET /api/tags` | Distinct tags from the current in-memory articles |
| `GET /api/articles` | Public article list, tag/author filters, ordering and pagination |
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

run-tests.protos     Focused test entry point
Makefile             Test command
```

The application uses existing Protos facilities such as `std:http/router`, `std:http/server`, `std:json/json` and `std:collections/array`; it does not implement private replacements for those libraries.

## What is not implemented yet

- User registration, login, signed tokens and authenticated operations
- Following, favorites, authenticated article mutations and comment mutations
- Durable storage
- TCP server startup and shutdown
- Official RealWorld Hurl conformance

The current standalone Protos CLI grants neither `network` nor `filesystem` authority. Protos already provides `std:http/host` and `std:io/files`, but real TCP hosting and persistence require an explicitly granted capability from an embedding host. Protos documents a [JVM embedding interface](https://github.com/guillermomolina/protos/blob/main/docs/guide/embedding/java.md) for that purpose. A native command-line launch does not currently provide those capabilities.

The authentication work is waiting for reusable, approved Protos security-library designs rather than adding application-local cryptography. See [D243](https://github.com/guillermomolina/protos/issues/1069), [D244](https://github.com/guillermomolina/protos/issues/1070), [D245](https://github.com/guillermomolina/protos/issues/1071) and [D246](https://github.com/guillermomolina/protos/issues/1072).

## Contract and progress

The external API contract belongs to the [RealWorld backend specification](https://docs.realworld.show/specifications/backend/introduction/). Its OpenAPI and Hurl tests are the conformance authority; passing the local smoke tests is not a claim of complete conformance.

The corresponding Protos implementation work is tracked in [the RealWorld backend issue](https://github.com/guillermomolina/protos/issues/1068).
