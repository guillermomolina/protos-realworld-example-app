# RealWorld (Conduit) backend in Protos

An *HTTP route implementation* of the [RealWorld (Conduit) backend API](https://docs.realworld.show/specifications/backend/introduction/), written in [Protos](https://github.com/guillermomolina/protos), an experimental prototype-based programming language implemented on GraalVM/Truffle.

This project shows that Protos can build a nontrivial application with **real TCP networking, two HTTP Worker Actors, RootActor-owned state, Argon2id passwords, HS256 JWT authentication and SQLite persistence**, using Protos modules and its Standard Library (`std:sqlite` included) rather than an application-specific Java server.

**Status:** all 19 required application routes are implemented. **SQLite is the only source of truth** for accounts, credentials, articles, comments, follows and favorites. Restart, crash-recovery and official-suite validation of the persistent server are still pending (see [`TODO.md`](TODO.md)). This is not a production-ready backend, and it makes no claim of complete official RealWorld conformance.

## Requirements

**Native Image (preferred):**

- The standalone Protos Native executable, version **`0.4.192-SNAPSHOT`** or a newer compatible build that includes I170 (integrated generic FFM provider) and the persistent `std:sqlite` library. This is a development snapshot, not a public release.
- Install it with the Protos repository's official `dist/install.sh` workflow. The application then needs **no separately installed JDK, JVM, GraalVM, Maven or external provider JAR**.
- **Linux x86-64** host with the native SQLite shared library installed, for example `libsqlite3.so.0`. The Native executable contains the generic FFM provider, but it does **not** embed SQLite or any other third-party C library.
- An explicit grant on every run: `--allow-library sqlite3=libsqlite3.so.0`. Nothing authorizes a native library automatically.
- `make`. The SQLite process tests also use `bash` (≥ 4.4), `mkfifo`, `timeout`, `sha256sum` and `base64`.

**Portable JVM (alternative):** the portable JVM distribution on Linux x86-64 with JDK 25, plus the optional generic FFM provider JAR built from the Protos repository. The JAR is needed only for this configuration and is loaded explicitly with `--foreign-provider-path` (see [Alternative: portable JVM execution](#alternative-portable-jvm-execution)).

Both configurations run the same application source and use the same `std:sqlite` API.

## Quick start (Native Image)

```sh
export PROTOS="$HOME/.local/bin/protos"
export PROTOS_ARGS=""
export SQLITE_ARGS="--allow-library sqlite3=libsqlite3.so.0"

# The application creates the database file when authorized, not its directory.
mkdir -p "$HOME/realworld"
export REALWORLD_DB_PATH="$HOME/realworld/realworld.db"

# Supply a stable secret through the host's secret-management mechanism:
# Base64url of 32-4096 random octets. "..." is a placeholder, not a key.
export REALWORLD_JWT_KEY_BASE64URL="..."

# First start only: create the database file.
REALWORLD_DB_CREATE=1 make serve
# Look for: REALWORLD_HTTP_READY=127.0.0.1:3000
```

```sh
# Another terminal: exercise public endpoints.
curl -i http://127.0.0.1:3000/api/tags
curl -i http://127.0.0.1:3000/api/articles
```

Type `quit` and Enter in the server terminal for a graceful shutdown. Every later launch uses the same `REALWORLD_DB_PATH` and the same key, **without** `REALWORLD_DB_CREATE=1`, to reopen the same data:

```sh
make serve
```

The listener binds to `127.0.0.1:3000`, not the public Internet.

### Alternative: portable JVM execution

The portable JVM distribution has no integrated provider. Add the external FFM provider JAR to `PROTOS_ARGS`; everything else stays the same:

```sh
export PROTOS=/path/to/protos-jvm/bin/protos
export PROTOS_ARGS="--foreign-provider-path /absolute/path/protos-ffm-provider.jar"
export SQLITE_ARGS="--allow-library sqlite3=libsqlite3.so.0"
make serve
```

The Makefile forwards `PROTOS_ARGS` unchanged and never adds a provider JAR by itself. Native Image does not need this JAR.

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
                Router   Auth/JWT    SqliteStore / SqliteCredentials
                            |              |
                       Argon2id      SqliteDatabase (one Connection)
                       + Entropy           |
                                   SQLite file + WAL  <- only source of truth
```

Workers handle their own TCP sessions and transfer bounded HTTP request snapshots. They never receive the database, a Connection or Statement, a repository, credentials, the signing key, or the Clock and Entropy grants. The RootActor owns authentication, authorization, the single SQLite Connection and every mutation. There is no connection pool and no per-Worker connection.

Domain rules stay in Protos: validation, ownership, idempotent follows and favorites, slug allocation, and the Instant-based ordering and pagination of `ArticleQuery`. SQL is used for parameterized reads and writes of copied rows; SQLite constraints are the final integrity guarantee. `favoritesCount` is derived from the `favorites` relation on every read, so no counter can diverge.

**Suggested source reading order:** [`src/main.protos`](src/main.protos) → [`HttpWorker.protos`](src/app/HttpWorker.protos) → [`Api.protos`](src/app/Api.protos) → [`Auth.protos`](src/app/Auth.protos) → [`AuthStore.protos`](src/app/AuthStore.protos) → [`SqliteStore.protos`](src/app/SqliteStore.protos) → [`SqliteCredentials.protos`](src/app/SqliteCredentials.protos) → [`SqliteDatabase.protos`](src/app/SqliteDatabase.protos).

`MemoryStore.protos` and its identity, content, follow and favorite stores remain as **test fixtures** for the in-memory suite (`make test`). They are not connected to the production server, and nothing copies data between them and SQLite.

## Configuration

| Variable | Meaning |
| --- | --- |
| `REALWORLD_DB_PATH` | Required. Filename of the SQLite database. In-memory (`:memory:`) and `file:` URI names are refused. Relative paths use the process working directory. |
| `REALWORLD_DB_CREATE` | Only the exact value `1` allows creating a database file that does not exist yet. Without it, an absent file stops startup. |
| `REALWORLD_JWT_KEY_BASE64URL` | Required. Base64url encoding of 32–4096 random key octets. Supplied by the host; never stored in the database. |
| `PROTOS` | Protos executable (default `protos` on `PATH`). Normally the installed Native executable. |
| `PROTOS_ARGS` | Optional execution arguments, forwarded unchanged; empty by default. For the portable JVM it carries `--foreign-provider-path /absolute/path/protos-ffm-provider.jar`. |
| `SQLITE_LIBRARY` | Library target for the default grant (default `libsqlite3.so.0`). |
| `SQLITE_ARGS` | SQLite authorization (default `--allow-library sqlite3=$(SQLITE_LIBRARY)`). `make serve` and the SQLite targets require a nonempty `sqlite3=<library>` grant in `PROTOS_ARGS` or `SQLITE_ARGS`, written `--allow-library sqlite3=…` or `--allow-library=sqlite3=…`. |

`make serve` checks these settings and runs:

```sh
$PROTOS $PROTOS_ARGS $SQLITE_ARGS --allow-network --allow-entropy --allow-clock --service=service src/main.protos
```

There is no `--allow-filesystem` grant: it would not confine SQLite (see the security limitations below).

## Startup, shutdown and reopening

Startup proceeds in this order, and `REALWORLD_HTTP_READY` is printed only after every step has succeeded:

1. Clock and Entropy are observed.
2. The JWT key is read and checked.
3. `REALWORLD_DB_PATH` and `REALWORLD_DB_CREATE` are read.
4. The database is opened through the FFM provider (integrated in Native Image, or the external JAR on the JVM) (`readWrite`, or `readWriteCreate` when creation is authorized).
5. Connection policy: `busy_timeout` 1000 ms, `journal_mode=WAL` (verified as `wal`), `synchronous=FULL` (verified as `2`), `foreign_keys=ON` (verified as `1`).
6. For a new, empty file: the complete schema and `user_version=1` are created in one transaction. For an existing file, `user_version` must be `1`, and the tables, columns, foreign keys and unique indexes must match exactly. `PRAGMA integrity_check` must answer `ok` and `PRAGMA foreign_key_check` must return no rows.
7. Repositories, authentication and the HTTP router are built. Then the listener opens, the two Workers start and readiness is announced.

Any failure stops startup with a fixed label such as `REALWORLD_HTTP_STARTUP_FAILED=sqlite_schema_version_unsupported`. Labels never include paths, SQL, keys, verifiers, tokens or provider exceptions. An unknown version, a different structure, or unrecognized tables in an unversioned file are refused without deleting or rewriting anything. There is no fallback to an in-memory database.

On `quit` the RootActor stops accepting connections and lets admitted requests finish. Then it closes the Connection, observing its terminal Future, and stops. Closing never commits an unfinished transaction: SQLite rolls it back. Ctrl-C terminates the process without a graceful drain. SQLite's WAL recovery then restores the last committed state the next time the database is opened.

## Transactions and failure handling

Every mutation runs synchronously inside one `BEGIN … COMMIT` on the RootActor's Connection. Statements are closed before `COMMIT`. A rejected domain result rolls back, so no partial change is published. A response reports success only after SQLite confirms `COMMIT`.

- **Registration:** the password is hashed and the subject generated first. Uniqueness is rechecked and the JWT is signed before the transaction opens. The identity and credential rows (subject, Argon2id verifier, generation `1`) are then inserted in one transaction. If anything fails before `COMMIT`, no account exists.
- **Account update:** metadata and a new password verifier are written in the same transaction. A password change increments the generation exactly once. The response token is prepared before the transaction, for the generation the commit will establish, and is returned only after `COMMIT`. Tokens with an older generation stay invalid, across restarts too.
- **Login:** after Argon2id verification, the identity and credential rows are read again. The ID, current email, subject, verifier and generation must all be unchanged.
- **Uncertain COMMIT:** the error is not retried and the operation is not repeated. A remaining transaction is rolled back if possible, and the connection is marked unusable for any further reads or writes. The failing request receives a sanitized `503`. The RootActor then answers `503` to everything and starts a graceful shutdown rather than continuing on an unreliable connection.
- Known uniqueness conflicts remain `409`, validation `422`, missing resources `404`, foreign ownership `403` and invalid credentials `401`. Unexpected SQLite errors (locks beyond the busy timeout, I/O errors, corruption) are operational failures and produce `503`. They never become `409` or a success status.

## Database files and preserving data

SQLite in WAL mode keeps two companion files next to the database: `<name>-wal` and `<name>-shm`. They belong to the database while any process has it open or after an unclean stop.

- Never delete or copy the `-wal`/`-shm` files separately from the database file.
- Back up a stopped server's database together with its companion files, or use SQLite's own backup tools.
- Keep the same `REALWORLD_JWT_KEY_BASE64URL` to keep issued tokens valid. Changing it invalidates every token, but no stored data.
- Do not set `REALWORLD_DB_CREATE=1` for an existing database. It is not needed, and it is never a way to "reset" anything: existing files are validated, not recreated.
- Only one server process should use a database file. The busy timeout handles brief lock contention; it is not a multi-writer design.
- A database written by a newer schema version is refused, never downgraded.

## Security and platform limitations

- Authorizing `sqlite3` runs **trusted native code** inside the Protos process, with the operating-system permissions of that process. SQLite reads and writes files (the database, WAL/SHM and temporary files) outside any Protos `Filesystem` capability. A native fault can corrupt memory or terminate the process. `std:sqlite` is not a sandbox.
- Supported configurations: Linux x86-64 with the Native executable (integrated FFM provider, I170 or newer), or with the portable JVM, JDK 25 and the external provider JAR. Other platforms and C ABIs are unsupported. Native support does not embed SQLite: the host's library is loaded only when `sqlite3` is explicitly authorized.
- Durability of a confirmed `COMMIT` depends on SQLite's configuration, the filesystem and the storage device. `synchronous=FULL` is used, but no universal power-loss guarantee is made.
- The HTTP listener has no TLS and binds to loopback only. Production use would need transport protection, supervision, rate limits and a key-custody/rotation policy.

## HTTP routes

Send an authenticated request with exactly one header:
`Authorization: Token <compact-jwt>`. Duplicate Authorization headers, malformed schemes/tokens, expired tokens and unverified claims never grant a principal. Public GETs support viewer-aware projections when valid credentials are supplied.

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

Article lists and feeds sort newest first by parsing ISO8601 timestamps and comparing exact Instants, including timestamps with different fractional-second precision. Filters, pagination and counts before pagination are preserved. Article lists omit `body`; details include it. Profiles and authors derive `following` from the stable-ID follow graph, and articles derive `favorited` from the stable-ID favorite graph. Anonymous projections use false. Usernames and emails can change without changing the numeric ID, so ownership, follows, favorites and comments survive renames. Comment IDs are never reused.

## Authentication

The application uses the public Standard Library password, JWT, Base64url, Instant, ISO8601, JSON, HTTP Router and SQLite interfaces. Passwords are hashed and verified with the Standard Library's Argon2id provider. There are no application-private cryptographic, Base64url or time implementations, and no Java launcher.

JWTs use issuer and audience `protos-realworld`, protected type `realworld-access+jwt`, a maximum lifetime of 3600 seconds and zero clock skew. Subjects are immutable random public identifiers, independent of username and email. The persistent credential generation revokes earlier tokens after a password change. Every issuance and verification observes a fresh trusted Instant. Only the Argon2id verifier is stored, never the password. The signing key is never stored.

Registration and password changes require at least eight Unicode characters and accept passwords of 64 characters or more, without composition rules. The input limit is 4096 UTF-8 bytes. Usernames and emails are exactly (case-sensitively) unique. Profile `bio` and `image` accept null, and empty strings normalize to null. Omitted update fields remain unchanged. Article titles are limited to 1024 UTF-8 bytes. Duplicate titles receive deterministic distinct slugs, and updates preserve existing slugs.

## Tests

```sh
make test
make test-sqlite
make test-sqlite-restart
make test-sqlite-failures
```

`make test` needs no SQLite authorization. The SQLite targets run with the configured `PROTOS` executable, `PROTOS_ARGS` and `SQLITE_ARGS`. Native Image is the preferred mode. The portable JVM is a supported alternative when it is configured explicitly with the external provider. SQLite authorization denial is tested in both modes. The negative scenario that removes the external provider applies only to JVM mode. With an integrated-provider runner it is skipped and reported as `SQLITE_EXTERNAL_PROVIDER_NEGATIVE=NOT_APPLICABLE_INTEGRATED`, not as a pass. Running the same entry points in both modes does not by itself show that their behavior is identical.

| Command | What it exercises | Needs |
| --- | --- | --- |
| `make test` | In-memory domain, JSON, routing and secure-authentication tests | Entropy/Clock grants only, no SQLite authorization |
| `make test-sqlite` | Repositories, schema, transactions, rollback, persistent Argon2id/JWT credentials, on temporary files | `PROTOS`, `PROTOS_ARGS`, `SQLITE_ARGS` |
| `make test-sqlite-restart` | Independent processes: commit and reopen, token revocation after restart, SIGKILL during an open transaction and after a confirmed commit, HTTP data across a server restart | `PROTOS`, `PROTOS_ARGS`, `SQLITE_ARGS`, free port 3000 |
| `make test-sqlite-failures` | Lock contention within the busy timeout, unknown schema version, incompatible schema, foreign content, missing `sqlite3` authorization, missing external provider (JVM only), corrupt file | `PROTOS`, `PROTOS_ARGS`, `SQLITE_ARGS`, free port 3000 |
| `make test-http` | Native TCP scenario against a running server | `make serve` on a new disposable database |
| `make test-http-lifecycle` | Workers, request limits, drain and abort on an ephemeral listener | Network grant |
| `make test-hurl` / `make test-hurl-official` | Official RealWorld Hurl suite, unmodified | Running server on a new database, Hurl, the spec checkout |
| `make test-hurl-adjusted` | Compatibility variant: after a password change, the next request uses the returned token | Same as above |

The SQLite tests create their databases in fresh temporary directories outside the repository and remove them afterwards. They never reuse another test's state. For the HTTP and Hurl suites, start the server on a throwaway database, for example:

```sh
REALWORLD_DB_CREATE=1 REALWORLD_DB_PATH="$(mktemp -d)/http.db" make serve
```

`make test-hurl` uses the checkout at `/tmp/realworld-spec`. Override it with `REALWORLD_SPEC=/path/to/realworld-spec`, and the server origin with `HOST=http://127.0.0.1:3000` (without `/api`). The adjusted variant applies the tracked [`hurl-refresh-token.patch`](src/tests/hurl-refresh-token.patch) to a temporary copy, because this implementation revokes the token used before a password change. A result from the adjusted variant is not an official conformance result.

## Contributions

See [`TODO.md`](TODO.md) for outstanding work, [`CONTRIBUTING.md`](CONTRIBUTING.md) for contribution guidance, and [GitHub Issues](https://github.com/guillermomolina/protos-realworld-example-app/issues) to report a reproducible problem or propose an improvement. For the language itself, see the [Protos repository](https://github.com/guillermomolina/protos) and the [language website](https://protos.guillermomolina.com/).

The [RealWorld backend specification](https://docs.realworld.show/specifications/backend/introduction/) and its official Hurl suite define conformance. Local assertions do not establish it.
