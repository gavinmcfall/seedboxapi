#!/bin/sh
# Regression test for the credential-destruction bug that took MAM session
# keeping down from 2026-10-20 to 2026-10-22.
#
# MAM rotates the mam_id when a session is created from it, so the configured
# seed value goes stale after first use. The old code cleared COOKIE_FILE before
# finding out whether the seed still worked, so a single transient failure
# destroyed the only working credential and left no way back without a human
# minting a new mam_id.
#
# These tests assert the invariant that prevents that: a failed request must
# never leave COOKIE_FILE worse than it found it.
#
# Run: sh test/session-safety.sh

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# Overridable so the suite can be pointed at an older wrapper.sh to confirm it
# still catches the regression it was written for.
WRAPPER="${WRAPPER:-${SCRIPT_DIR}/wrapper.sh}"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

# Build a sandbox with a stubbed curl whose behaviour the test controls.
#   $1 = body curl should emit on stdout (the MAM response)
#   $2 = if "writejar", the stub also writes a cookie jar to its -c target,
#        mimicking curl persisting a session; otherwise -c is left untouched.
setup() {
    SANDBOX=$(mktemp -d)
    mkdir -p "${SANDBOX}/bin" "${SANDBOX}/config"
    printf '%s' "$1" > "${SANDBOX}/response-body"
    printf '%s' "${2:-}" > "${SANDBOX}/stub-mode"

    cat > "${SANDBOX}/bin/curl" <<'STUB'
#!/bin/sh
# Stubbed curl: find the -c target, optionally write a jar, emit the body.
# Every invocation is recorded so the test can prove the code path ran.
jar=""
prev=""
for arg in "$@"; do
    [ "$prev" = "-c" ] && jar="$arg"
    prev="$arg"
done
echo "called jar=${jar}" >> "${SANDBOX}/stub.log"
if [ "$(cat "${SANDBOX}/stub-mode")" = "writejar" ] && [ -n "$jar" ]; then
    printf '# Netscape HTTP Cookie File\nt.myanonamouse.net\tFALSE\t/\tTRUE\t0\tmam_id\tFRESH\n' > "$jar"
fi
cat "${SANDBOX}/response-body"
STUB
    chmod +x "${SANDBOX}/bin/curl"

    # The script backgrounds a metrics server as `while true; do ... | nc -l; done`.
    # The stub must BLOCK: an nc that returns immediately turns that into a tight
    # spin loop that starves the script under test.
    for cmd in httpd nc busybox; do
        printf '#!/bin/sh\nsleep 3600\n' > "${SANDBOX}/bin/${cmd}"
        chmod +x "${SANDBOX}/bin/${cmd}"
    done

    GOOD_JAR='# Netscape HTTP Cookie File
t.myanonamouse.net	FALSE	/	TRUE	0	mam_id	WORKING_SESSION'
}

teardown() { [ -n "${SANDBOX:-}" ] && rm -rf "${SANDBOX}"; }

# Run wrapper.sh in the sandbox until $1 appears in its log, then stop it.
# Waiting on a marker rather than a fixed sleep matters: process spawning can be
# slow enough (notably on MSYS) that a timed wait returns before the script has
# touched the cookie at all, which would make "the cookie survived" pass
# vacuously. assert_probed() below closes that hole from the other side.
run_wrapper() {
    marker="$1"
    SANDBOX="${SANDBOX}" \
    COOKIE_FILE="${SANDBOX}/config/MAM.cookies" \
    TEMP_COOKIE_FILE="${SANDBOX}/tmp-jar" \
    RESPONSE_FILE="${SANDBOX}/response" \
    OLD_IP_FILE="${SANDBOX}/ip" \
    METRICS_FILE="${SANDBOX}/metrics.prom" \
    MAX_RETRIES="2" \
    RETRY_DELAY="1" \
    mam_id="STALE_SEED" \
    interval="60" \
    PATH="${SANDBOX}/bin:${PATH}" \
    sh "${WRAPPER}" >"${SANDBOX}/log" 2>&1 &
    WRAPPER_PID=$!

    waited=0
    while [ "${waited}" -lt 60 ]; do
        grep -q "${marker}" "${SANDBOX}/log" 2>/dev/null && break
        kill -0 "${WRAPPER_PID}" 2>/dev/null || break
        sleep 1
        waited=$((waited + 1))
    done
    kill "${WRAPPER_PID}" 2>/dev/null
    wait "${WRAPPER_PID}" 2>/dev/null
    grep -q "${marker}" "${SANDBOX}/log" 2>/dev/null
}

# Guard against vacuous passes: the stubbed curl must actually have been called.
assert_probed() {
    if [ -s "${SANDBOX}/stub.log" ]; then
        return 0
    fi
    bad "$1" "the script never reached the session logic (curl stub was never called) -- log: $(tr '\n' '|' < "${SANDBOX}/log" 2>/dev/null)"
    return 1
}

# ---------------------------------------------------------------------------
# 1. A valid cookie plus a failing probe must not destroy the cookie.
#    This is the exact shape of the 2026-10-20 incident.
# ---------------------------------------------------------------------------
T="failing probe leaves the working cookie intact"
setup '{"Success":false,"msg":"Invalid session - Other"}'
printf '%s\n' "${GOOD_JAR}" > "${SANDBOX}/config/MAM.cookies"
# "Failed to create session" is logged AFTER the curl, so it is the first marker
# that is guaranteed to be past the point where the old code deleted the cookie.
# Waiting on "Attempting to recreate session" instead races the deletion and
# lets the buggy version pass.
run_wrapper "Failed to create session"
if assert_probed "$T"; then
    if [ -s "${SANDBOX}/config/MAM.cookies" ] && grep -q WORKING_SESSION "${SANDBOX}/config/MAM.cookies"; then
        ok "$T"
    else
        bad "$T" "COOKIE_FILE was destroyed or emptied: $(cat "${SANDBOX}/config/MAM.cookies" 2>&1)"
    fi
fi
teardown

# ---------------------------------------------------------------------------
# 2. A failing session creation must not leave a half-written cookie behind.
# ---------------------------------------------------------------------------
T="failed creation leaves no bogus cookie"
setup '{"Success":false,"msg":"Invalid session - Other"}'
run_wrapper "Failed to create session"
if assert_probed "$T"; then
    if [ ! -s "${SANDBOX}/config/MAM.cookies" ]; then
        ok "$T"
    else
        bad "$T" "unexpected COOKIE_FILE: $(cat "${SANDBOX}/config/MAM.cookies" 2>&1)"
    fi
fi
teardown

# ---------------------------------------------------------------------------
# 3. A successful creation must promote the temp jar into place.
# ---------------------------------------------------------------------------
T="successful creation promotes the new session"
setup '{"Success":true}' writejar
run_wrapper "New session created successfully"
if assert_probed "$T"; then
    if grep -q FRESH "${SANDBOX}/config/MAM.cookies" 2>/dev/null; then
        ok "$T"
    else
        bad "$T" "COOKIE_FILE missing or stale: $(cat "${SANDBOX}/config/MAM.cookies" 2>&1)"
    fi
fi
teardown

# ---------------------------------------------------------------------------
# 4. Repeated failure must not exit; a crashloop kills the metrics server and
#    makes the outage invisible to Prometheus.
# ---------------------------------------------------------------------------
if grep -q 'exit 1' "${WRAPPER}"; then
    bad "no bare 'exit 1' failure paths remain" \
        "found: $(grep -n 'exit 1' "${WRAPPER}" | tr '\n' ' ')"
else
    ok "no bare 'exit 1' failure paths remain"
fi

printf '\n%s passed, %s failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
