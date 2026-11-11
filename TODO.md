# TODO — RealWorld backend in Protos

## Remaining application work

### I153-H1 durable persistence (D255-H1 = E+A): implemented, UNVERIFIED, NOT accepted

Implemented in source, but not compiled, run or validated yet:

- [x] Journal frame codec, domain schema v1, deterministic bounded recovery.
- [x] RootActor-owned journal: `createNew` lock, preprovisioned journal,
  partial-write handling, `sync()` before acknowledgement, fault poisoning.
- [x] Transaction coordinator: gate across suspension, bounded queue, staged
  candidate, publish after sync. All mutating routes go through it.
- [x] Store export/restore with invariant validation. Restored subjects and
  generations keep tokens and revocation valid across restarts.
- [x] Durable bootstrap and shutdown in `main.protos`. `make init-data`,
  `--allow-filesystem`, `make test-persistence`, `make test-restart`.
- [x] Tests written: codec, recovery, coordinator, fault injection, durable
  HTTP, and the external restart harness. Docs: `docs/persistence.md`.

Still pending:

- [ ] Run `make test`: the 12 existing groups plus the 5 new persistence groups.
  Fix any API mismatches, especially the File/Filesystem/Path calls listed under
  assumptions in `docs/persistence.md` and in the implementation report.
- [x] R1 correction pass: `filesystem.remove`, explicit open options, no
  write byte-count assumption, torn-tail sequence check, publish scoping.
- [ ] Re-run `make test-http`, `make test-http-lifecycle` and `make test-hurl`
  against the durable server on a fresh data directory.
- [ ] Run `make test-restart` (real restart, second writer, SIGKILL, stale lock,
  corruption and tail repair) and record the platform, runtime and results.
- [ ] Real crash testing beyond SIGKILL (power loss / OS crash) is not planned
  for this example. Durability claims remain limited to what `File.sync()`
  guarantees.
- [ ] Validate on JVM and, separately, on Native before claiming either.
- [ ] I153 acceptance by its owner after the evidence above exists.

## Optional work for deployment

These tasks are needed for a production deployment, not to run the learning
example locally:

- [ ] Configure HTTPS and deployment supervision.
- [ ] Add request/rate limits appropriate to the deployment. The existing HTTP
  request-body size limit is already implemented and tested.
- [ ] Define secure storage and rotation of the production JWT signing key.
  `make serve` generates a temporary development key only when none is configured.
- [ ] Connect process shutdown signals to graceful drain. The manual `quit`
  command and the drain/abort lifecycle already work.

Using `std:http/host` is a possible future refactor, not a missing feature or a
requirement for completing this example.

## Implemented and validated

- All 19 Slice 12 routes: registration/login, account retrieval/update, profiles,
  follows, feed, article CRUD, comments, favorites and tags.
- Standard Library Argon2id and JWT authentication, stable subjects and ownership,
  token revocation after password changes, atomic registration and account updates.
- Input validation, unique slugs, chronological ordering, filters, pagination and
  viewer-aware JSON presentation.
- RootActor-owned state and security authority, two HTTP Workers, bounded request
  snapshots and safe logs.

Historical results reported by the maintainer on **2026-11-09** (before the
persistence slice; not yet re-run), with the Protos
`0.3.459-SNAPSHOT` development baseline:

| Command | Result |
| --- | --- |
| `make test` | All 12 groups PASS, including secure authentication HTTP |
| `make test-http` | `REALWORLD_NATIVE_HTTP=PASS` |
| `make test-http-lifecycle` | All five checks PASS: concurrent Workers, request envelope, body limit, drain and abort |
| `make test-hurl` | All 13 files and 157 requests succeeded; zero failed files |

## Hurl compatibility note

`make test-hurl` applies the tracked token-refresh patch to a temporary copy of
external tests. After a password change, the next request uses the token returned
by that change. The original test reused the revoked token and therefore received
HTTP 401. This adjustment preserves the application's token-revocation requirement
and does not modify the external checkout.

All 157 requests pass with this documented adjustment. This is an adapted-suite
result, not a claim that the unmodified official suite passes. Its exact external
revision was not recorded in the reported run. Proposing the test correction
upstream is optional and does not block application development.

No Standard Library blocker has been identified by the reported validations.

## Publication and release hygiene

- [ ] Verify a clean checkout builds and passes the tests using only documented
  steps.
- [ ] Record the exact upstream RealWorld spec and Hurl revision used for
  conformance runs. The current distinction remains: 12/13 files pass
  unmodified, and 13/13 (157 requests) pass with the documented token-refresh
  adjustment.
- [ ] Accept Native execution only after a validated Native run.
