# RealWorld backend in Protos

A Protos-first RealWorld HTTP backend with RootActor-owned, in-memory accounts,
credentials, profiles, articles, comments, follows and favorites. Slice 12 adds
secure authentication and authenticated domain routes. The maintainer has reported
passing direct, native HTTP, HTTP lifecycle and adapted Hurl tests on Protos
`0.3.459-SNAPSHOT`; the validation details and scope are recorded below.

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

The server requires explicitly granted **Network, Entropy and Clock** authorities:

```sh
make serve
# Equivalent, retaining any desired PROTOS_ARGS:
protos --allow-network --allow-entropy --allow-clock --service=service src/main.protos
```

Set `REALWORLD_JWT_KEY_BASE64URL` in the server process environment before starting.
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
make serve                 # Separate terminal; temporary key if none is configured
make test-http             # Requires a fresh running server for account fixtures
make test-http-lifecycle    # Independent ephemeral lifecycle fixture
make test-hurl              # Requires the running server, Hurl and the external spec
```

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

Validation reported by the maintainer on **2026-11-09**, using the Protos
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

## Storage and deployment limitations

All application state is **in memory**. Restarting loses every account, credential,
article, comment, follow and favorite. A stable signing key does not make those
records durable: a token whose credential subject has been lost cannot authorize.
Durable persistence and restart recovery are separate remaining subsystems.

The loopback HTTP listener has no TLS and is not a production deployment. Production
requires transport protection, deployment hardening, durable recovery, operational
controls and a defined key-custody/rotation policy. See [TODO.md](TODO.md).

The [RealWorld backend specification](https://docs.realworld.show/specifications/backend/introduction/)
and its official Hurl suite define conformance. Local assertions do not establish it.
