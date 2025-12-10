#!/bin/sh

if [ -n "$DEBUG" ]; then
    set -x
fi

# State files
OLD_IP_FILE=/tmp/MAM.ip
RESPONSE_FILE=/tmp/MAM.output
TEMP_COOKIE_FILE=/tmp/MAM.cookies
COOKIE_FILE=/config/MAM.cookies
METRICS_FILE=/tmp/metrics.prom
MAM_API_URL="https://t.myanonamouse.net/json/dynamicSeedbox.php"

# Metrics port (default 8080)
METRICS_PORT="${METRICS_PORT:-8080}"

# Retry configuration
MAX_RETRIES=3
RETRY_DELAY=30

# Curl timeouts
CURL_CONNECT_TIMEOUT=10
CURL_MAX_TIME=30

# Metrics counters
REFRESH_SUCCESS=0
REFRESH_FAILED=0
SESSION_RECREATE_SUCCESS=0
SESSION_RECREATE_FAILED=0
IP_CHANGES=0
LAST_SUCCESS_TIMESTAMP=0

# Logging with timestamps
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Update metrics file
update_metrics() {
    LAST_SUCCESS_TIMESTAMP=$(date +%s)
    cat > "${METRICS_FILE}" <<EOF
# HELP seedboxapi_refresh_success_total Total successful IP refresh attempts
# TYPE seedboxapi_refresh_success_total counter
seedboxapi_refresh_success_total ${REFRESH_SUCCESS}

# HELP seedboxapi_refresh_failed_total Total failed IP refresh attempts
# TYPE seedboxapi_refresh_failed_total counter
seedboxapi_refresh_failed_total ${REFRESH_FAILED}

# HELP seedboxapi_session_recreate_success_total Total successful session recreations
# TYPE seedboxapi_session_recreate_success_total counter
seedboxapi_session_recreate_success_total ${SESSION_RECREATE_SUCCESS}

# HELP seedboxapi_session_recreate_failed_total Total failed session recreations
# TYPE seedboxapi_session_recreate_failed_total counter
seedboxapi_session_recreate_failed_total ${SESSION_RECREATE_FAILED}

# HELP seedboxapi_ip_changes_total Total IP address changes detected
# TYPE seedboxapi_ip_changes_total counter
seedboxapi_ip_changes_total ${IP_CHANGES}

# HELP seedboxapi_last_success_timestamp_seconds Unix timestamp of last successful operation
# TYPE seedboxapi_last_success_timestamp_seconds gauge
seedboxapi_last_success_timestamp_seconds ${LAST_SUCCESS_TIMESTAMP}

# HELP seedboxapi_up Whether the service is running (1 = up)
# TYPE seedboxapi_up gauge
seedboxapi_up 1
EOF
}

# Start metrics HTTP server in background
start_metrics_server() {
    log "Starting metrics server on port ${METRICS_PORT}"
    while true; do
        {
            echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n$(cat "${METRICS_FILE}" 2>/dev/null || echo '# No metrics yet')"
        } | nc -l -p "${METRICS_PORT}" -q 1 >/dev/null 2>&1
    done &
    METRICS_PID=$!
    log "Metrics server started (PID: ${METRICS_PID})"
}

# Get public IP with fallback providers
get_public_ip() {
    curl -s --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" ip4.me/api/ 2>/dev/null || \
    curl -s --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" ifconfig.me 2>/dev/null || \
    curl -s --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" icanhazip.com 2>/dev/null
}

# Interval configuration
if [ -z "$interval" ]; then
    log "Running with default interval of 1 minute"
    SLEEPTIME=60
else
    if [ "$interval" -lt 1 ]; then
        log "Cannot set interval to less than 1 minute"
        log "  => Running with default interval of 60 seconds"
        SLEEPTIME=60
    else
        log "Running with an interval of $interval minute(s)"
        SLEEPTIME=$((interval * 60))
    fi
fi

# Function to create session from mam_id
create_session_from_mam_id() {
    if [ -z "$mam_id" ]; then
        log "No mam_id available to create session"
        return 1
    fi

    log "Creating new session from mam_id..."
    rm -f "${COOKIE_FILE}" "${TEMP_COOKIE_FILE}"
    curl -s --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
        -b "mam_id=${mam_id}" -c "${COOKIE_FILE}" "${MAM_API_URL}" > "${RESPONSE_FILE}"

    if grep -q '"Success":true' "${RESPONSE_FILE}"; then
        if grep -q mam_id "${COOKIE_FILE}"; then
            log "New session created successfully"
            SESSION_RECREATE_SUCCESS=$((SESSION_RECREATE_SUCCESS + 1))
            update_metrics
            return 0
        else
            log "Command successful, but failed to create cookie file"
            SESSION_RECREATE_FAILED=$((SESSION_RECREATE_FAILED + 1))
            update_metrics
            return 1
        fi
    else
        log "Failed to create session: $(cat "${RESPONSE_FILE}")"
        SESSION_RECREATE_FAILED=$((SESSION_RECREATE_FAILED + 1))
        update_metrics
        return 1
    fi
}

# Function to create session with retries
create_session_with_retry() {
    retry_count=0
    while ! create_session_from_mam_id; do
        retry_count=$((retry_count + 1))
        if [ "$retry_count" -ge "$MAX_RETRIES" ]; then
            log "Failed after $MAX_RETRIES attempts"
            return 1
        fi
        log "Retry $retry_count/$MAX_RETRIES in $RETRY_DELAY seconds..."
        sleep "$RETRY_DELAY"
    done
    return 0
}

# Initialize metrics file and start server
update_metrics
start_metrics_server

# Initial session check/creation
if ! grep -q mam_id "${COOKIE_FILE}" 2>/dev/null; then
    log "No existing session found"
    if ! create_session_with_retry; then
        exit 1
    fi
else
    # Test existing cookie
    curl -s --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
        -b "${COOKIE_FILE}" -c "${COOKIE_FILE}" "${MAM_API_URL}" > "${RESPONSE_FILE}"
    if ! grep -q '"Success":true' "${RESPONSE_FILE}"; then
        log "Existing cookie invalid: $(cat "${RESPONSE_FILE}")"
        log "Attempting to recreate session..."
        if ! create_session_with_retry; then
            exit 1
        fi
    else
        log "Existing session is valid"
        REFRESH_SUCCESS=$((REFRESH_SUCCESS + 1))
        update_metrics
    fi
fi

# Main loop
while true; do
    OLD_IP=$(cat "${OLD_IP_FILE}" 2>/dev/null)
    RAW_IP=$(get_public_ip)

    if [ -z "$RAW_IP" ]; then
        log "Failed to get public IP, retrying next interval"
        REFRESH_FAILED=$((REFRESH_FAILED + 1))
        update_metrics
        sleep "$SLEEPTIME"
        continue
    fi

    NEW_IP=$(echo "$RAW_IP" | md5sum | awk '{print $1}')

    if [ -n "$DEBUG" ]; then
        log "Current IP: $RAW_IP"
    fi

    # Check if IP changed
    if [ "$OLD_IP" != "$NEW_IP" ]; then
        log "New IP detected"
        IP_CHANGES=$((IP_CHANGES + 1))

        # Save to temp file to prevent corruption on failure
        curl -s --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
            -b "${COOKIE_FILE}" -c "${TEMP_COOKIE_FILE}" "${MAM_API_URL}" > "${RESPONSE_FILE}"

        if grep -qE 'No Session Cookie|Invalid session' "${RESPONSE_FILE}"; then
            log "Session invalid: $(cat "${RESPONSE_FILE}")"
            log "Attempting to recreate session..."
            REFRESH_FAILED=$((REFRESH_FAILED + 1))
            update_metrics
            if ! create_session_with_retry; then
                exit 1
            fi
            continue
        fi

        if grep -q '"Success":true' "${RESPONSE_FILE}"; then
            log "Response: $(cat "${RESPONSE_FILE}")"
            mv "${TEMP_COOKIE_FILE}" "${COOKIE_FILE}"
            echo "$NEW_IP" > "${OLD_IP_FILE}"
            REFRESH_SUCCESS=$((REFRESH_SUCCESS + 1))
            update_metrics
        elif grep -q "Last change too recent" "${RESPONSE_FILE}"; then
            log "Last update too recent - sleeping"
            rm -f "${TEMP_COOKIE_FILE}"
        else
            log "Invalid response: $(cat "${RESPONSE_FILE}")"
            rm -f "${TEMP_COOKIE_FILE}"
            REFRESH_FAILED=$((REFRESH_FAILED + 1))
            update_metrics
            # Try to recover instead of exiting
            log "Attempting to recreate session..."
            if ! create_session_with_retry; then
                exit 1
            fi
        fi
    else
        log "No IP change detected"
    fi

    sleep "$SLEEPTIME"

    # Enforce session freshness after 30 days
    find "${OLD_IP_FILE}" -mtime +30 -delete 2>/dev/null
done
