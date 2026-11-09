# TODO — RealWorld backend in Protos

## Remaining application work

- [ ] Durable persistence: save accounts, password verifiers, JWT subjects and
  generations, articles, comments, follows and favorites. Restore the same
  identities and relationships after restarting the process.
- [ ] Add restart/recovery tests when persistence is implemented.

The current backend stores everything in memory. Restarting loses all accounts
and domain data. Persistence is the main remaining application feature; the
implemented HTTP routes and authentication have passed the checks listed below.

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

Results reported by the maintainer on **2026-11-09**, with the Protos
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
