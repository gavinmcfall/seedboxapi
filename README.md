# seedboxapi

Fork of [myanonamouse/seedboxapi](https://github.com/myanonamouse/seedboxapi) with automatic session recovery.

## Improvements

- **Auto-regeneration**: When MAM cookie expires, automatically recreates session from `mam_id` instead of exiting
- **Retry logic**: Retries failed operations up to 3 times with 30s delay
- **Prometheus metrics**: Exposes `/metrics` endpoint on port 8080
- **Temp cookie file**: Prevents cookie corruption on failed requests
- **Curl timeouts**: Prevents hanging on network issues
- **IP fallback**: Uses multiple IP providers (ip4.me, ifconfig.me, icanhazip.com)
- **Timestamped logs**: All log messages include timestamps

## Usage

```yaml
image: ghcr.io/gavinelder/seedboxapi:latest
env:
  - name: mam_id
    value: "your-mam-session-id"
  - name: interval
    value: "1"  # minutes
  - name: DEBUG
    value: "1"  # optional
  - name: METRICS_PORT
    value: "8080"  # optional, default 8080
```

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `mam_id` | Yes | - | MAM session ID from Security preferences |
| `interval` | No | 1 | Update interval in minutes |
| `DEBUG` | No | - | Enable debug output |
| `METRICS_PORT` | No | 8080 | Port for Prometheus metrics endpoint |

## Prometheus Metrics

Metrics are exposed at `http://localhost:8080/metrics`:

| Metric | Type | Description |
|--------|------|-------------|
| `seedboxapi_refresh_success_total` | counter | Total successful IP refresh attempts |
| `seedboxapi_refresh_failed_total` | counter | Total failed IP refresh attempts |
| `seedboxapi_session_recreate_success_total` | counter | Total successful session recreations |
| `seedboxapi_session_recreate_failed_total` | counter | Total failed session recreations |
| `seedboxapi_ip_changes_total` | counter | Total IP address changes detected |
| `seedboxapi_last_success_timestamp_seconds` | gauge | Unix timestamp of last successful operation |
| `seedboxapi_up` | gauge | Whether the service is running (1 = up) |

### Example Prometheus scrape config

```yaml
scrape_configs:
  - job_name: 'seedboxapi'
    static_configs:
      - targets: ['seedboxapi:8080']
```

## Getting mam_id

1. Log in to myanonamouse from your main machine
2. Click username → Preferences → Security
3. Shell into the container running your VPN and `curl -s ifconfig.me` or `wget -qO- http://localhost:8000/v1/publicip/ip`
4. Under "Create Session"
    - Enter the public Ip from step 3
    - Select ASN for lcoked session
    - Select 'yes' for Allow Session to set Dynamic Seedbox
    - Add a label to help you remember what its for
5. Copy the long session token. This is your mam_id
