#!/usr/bin/env bash
# Multi-process SQLite validation for the RealWorld server.
#
# Usage: src/tests/test-sqlite-processes.sh restart|failures|all
#   restart   independent processes: commit, reopen, revocation, SIGKILL during
#             an open transaction, SIGKILL after a confirmed commit, recovery,
#             and HTTP data surviving a server restart;
#   failures  lock contention, unknown schema version, incompatible schema,
#             foreign content, missing sqlite3 authorization, missing external
#             FFM provider (JVM mode only) and a corrupt database file.
#
# Environment:
#   PROTOS       Protos executable (default: protos). Normally the installed
#                Native executable, whose FFM provider is integrated.
#   PROTOS_ARGS  optional execution arguments. For the portable JVM it must
#                also carry --foreign-provider-path /absolute/path/provider.jar.
#   SQLITE_ARGS  SQLite authorization, e.g. --allow-library sqlite3=libsqlite3.so.0.
# The effective arguments are PROTOS_ARGS followed by SQLITE_ARGS, in order, and
# must authorize the alias sqlite3 (separate-token or --allow-library=... form).
# Every database lives in a fresh temporary directory outside the repository,
# removed on exit. Synchronization uses markers printed by the fixtures, never
# a fixed sleep standing in for a commit. Uses bash >= 4.4, mkfifo, timeout,
# sha256sum and base64.
set -euo pipefail

cd "$(dirname "$0")/../.."

mode="${1:-all}"
case "$mode" in
    restart|failures|all) ;;
    *) echo "usage: $0 restart|failures|all" >&2; exit 2 ;;
esac

PROTOS="${PROTOS:-protos}"
read -r -a INPUT_PROTOS_ARGS <<< "${PROTOS_ARGS:-}"
read -r -a INPUT_SQLITE_ARGS <<< "${SQLITE_ARGS:-}"
ARGS=("${INPUT_PROTOS_ARGS[@]}" "${INPUT_SQLITE_ARGS[@]}")

# Value of every occurrence of flag (separate-token or flag=value), one per line.
pair_values() {
    local flag=$1 previous=""
    for word in "${ARGS[@]}"; do
        if [[ $previous == "$flag" ]]; then printf '%s\n' "$word"
        elif [[ $word == "$flag="* ]]; then printf '%s\n' "${word#"$flag="}"
        fi
        previous=$word
    done
    if [[ $previous == "$flag" ]]; then printf '\n'; fi
}
sqlite_grant=0
while IFS= read -r mapping; do
    case "$mapping" in
        sqlite3=*=*|sqlite3=|sqlite3) echo "malformed sqlite3 authorization" >&2; exit 2 ;;
        sqlite3=?*) sqlite_grant=1 ;;
        *=?*) ;;   # another explicitly authorized alias, preserved
        *) echo "malformed --allow-library mapping: $mapping" >&2; exit 2 ;;
    esac
done < <(pair_values --allow-library)
((sqlite_grant)) || { echo "PROTOS_ARGS/SQLITE_ARGS must include --allow-library sqlite3=<library>" >&2; exit 2; }

# An external provider is used only when the caller supplied one (JVM mode).
EXTERNAL_PROVIDER=0
if [[ -n $(pair_values --foreign-provider-path) ]]; then EXTERNAL_PROVIDER=1; fi

# Copy ARGS without one "flag value" pair (also accepting flag=value).
STRIPPED=()
strip_pair() {
    local flag=$1 pattern=$2 skip=0
    STRIPPED=()
    for word in "${ARGS[@]}"; do
        if ((skip)); then
            skip=0
            if [[ $word == $pattern ]]; then continue; fi
            STRIPPED+=("$flag")
        fi
        if [[ $word == "$flag" ]]; then skip=1; continue; fi
        if [[ $word == "$flag="$pattern ]]; then continue; fi
        STRIPPED+=("$word")
    done
    if ((skip)); then STRIPPED+=("$flag"); fi
}
strip_pair --allow-library 'sqlite3=*'
NO_LIBRARY=("${STRIPPED[@]}")
NO_PROVIDER=()
if ((EXTERNAL_PROVIDER)); then
    strip_pair --foreign-provider-path '*'
    NO_PROVIDER=("${STRIPPED[@]}")
fi
FIXTURE=("$PROTOS" "${ARGS[@]}" --allow-entropy --allow-clock src/sqlite-process-main.protos)

work=$(mktemp -d "${TMPDIR:-/tmp}/realworld-sqlite.XXXXXX")
KEY=$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')
pids=()
cleanup() {
    for pid in "${pids[@]}"; do kill -KILL "$pid" 2>/dev/null || true; done
    rm -rf "$work"
}
trap cleanup EXIT

fail() {
    echo "SQLITE_PROCESS_TEST_FAILED=$1" >&2
    exit 1
}

show() { sed 's/^/    | /' "$1" >&2; }

# Run a fixture scenario to completion; require exit 0 and its exact marker.
scenario() {
    local marker=$1; shift
    local log="$work/$1.$RANDOM.log" status=0
    timeout 180 "$PROTOS" "${ARGS[@]}" --allow-entropy --allow-clock \
        src/sqlite-process-main.protos "$@" < /dev/null > "$log" 2>&1 || status=$?
    if ((status != 0)); then show "$log"; fail "$1 exited with $status"; fi
    grep -qx "$marker" "$log" || { show "$log"; fail "$1 marker $marker missing"; }
    echo "  ok: $1"
}

# Start a fixture or server in the background with stdin attached to a FIFO
# held open by this shell, so the controller can release or stop it later.
held_pid=""
held_fd=""
held_log=""
start_held() {
    local name=$1; shift
    local fifo="$work/$name.fifo"
    held_log="$work/$name.log"
    mkfifo "$fifo"
    "$@" < "$fifo" > "$held_log" 2>&1 &
    held_pid=$!
    pids+=("$held_pid")
    exec {held_fd}> "$fifo"
}

# Wait until a marker line appears; fail if the process exits first or the
# bounded wait expires. The marker, not the elapsed time, is the signal.
wait_marker() {
    local pattern=$1 pid=$2 log=$3
    for _ in $(seq 1 1800); do
        if grep -q "$pattern" "$log"; then return 0; fi
        if ! kill -0 "$pid" 2>/dev/null; then show "$log"; fail "process exited before $pattern"; fi
        sleep 0.1
    done
    show "$log"
    fail "timeout waiting for $pattern"
}

# Wait for a background process, requiring an exact exit status.
reap() {
    local pid=$1 expected=$2 label=$3 status=0
    wait "$pid" || status=$?
    if ((status != expected)); then fail "$label exited with $status, expected $expected"; fi
}

kill_held() {
    local label=$1
    kill -KILL "$held_pid"
    reap "$held_pid" 137 "$label"
    exec {held_fd}>&-
    echo "  ok: $label killed with SIGKILL at its synchronization point"
}

# The real server must not announce readiness and must actually terminate.
server_must_not_start() {
    local label=$1 db=$2; shift 2
    local log="$work/server-$label.log" status=0
    env -u REALWORLD_DB_CREATE REALWORLD_DB_PATH="$db" REALWORLD_JWT_KEY_BASE64URL="$KEY" \
        timeout 180 "$PROTOS" "$@" --allow-network --allow-entropy --allow-clock \
        --service=service src/main.protos < /dev/null > "$log" 2>&1 || status=$?
    if grep -q '^REALWORLD_HTTP_READY=' "$log"; then show "$log"; fail "$label: server announced readiness"; fi
    if ((status == 124)); then show "$log"; fail "$label: server did not terminate"; fi
    if ((status == 0)); then show "$log"; fail "$label: server exited successfully"; fi
    echo "  ok: $label prevents server readiness (exit $status)"
}

# A fixture run that must fail without printing any success marker.
fixture_must_fail() {
    local label=$1; shift
    local log="$work/fixture-$label.log" status=0
    timeout 180 "$PROTOS" "$@" --allow-entropy --allow-clock \
        src/sqlite-process-main.protos verify "$work/restart.db" < /dev/null > "$log" 2>&1 || status=$?
    if grep -q '=OK$' "$log"; then show "$log"; fail "$label: fixture reported success"; fi
    if ((status == 0 || status == 124)); then show "$log"; fail "$label: fixture exit $status"; fi
    echo "  ok: $label fixture fails (exit $status)"
}

start_server() {
    local name=$1 db=$2 create=$3
    if [[ $create == 1 ]]; then
        start_held "$name" env REALWORLD_DB_CREATE=1 REALWORLD_DB_PATH="$db" REALWORLD_JWT_KEY_BASE64URL="$KEY" \
            "$PROTOS" "${ARGS[@]}" --allow-network --allow-entropy --allow-clock --service=service src/main.protos
    else
        start_held "$name" env -u REALWORLD_DB_CREATE REALWORLD_DB_PATH="$db" REALWORLD_JWT_KEY_BASE64URL="$KEY" \
            "$PROTOS" "${ARGS[@]}" --allow-network --allow-entropy --allow-clock --service=service src/main.protos
    fi
    wait_marker '^REALWORLD_HTTP_READY=127.0.0.1:3000$' "$held_pid" "$held_log"
}

stop_server() {
    local label=$1
    printf 'quit\n' >&"$held_fd"
    reap "$held_pid" 0 "$label"
    exec {held_fd}>&-
}

http_client() {
    local log=$1; shift
    local status=0
    timeout 180 "$PROTOS" "${ARGS[@]}" --allow-network src/tests/sqlite-http-restart.protos "$@" \
        < /dev/null > "$log" 2>&1 || status=$?
    if ((status != 0)); then show "$log"; fail "http client $1 exited with $status"; fi
}

run_restart() {
    local db="$work/restart.db"
    echo "SQLITE_PROCESS_RESTART=START"
    # 1-2. Process A creates and commits data, then terminates.
    scenario SQLITE_PROCESS_INIT=OK init "$db"
    # 3. Process B opens the same file and checks every record.
    scenario SQLITE_PROCESS_VERIFY=OK verify "$db"
    scenario SQLITE_PROCESS_REVOCATION=OK revocation "$db"
    # 4-5. Process C writes inside an open transaction and is killed there.
    start_held hold-uncommitted "${FIXTURE[@]}" hold-uncommitted "$db"
    wait_marker '^SQLITE_PROCESS_UNCOMMITTED_READY=1$' "$held_pid" "$held_log"
    kill_held hold-uncommitted
    # 7. Another process commits, reports the confirmed commit, is killed.
    start_held hold-committed "${FIXTURE[@]}" hold-committed "$db"
    wait_marker '^SQLITE_PROCESS_COMMITTED=1$' "$held_pid" "$held_log"
    kill_held hold-committed
    # 6. Process D recovers: no partial effect, committed data present.
    scenario SQLITE_PROCESS_RECOVERED=OK check-recovered "$db"

    # The HTTP server keeps accounts, content and revocation across restarts.
    local http_db="$work/http.db" before="$work/http-before.log" after="$work/http-after.log"
    start_server http-first "$http_db" 1
    http_client "$before" before
    grep -qx 'SQLITE_HTTP_BEFORE=PASS' "$before" || { show "$before"; fail "http before"; }
    local old_token
    old_token=$(sed -n 's/^SQLITE_HTTP_OLD_TOKEN=//p' "$before")
    [[ -n $old_token ]] || fail "http before: missing old token"
    stop_server http-first
    start_server http-second "$http_db" 0
    http_client "$after" after "$old_token"
    grep -qx 'SQLITE_HTTP_AFTER=PASS' "$after" || { show "$after"; fail "http after"; }
    stop_server http-second
    echo "  ok: http data and revocation survive a server restart"
    echo "SQLITE_PROCESS_RESTART=PASS"
}

run_failures() {
    echo "SQLITE_PROCESS_FAILURES=START"
    local db="$work/restart.db"
    if [[ ! -f $db ]]; then scenario SQLITE_PROCESS_INIT=OK init "$db"; fi

    # 8. One process holds the write lock; another waits busy_timeout and fails.
    start_held hold-lock "${FIXTURE[@]}" hold-lock "$db"
    wait_marker '^SQLITE_PROCESS_LOCK_HELD=1$' "$held_pid" "$held_log"
    scenario SQLITE_PROCESS_BUSY_OBSERVED=OK contend-lock "$db"
    printf 'release\n' >&"$held_fd"
    reap "$held_pid" 0 hold-lock
    exec {held_fd}>&-
    grep -qx 'SQLITE_PROCESS_LOCK_RELEASED=OK' "$held_log" || { show "$held_log"; fail "hold-lock release"; }

    # 9. An unknown schema version prevents admission.
    local future="$work/future.db"
    scenario SQLITE_PROCESS_PREPARED=future_version set-future-version "$future"
    scenario SQLITE_PROCESS_REJECTED=schema_version_unsupported expect-reject "$future" schema_version_unsupported 0
    server_must_not_start future-version "$future" "${ARGS[@]}"

    # Incompatible structure at version 1, and foreign content at version 0
    # (even with creation authority) are refused without deleting anything.
    local mismatch="$work/mismatch.db" foreign="$work/foreign.db"
    scenario SQLITE_PROCESS_PREPARED=schema_mismatch schema-mismatch "$mismatch"
    scenario SQLITE_PROCESS_REJECTED=schema_mismatch expect-reject "$mismatch" schema_mismatch 0
    scenario SQLITE_PROCESS_PREPARED=foreign_content foreign-content "$foreign"
    scenario SQLITE_PROCESS_REJECTED=unrecognized_database_content expect-reject "$foreign" unrecognized_database_content 1
    scenario SQLITE_PROCESS_FOREIGN_PRESERVED=OK check-foreign-preserved "$foreign"

    # An absent database is not created without REALWORLD_DB_CREATE=1.
    server_must_not_start absent-database "$work/absent.db" "${ARGS[@]}"
    [[ ! -e $work/absent.db ]] || fail "absent database was created"

    # 10. Without sqlite3 authorization the library is not opened.
    fixture_must_fail no-sqlite3-authorization "${NO_LIBRARY[@]}"
    server_must_not_start no-sqlite3-authorization "$db" "${NO_LIBRARY[@]}"

    # 11. JVM mode only: without the external FFM provider (sqlite3 still
    # authorized) there is no false successful startup. An integrated-provider
    # runner has no external provider to remove; that one check is skipped.
    if ((EXTERNAL_PROVIDER)); then
        fixture_must_fail no-ffm-provider "${NO_PROVIDER[@]}"
        server_must_not_start no-ffm-provider "$db" "${NO_PROVIDER[@]}"
    else
        echo "SQLITE_EXTERNAL_PROVIDER_NEGATIVE=NOT_APPLICABLE_INTEGRATED"
    fi

    # 12. A corrupt file is reported, never replaced by an empty database.
    local corrupt="$work/corrupt.db" checksum
    head -c 8192 /dev/urandom > "$corrupt"
    checksum=$(sha256sum "$corrupt" | cut -d' ' -f1)
    scenario SQLITE_PROCESS_REJECTED=native_failure expect-reject "$corrupt" native_failure 0
    scenario SQLITE_PROCESS_REJECTED=native_failure expect-reject "$corrupt" native_failure 1
    server_must_not_start corrupt-database "$corrupt" "${ARGS[@]}"
    [[ $(sha256sum "$corrupt" | cut -d' ' -f1) == "$checksum" ]] || fail "corrupt database was modified"
    echo "  ok: corrupt database left unchanged"
    echo "SQLITE_PROCESS_FAILURES=PASS"
}

case "$mode" in
    restart) run_restart ;;
    failures) run_failures ;;
    all) run_restart; run_failures ;;
esac
