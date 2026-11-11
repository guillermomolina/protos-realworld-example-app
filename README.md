# RealWorld (Conduit) backend in Protos

A complete *HTTP route implementation* of the [RealWorld (Conduit) backend API](https://docs.realworld.show/specifications/backend/introduction/), written in [Protos](https://github.com/guillermomolina/protos), an experimental prototype-based programming language implemented on GraalVM/Truffle.

This project demonstrates that Protos can build a nontrivial application with **real TCP networking, two HTTP Worker Actors, RootActor-owned state, Argon2id passwords, HS256 JWT authentication and an application-owned durable journal**, using Protos modules and its Standard Library rather than an application-specific Java server or a database dependency.

**Status:** All 19 required application routes are implemented. Local unit/integration and HTTP lifecycle tests have been reported passing. The official Hurl suite passes **12/13 files unmodified**, and **13/13 files (157 requests)** with a documented token-refresh adjustment. **Durable persistence (I153-H1) is implemented in the source but not yet validated**: its new tests and the real restart/crash harness have not been run. Until they have, treat state as unproven across restarts. This is not a production-ready or fully conformant backend.

## Quick start

Requires **Protos `0.3.459-SNAPSHOT`** (development baseline) or a newer compatible build, `make`, and `openssl` on your `PATH`. This is not a published stable Protos release.

```sh
# Terminal 1: from this repository's root
make init-data   # once: creates var/realworld-data/ and an empty journal
make serve
# Look for: REALWORLD_HTTP_READY=127.0.0.1:3000
```

```sh
# Terminal 2: exercise public HTTP endpoints
curl -i http://127.0.0.1:3000/api/tags
curl -i http://127.0.0.1:3000/api/articles
```

Type `quit` and Enter in terminal 1 for graceful shutdown. `make init-data` never resets an existing journal; override the location with `REALWORLD_DATA_DIR=...`. `make serve` generates an ephemeral **development-only** JWT signing key using OpenSSL when no key is configured; set `REALWORLD_JWT_KEY_BASE64URL` explicitly when you need a stable key. The listener binds to `127.0.0.1`, not the public Internet.

## Architecture

```text
                    TCP 127.0.0.1:3000
                            |
                +-----------+-----------+
                |                       |
          HTTP Worker Actor 1     HTTP Worker Actor 2
                |                       |
                +-----------+-----------+
                            |
                    transferable request data
                            |
                         RootActor
                    /       |        \
                Router   Auth/JWT    DurableStore ── Journal ── realworld.journal
                            |             |             (lock, append, sync)
                       Argon2id      MemoryStore
                       + Entropy    (users, articles, follows, favorites)
```

Workers handle their own TCP sessions and transfer bounded HTTP request snapshots; they never receive the mutable store, credentials, signing key, Clock or Entropy grants. The RootActor owns authentication, authorization and all application mutations. There is no custom application-private crypto implementation.

Every successful write is one logical transaction: it is prepared on an independent candidate state, appended as one checksummed journal frame, synchronized with `File.sync()`, and only then published and answered. See [Persistence](#persistence) and [`docs/persistence.md`](docs/persistence.md).

**Suggested source reading order:** [`src/main.protos`](src/main.protos) → [`HttpWorker.protos`](src/app/HttpWorker.protos) → [`Api.protos`](src/app/Api.protos) → [`Auth.protos`](src/app/Auth.protos) → [`AuthStore.protos`](src/app/AuthStore.protos) → [`MemoryStore.protos`](src/app/MemoryStore.protos).

## Tests and compatibility

Historical outcomes reported on 2026-11-09, **before** the persistence slice:

| Command | Historical reported outcome |
| --- | --- |
| `make test` | 12 test groups passed, including secure authentication |
| `make test-http` | Authenticated HTTP over real TCP passed |
| `make test-http-lifecycle` | Workers, request limits, drain and abort passed |
| `make test-hurl` | 13 files / 157 requests passed **with an explicit test adjustment** |

The persistence slice adds five `make test` groups and `make test-restart`; none has been run yet, and the earlier groups have not been re-run against the changed code.

The **unmodified** official RealWorld Hurl suite passed 12 of 13 files. Its remaining case reused a JWT after a password change, while this implementation revokes old tokens. The tracked [`hurl-refresh-token.patch`](src/tests/hurl-refresh-token.patch) updates the test's token in a temporary copy; it does not modify the official checkout. **An adjusted Hurl pass is not an unmodified official conformance claim.** Details and prerequisites follow below.

## Project status and contributions

The remaining major application work is **validating durable persistence**: running the new test groups and the real restart/crash harness. Persistence is implemented in Protos itself with no SQLite or other database dependency. SQLite/portable database access is separate Protos ecosystem work and is not used here. The backend has no HTTPS, public hosting or production operational hardening.

See [`TODO.md`](TODO.md) for outstanding work, [`CONTRIBUTING.md`](CONTRIBUTING.md) for contribution guidance, and [GitHub Issues](https://github.com/guillermomolina/protos-realworld-example-app/issues) to report a reproducible problem or propose an improvement. For the language itself, see the [Protos repository](https://github.com/guillermomolina/protos) and [language website](https://protos.guillermomolina.com/).

---

## Required Protos capabilities

The verified development baseline is **Protos `0.3.459-SNAPSHOT`**, or a later
version containing **I157, I159, I160, I161 and I163**, including the approved
**D253-C1 RootActor-local Clock**. This snapshot is a development baseline, not
a published stable release. Earlier snapshots used for public-route tests are
not a sufficient authentication baseline.

The application consumes the public Standard Library password, JWT, Base64url,
Instant, ISO8601, JSON and HTTP Router interfaces. Password hashing and verification
use the Standard Library's Argon2id provider. There are no application-private
cryptographic, Base64url or time implementations, and no Java launcher.

The server requires explicitly granted **Network, Entropy, Clock and Filesystem** authorities. The Filesystem grant is confined to the data directory:

```sh
make init-data && make serve
# Equivalent, retaining any desired PROTOS_ARGS:
protos --allow-network --allow-entropy --allow-clock \
  --allow-filesystem=var/realworld-data --service=service src/main.protos
```

A missing Filesystem grant, missing journal, held lock or unrecoverable journal prevents the readiness marker; there is no in-memory fallback.

For a stable signing key, set `REALWORLD_JWT_KEY_BASE64URL` in the server process environment before starting; `make serve` otherwise supplies a temporary development key.
Its value must be a valid Base64url encoding of **32–4096 cryptographically random
key octets**. Generate the key outside source code with a trusted secret-management
or random-key tool. Keep it secret and stable across service starts; never commit
it, place it in a URL, or include it in diagnostic output. Changing it rejects all
previously signed tokens. The server neither embeds a production key nor generates
a replacement when configuration is missing. Missing grants, absent/malformed
keys and invalid key lengths prevent the readiness marker.

JWTs use issuer and audience `protos-realworld`, protected type
`realworld-access+jwt`, a maximum lifetime of 3600 seconds and zero clock skew.
Subjects are immutable random public identifiers independent of username/email.
The retained credential generation revokes earlier tokens after a password change.
Every issuance and verification observes a fresh trusted Instant.

Registration hashes the password, generates the subject and rechecks uniqueness
before issuing its token. Token issuance completes before identity and credential
admission, so a Clock or JWT failure leaves no account and the same username/email
can be retried. The response uses that pre-issued token without signing again
after commit. Invalid-credentials responses retain HTTP 401 and use the RealWorld
message `invalid`; login passwords outside the provider's input domain or above
4096 UTF-8 bytes are rejected before verification.

Registration and password changes require at least eight Unicode characters and
accept passwords of at least 64 characters without composition rules. The input
limit is 4096 UTF-8 bytes. Usernames and emails are exactly unique. Profile `bio`
and `image` accept null, and empty strings normalize to null. Omitted update fields
remain unchanged. Article titles are limited to 1024 UTF-8 bytes; duplicate titles
receive deterministic distinct slugs, and updates preserve existing slugs.

## HTTP routes

Send an authenticated request with exactly one header:
`Authorization: Token <compact-jwt>`. Duplicate Authorization headers, malformed
schemes/tokens, expired tokens and unverified claims never grant a principal.
Public GETs support viewer-aware projections when valid credentials are supplied.

| Method | Route | Behavior |
| --- | --- | --- |
| POST | `/api/users` | Register; 201 |
| POST | `/api/users/login` | Login; 200 |
| GET / PUT | `/api/user` | Read/update current account |
| GET | `/api/profiles/{username}` | Public or viewer-aware profile |
| POST / DELETE | `/api/profiles/{username}/follow` | Follow/unfollow |
| GET | `/api/articles` | Filtered and paginated public article list |
| GET | `/api/articles/feed` | Authenticated followed-author feed |
| POST | `/api/articles` | Create article; 201 |
| GET | `/api/articles/{slug}` | Article detail |
| PUT / DELETE | `/api/articles/{slug}` | Owner update/delete; deletion returns 204 |
| POST / DELETE | `/api/articles/{slug}/favorite` | Favorite/unfavorite |
| GET / POST | `/api/articles/{slug}/comments` | List/create comments; creation returns 201 |
| DELETE | `/api/articles/{slug}/comments/{id}` | Owner deletion; 204 |
| GET | `/api/tags` | Distinct current article tags |

Article lists and feeds sort newest first by parsing ISO8601 timestamps and
comparing exact Instants, including timestamps with differing fractional-second
precision. Filtering, pagination and counts before pagination are preserved.
Article lists omit `body`; details include it. Profiles and authors derive
`following` from the stable-ID follow graph, and articles derive `favorited` from
the stable-ID favorite graph. Anonymous projections use false. Request JSON never
selects an authenticated actor ID. Ownership checks remain mandatory after JWT
verification. Missing/rejected credentials return 401, foreign-owner operations
403, absent resources 404, username/email conflicts 409 and invalid input 422.
Unconfigured security or operational provider failures produce sanitized 503
responses rather than simulated authentication. The single-store `Api.make`
construction remains available for anonymous fixtures and fails closed for writes.

## Execution and validation

```sh
make test
make init-data             # Once per data directory; never resets existing data
make serve                 # Separate terminal; temporary key if none is configured
make test-http             # Requires a server on a FRESH data directory (fixed accounts)
make test-http-lifecycle    # Independent ephemeral lifecycle fixture
make test-hurl              # Requires the running server, Hurl and the external spec
make test-persistence       # Alias of make test (persistence groups are in-memory)
make test-restart           # Real restart/SIGKILL/lock/corruption harness (Python driver)
```

`make test-http` and `make test-hurl` register fixed or generated accounts. Run them against a server started on a disposable data directory, for example `REALWORLD_DATA_DIR=var/http-test make init-data serve`, so that stored accounts from earlier runs do not cause conflicts.

`make serve` preserves a configured `REALWORLD_JWT_KEY_BASE64URL`. When the variable
is unset, the Makefile uses OpenSSL to generate a temporary development key without
printing or saving it. It changes on each start. Direct Protos invocation still
requires the environment setting.

`make test-hurl` uses the checkout at `/tmp/realworld-spec`; override it with
`REALWORLD_SPEC=/path/to/realworld-spec` and the server origin with
`HOST=http://127.0.0.1:3000` (without `/api`). The suite creates its own test
accounts and passwords. A disposable copy receives the small tracked
`src/tests/hurl-refresh-token.patch`: after changing a password, the next request
uses the returned token because the previous one is revoked. The external checkout
is not modified. Results from this adapted suite must be distinguished from an
unmodified official-suite run.

`PROTOS` and `PROTOS_ARGS` remain overridable. Direct tests receive real Entropy
and Clock grants and retain all eleven previous groups. The new secure-auth group
prints `REALWORLD_SECURE_AUTH_HTTP=PASS` only after all its assertions complete.
The native TCP test parses real response tokens and exercises registration, login,
current user, article, favorite and comment creation/deletion.

Historical validation reported by the maintainer on **2026-11-09** (before the persistence slice), using the Protos
`0.3.459-SNAPSHOT` development baseline:

| Command | Reported result |
| --- | --- |
| `make test` | All 12 groups PASS, including `REALWORLD_SECURE_AUTH_HTTP=PASS` |
| `make test-http` | `REALWORLD_NATIVE_HTTP=PASS`; complete authenticated TCP scenario |
| `make test-http-lifecycle` | All five checks PASS: concurrent Workers, request envelope, body limit, drain and abort |
| `make test-hurl` | All 13 files and 157 requests succeeded; zero failed files; 12.134 seconds |

The Hurl run used the tracked token-refresh patch on a temporary suite copy.
The preceding unmodified run passed 12 of 13 files; `errors_auth.hurl` reused a
revoked token after changing the password. The adapted run passed all 13 files
without weakening token revocation. The external specification checkout revision
has not been recorded. These results establish the reported checks, not unmodified
official-suite conformance. The agent did not execute these validations.

The service listens on `127.0.0.1:3000`. Two HTTP Worker Actors retain delegated
TCP acceptors and send bounded request snapshots to the RootActor. Requests keep
the raw target, ordered duplicate-preserving headers and body Bytes. The Standard
Library HTTP server caps request bodies at 1 MiB. Workers never receive the mutable
application store, security-service object, signing key, credential repository,
Clock or Entropy capabilities. RootActor logs contain safe method/status metadata,
not Authorization, bodies, query strings or credential material.

Type `quit` followed by Enter in the server terminal to request graceful drain.
The RootActor closes the listener, waits for admitted work and stops the Workers.
EOF leaves the service running. Ctrl-C is host termination and does not guarantee
a graceful drain. The independent lifecycle fixture retains drain/abort coverage.

## Persistence

State is kept in a Protos-first, application-owned journal. There is no SQLite, ORM,
Java storage provider or other persistence dependency, and no change to the language
runtime. The design is the ratified D255-H1 (E+A): one cooperative writer, one
RootActor that owns all mutable state and the journal, an explicit confined
Filesystem grant, and an append-only file of versioned, checksummed domain
transactions.

- **Data directory and files.** `make init-data` creates `REALWORLD_DATA_DIR`
  (default `var/realworld-data`) and an empty `realworld.journal`. It never truncates
  existing data. The server only opens the preprovisioned journal; it never creates
  or resets it.
- **Lock.** On startup the server creates `realworld.journal.lock` with `createNew`.
  A second server is refused. A lock left by a crash is **never** removed
  automatically. Remove it manually after confirming that no server is running
  (see [stale-lock recovery](docs/persistence.md#stale-lock-recovery-procedure)).
- **Commit.** prepare → append → `File.sync()` → publish → respond. A success
  response is never sent based on unsynchronized state.
- **Crashes and uncertain commits.** If a write or sync fails, the process stops
  accepting writes (503) and serves the last committed state. Nothing is rolled
  back. At the next start, a complete final frame is applied even if its client saw
  an error, and a torn final frame is refused. The torn frame is removed only with
  explicit `REALWORLD_JOURNAL_REPAIR=truncate-incomplete-tail`. Interior corruption
  always fails closed.
- **Restart.** Recovery replays and validates every frame before the listener
  opens. Accounts, subjects, credential generations (revocation), articles,
  comments, follows, favorites and counters are restored exactly.
- **Signing key.** The key is never persisted. Restart authentication needs the
  same `REALWORLD_JWT_KEY_BASE64URL`. A new key keeps all data but invalidates all
  issued tokens.
- **Limitations.** Single writer only. Each transaction stores the full domain, so
  the journal grows quickly. It is bounded at 1 GiB and has no compaction, which
  suits a learning example. Durability is only as strong as `File.sync()` on the
  host. No durability is claimed for directory entries (the lock file), and there
  is no cross-file ACID. Fault-injection tests do not prove power-loss durability.
  JVM and Native support are claimed only once validated; neither has been yet.

The full protocol, limits and operator contract are in
[`docs/persistence.md`](docs/persistence.md).

## Storage and deployment limitations

Persistence is implemented but **not yet validated** by running its tests or the
restart harness. Until then, do not rely on it for data you cannot lose. The journal
contains Argon2id verifiers: protect the data directory like a password database.

The loopback HTTP listener has no TLS and is not a production deployment. Production
requires transport protection, deployment hardening, validated durable recovery and
backups, operational controls and a defined key-custody/rotation policy. See [TODO.md](TODO.md).

The [RealWorld backend specification](https://docs.realworld.show/specifications/backend/introduction/)
and its official Hurl suite define conformance. Local assertions do not establish it.
