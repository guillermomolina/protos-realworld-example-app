# Durable persistence: storage protocol and operator contract

This document describes the RealWorld application's private journal format,
its recovery rules and how to operate it. The format is private to this
application. It is not a general storage format or a Protos Standard Library
facility.

Architecture authority: D255-H1 (E+A), ratified in D255 #1107. Execution is
tracked by I153 #1068.

## 1. Overview

```text
HTTP Worker ──request data──▶ RootActor
                               │
                               ├─ Api / Auth           (unchanged routes and responses)
                               ├─ DurableStore         transaction gate, fault state
                               │    ├─ MemoryStore     committed domain (published state)
                               │    └─ Journal         lock + append-only File + sync()
                               └─ Filesystem grant     --allow-filesystem=<data dir>
```

* There is one cooperative writer: one RootActor in one process. It owns all
  mutable domain state, the journal File and the lock.
* The journal is a preprovisioned regular file, `realworld.journal`, in the
  granted data directory. The lock is `realworld.journal.lock`, in the same
  directory.
* Each successful domain-changing request is one logical transaction. The
  RootActor prepares it on an independent candidate state, appends one frame,
  completes `File.sync()`, then publishes the candidate. Only after that does
  it return the success response.
* Startup runs complete recovery before the listener opens. The listener and
  `REALWORLD_HTTP_READY` never come first. The server never falls back to an
  in-memory store.

Source files: `src/app/persistence/{JournalCodec,DomainCodec,Recovery,Journal,DurableStore}.protos`,
plus export and restore operations in the existing store modules.

## 2. Binary framing (journal format version 1)

The file is a sequence of frames starting at offset 0. It has no file
header. All integers are unsigned and big-endian, with the widths shown.

| Offset | Width | Field | Rule |
| --- | --- | --- | --- |
| 0 | 4 | magic | `50 52 57 4A` (`PRWJ`) |
| 4 | 1 | version | `1`. Any other value is rejected. |
| 5 | 1 | flags | `0` |
| 6 | 2 | reserved | `0` |
| 8 | 8 | sequence | `1 … 9007199254740991`. Consecutive within a file. |
| 16 | 16 | transaction ID | Opaque. Must not be all zero. |
| 32 | 4 | length *n* | `0 … maxPayloadBytes` |
| 36 | *n* | payload | Domain transaction (§3) |
| 36+*n* | 4 | Adler-32 | RFC 1950, over octets `[0, 36+n)` |
| 40+*n* | 4 | polyhash | `h = (h·257 + b + 1) mod 4294967291` over octets `[0, 36+n)`, starting from `h = 0` |

The frame size is `44 + n`. The 8-octet checksum covers every header field
and the payload. It detects accidental damage only. It is **not**
cryptographic and provides no authenticity: anyone who can write the file can
forge frames.

Transaction ID = an 8-octet nonce drawn from Entropy once per process start,
followed by the 8-octet sequence. It identifies the journal record. It is not
an HTTP request identity, and no exactly-once network delivery is promised.

### Decoder classification

When the decoder reads at an offset, the octets there fall into exactly one
of these classes:

| Class | Condition |
| --- | --- |
| `eof` | The offset is the end of the data. |
| `frame` | The header is valid, the frame is complete and the checksum matches. |
| `incomplete` | A strict prefix of a plausible frame (a magic/version prefix, a partial header, or a valid header with missing payload or trailer), or an all-zero remainder. |
| `corrupt` | Anything else, with one reason: `magic`, `unsupported_version`, `reserved_bits`, `sequence_overflow`, `illegal_sequence`, `malformed_transaction_id`, `oversized_frame` or `checksum`. |

The length field is checked against `maxPayloadBytes` before any payload is
copied. Every decoded field is returned as an independent copy.

## 3. Domain schema (payload version 1)

The payload is the UTF-8 JSON text of one object. Its members are, in this
order: `schema` (`"protos-realworld-domain"`), `version` (`1`),
`operation` (a label), `nextIdentityId`, `nextCommentId`, `accounts`,
`articles`, `comments`, `follows` and `favorites`. Field lists are in
`DomainCodec.protos`.

Version 1 stores the **complete committed domain after the transaction**.
Recovery therefore never merges partial updates. A cascade, such as an
article deleted together with its comments and favorite edges, is one record.
Collections keep their deterministic repository insertion order. No hash-map
order is ever serialized. Integers are exact JSON integers. Decoding rejects
unknown members, missing members, wrong kinds, fractional or exponent
integers, invalid UTF-8 and values outside the limits.

Persisted data:

* Accounts: id, username, email, bio and image (nullable), JWT subject,
  Argon2id verifier, credential generation.
* Articles, comments and both counters.
* Follow edges and favorite edges, by stable ID or slug.

Never persisted: plaintext passwords, the JWT signing key, issued tokens,
Closures, ActorRefs, Futures, capabilities, Files and HTTP responses.

## 4. Limits

| Limit | Default |
| --- | --- |
| Frame payload (`maxPayloadBytes`) | 8 MiB |
| Journal size (`maxJournalBytes`) | 1 GiB |
| Frames (`maxFrames`) | 1,000,000 |
| Accounts / articles | 100,000 each |
| Comments / edges | 1,000,000 each |
| Username / email / title | 256 / 1024 / 1024 UTF-8 octets |
| Long text fields | 1 MiB |

Every transaction stores a full state, so the journal grows by roughly the
size of the whole domain on each write. This design is meant for a learning
example and modest data sets. When `maxJournalBytes` would be exceeded, the
write fails before any I/O and the client receives a sanitized 503 response.
Compaction and snapshots are explicitly out of scope (see §11).

## 5. Recovery rules

1. Start from an empty domain.
2. Sequences must be 1, 2, 3, … with no gap or repetition.
3. For each frame: decode the payload strictly, validate the complete domain
   (uniqueness, references, counters, timestamps, verifier framing), then
   check the transition from the previous domain. Accounts are never lost.
   Subjects never change. Generations never decrease, so revocations survive.
   Counters never move backwards. No new ID may appear below a previous
   counter.
4. **Idempotence rule:** a frame with the same transaction ID and a
   byte-identical payload as the immediately preceding applied frame is an
   exact retransmission. It consumes its sequence number but is not applied
   again. Any other reuse of a transaction ID is rejected.
5. An invalid interior frame is never skipped. Startup fails.
6. Only the final region of the file may be `incomplete`: a strict prefix whose header, if complete, is valid and carries the next expected sequence, or an all-zero remainder. A complete frame with a bad checksum, unsupported version or invalid domain is never treated as a torn tail and never repaired. Earlier frames are
   kept. Startup then **refuses** with
   `REALWORLD_JOURNAL_FAILURE=incomplete_tail_requires_repair`. Appending
   after torn octets would turn them into interior corruption.
7. A complete, checksum-valid final frame is **applied**.
8. Size, frame-count and frame-size limits are enforced. Any failure produces
   no domain at all. A partially recovered state is never published.

### Uncertain acknowledgement

A frame can be fully written to disk while its `sync()` never reported
success. For example, the process was killed between the write and the
acknowledgement, or `sync()` failed after the device accepted the octets. The
client then received an error, or no response at all. Recovery cannot
distinguish that frame from an acknowledged commit, and a valid checksum is
not evidence of acknowledgement. The contract is:

* **An acknowledged success is durable**, subject to the platform guarantees
  in §8.
* **An unacknowledged transaction may or may not survive.** If its complete
  frame survives, it is committed at the next start. If the frame is torn, it
  never happened.
* There is no automatic rollback after an uncertain write. Clients that
  retry after an error may apply their change twice. Most RealWorld writes
  are idempotent, but article creation creates a second article with a new
  slug.

### Explicit tail repair

After checking that no server is running, an operator may authorize one
repair for one start:

```sh
REALWORLD_JOURNAL_REPAIR=truncate-incomplete-tail make serve
```

The repair truncates the file at the end of the last complete frame. By
protocol, those torn octets were never acknowledged. It then calls `sync()`.
Corruption anywhere else is never repaired automatically. Restore it from a
backup.

## 6. Commit protocol and runtime faults

```
admit (gate) → stage candidate → prepare (validate, Argon2id, Entropy, token)
  → validate complete candidate → encode → seek(end) → write… → sync()
  → publish (no suspension) → release gate → respond
```

* `Future.value()` may suspend the RootActor turn. The gate stays held across
  hashing, writes and `sync()`, so competing writes queue behind it. The
  queue is bounded (64 by default). Overload, or a write during shutdown,
  gets a sanitized 503 response.
* Reads use the committed store, which changes only at the publish step.
* Writes: the frame is written in bounded chunks. A chunk counts as accepted
  only when its `write` Future succeeds; its result is not read as a byte
  count. A failed write may have committed a prefix, so it is never retried.
* A failure before the first `write` call, for example a failed seek or a
  quota or validation error, leaves the state unchanged and the journal
  usable.
* A failure after the first `write` call (a write error, a `sync()` error, or
  a cancellation) is **uncertain**. The candidate is not published. The
  journal and the coordinator become permanently faulted for this process.
  Every later write returns 503, reads continue to serve the last committed
  state, and a restart resolves the outcome through recovery.
* A failure is never converted into an empty store, and a success response
  is never sent based on unsynchronized state.

## 7. Cooperative writer lock

* Startup creates `realworld.journal.lock` with `createNew`, then writes and
  syncs a fixed marker line.
* If the lock already exists, startup fails with `lock_unavailable`. This
  happens both when another server is running and when a crashed server left
  the lock behind. **The lock is never stolen automatically.**
* A graceful shutdown (`quit`) drains HTTP, waits for the transaction in
  progress, closes the journal and then removes the lock with `filesystem.remove`. If closing the File
  fails or a write is still in flight, the lock is **kept**.
* The lock excludes only cooperating processes that follow this protocol. It
  is not distributed fencing. It cannot stop other programs from writing the
  file, and it provides no protection on network filesystems with weak
  create-exclusive semantics.

### Stale-lock recovery procedure

1. Make sure no RealWorld server is using the directory. Check the process
   list, any supervisor, and every host that can mount the directory.
2. Optionally, inspect `realworld.journal.lock`. It holds only the marker
   line.
3. Remove the lock: `rm <data-dir>/realworld.journal.lock`.
4. Start the server. If recovery reports an incomplete tail, follow §5.

`make serve` refuses to start while the lock exists, and prints a pointer to
this procedure.

## 8. Synchronization guarantees and exclusions

* `File.sync()` is the only durability primitive used. Its guarantee is
  whatever the Protos runtime and the host platform provide for that File's
  contents.
* No claim is made about the durability of directory entries (lock creation
  or deletion), about atomic renames, or about cross-file ACID properties. The
  design needs only the journal File's contents to be durable.
* `close()` is never assumed to synchronize anything.
* Fault-injection tests exercise the protocol. They do not prove power-loss
  durability. The process-restart harness uses SIGKILL, which kills a
  process, not the machine.
* JVM and Native-image behavior is claimed only where it has been validated.
  So far nothing has been validated.

## 9. Filesystem confinement

The server receives only `--allow-filesystem=<data dir>`. It builds paths
solely with `Path.relative().child(name)` below that root. It never parses
host paths or constructs absolute paths. HTTP Workers receive no Filesystem,
Journal, key or mutable state. Logs contain fixed labels only: no paths,
payloads, tokens or exception details.

Startup failure labels (`REALWORLD_JOURNAL_FAILURE=…`): `lock_unavailable`,
`lock_marker_failed`, `journal_unavailable`, `journal_read_failed`,
`journal_quota`, `corrupt_<reason>`, `sequence_gap`, `transaction_conflict`,
`domain_schema`, `domain_invariant`, `domain_transition`, `frame_limit`,
`incomplete_tail_requires_repair`, `tail_repair_failed`, `sync_unsupported`.

## 10. Security notes

* Verifiers are the Standard Library's opaque Argon2id records
  (`protos-password-v1:…`). They are stored unchanged and only their prefix
  is checked. Anyone who can read the journal can run offline guessing
  attacks against them, so protect the data directory like a password
  database, with restrictive permissions and encrypted backups.
* The JWT signing key is never persisted. Restarting with a different key
  keeps all data but invalidates every issued token. Restart authentication
  requires a stable, separately managed `REALWORLD_JWT_KEY_BASE64URL`.
* Subjects and generations are restored exactly. A token revoked by a
  password change stays revoked after a restart.

## 11. Versioning and migration

* The frame `version` and the payload `schema`/`version` are both checked,
  and unknown versions fail closed.
* Planned evolution path: a future version N adds a decoder for N and keeps
  decoders for all earlier versions. Recovery replays old frames with their
  own decoder and writes only version N frames afterwards. An offline,
  operator-run tool may rewrite a journal into a single version-N frame.
  None of this is implemented, and no generic migration framework exists.
* Compaction, snapshots, background maintenance and multi-process
  coordination are out of scope for I153-H1.

## 12. Fault-injection matrix

These cases are run by `make test`, using injected in-memory Files and no
Filesystem grant:

| Case | Expected outcome |
| --- | --- |
| Successful chunked write | Complete frame synced. Commit succeeds. |
| Write fails on first call | `faulted`, `uncertain_commit`. State not published. |
| Write fails after committing a prefix | `faulted`. Restart sees an incomplete tail. Never retried. |
| Seek fails (before any write) | Journal stays `ready`. Nothing written. |
| `sync()` fails | `faulted`. The frame applies if its octets survive, and is absent otherwise. |
| `close()` fails | Lock kept. State `faulted`. |
| Publish fails after a durable commit | Coordinator `faulted` until restart. |
| Read revoked during recovery | `journal_read_failed`. Startup refused. |
| Invalid transaction ID / commit before recovery | Rejected before I/O. |
| Missing preprovisioned journal | `journal_unavailable`. Own lock removed. |
| Lock exists (live or stale) | `lock_unavailable`. Lock untouched. |
| Second writer | `lock_unavailable` until the first closes. |
| Quota exceeded | Rejected before I/O. Journal stays `ready`. |
| File without `sync` | `sync_unsupported`. Startup refused. |
| Incomplete tail | `incomplete_tail_requires_repair`. File untouched. |
| Middle corruption | `corrupt_checksum`. Never skipped. |

## 13. Real restart acceptance criteria

`make test-restart` (`src/tests/restart-integration.py`) must print every
step marker and then `REALWORLD_RESTART_INTEGRATION=PASS`. The steps:

1. A missing Filesystem grant or a missing journal is refused without
   readiness.
2. A populated server stops gracefully and releases the lock. After a
   restart, identities, the article, the comment, the follow, the favorite,
   the counters and the new password are all intact. A token issued before
   the restart still works with the same key, and the revoked token is still
   rejected. A new comment receives a new ID.
3. A second concurrent server is refused.
4. After SIGKILL the lock remains and a restart is refused. Once the operator
   removes the lock, an acknowledged write is present.
5. Middle corruption in a disposable copy is refused. A torn tail is refused
   and left unmodified, then recovers only with the explicit repair setting,
   which truncates exactly back to the last complete frame.

Until this harness has been run and reported on a named platform and
runtime, durability is implemented but **not accepted**. Test execution
status: **UNVERIFIED** (nothing in this slice has been compiled or run).
