# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-10-08

### Added
- CLI (all clients: POSIX sh, bash, Python and its cron/k8s images, Go,
  PowerShell): `--only-changed` downloads only databases whose ETag changed
  since the last run, using a conditional `GET` with `If-None-Match`. A `304`
  logs `Unchanged: <name>` and leaves the file untouched; unchanged files count
  as successes. `--force` downloads everything even with `--only-changed`.
  PowerShell: `-OnlyChanged`, `-Force`.
- CLI: the manifest `<target>/.geoip-update.json` (ETag, `Last-Modified` and
  size per database), written once per run through `.geoip-update.json.part`
  and a rename. Every client writes the same canonical layout, sorted by name,
  so a manifest written by one client is read by every other.
- CLI: `--lock-file PATH` takes an exclusive kernel lock on a shared path,
  released by the operating system on any exit including `kill -9`;
  `--lock-timeout SECONDS` (default `1800`) limits the wait, after which the run
  logs `Timed out after N s waiting for lock PATH` and exits 1. Combining it
  with `--no-lock` exits 1 with `--lock-file and --no-lock cannot be combined`.
  PowerShell: `-LockFile`, `-LockTimeout`. The POSIX script, which had no lock,
  gains it too; the shell clients fall back to a `mkdir` lock where `flock` is
  missing.
- CLI: every client reads the same environment variables as defaults for its
  options — `GEOIP_API_KEY`, `GEOIP_API_ENDPOINT`, `GEOIP_TARGET_DIR`,
  `GEOIP_DATABASES`, `GEOIP_CONCURRENT`, `GEOIP_LOG_FILE`, `GEOIP_TIMEOUT`,
  `GEOIP_MAX_RETRIES`, and the new `GEOIP_ONLY_CHANGED` (`true`, `1`, `yes`),
  `GEOIP_LOCK_FILE` and `GEOIP_LOCK_TIMEOUT`. Command-line options win. A
  variable a client did not read before takes effect when it is set.
- CLI (POSIX, Python): YAML keys `only_changed`, `lock_file`, `lock_timeout`.
- CLI (PowerShell): `-Databases` accepts one comma-separated value, so
  `pwsh -File geoip-update.ps1 -Databases a,b` works.
- CLI (PowerShell): resumed downloads send `If-Range`; an object that changes
  mid-download restarts, counted against `-MaxRetries`.

### Changed
- CLI (bash, Python, Go, PowerShell): downloads are staged as
  `<target>/<name>.part` and renamed into place, as the POSIX script already
  did, so readers never see a half-written database even when the system temp
  directory is on another filesystem. A transient `<name>.part` is visible in
  the target directory during a download.
- CLI (POSIX, bash): `--timeout` is the overall download ceiling across retry
  attempts. `0` means no ceiling; a value that is not a plain decimal number is
  passed to curl untouched, with no ceiling across attempts, as before.
- CLI (bash): a permanent download error now fails after the retry loop (about
  10 s, 3 attempts without progress) instead of at once; the exit code is
  unchanged.
- CLI (Python): a resumed request answered with a full `200` counts as a
  restart against `--retries`.
- CLI (Python): an invalid value in a newly read integer variable
  (`GEOIP_TIMEOUT`, `GEOIP_CONCURRENT`, `GEOIP_MAX_RETRIES`,
  `GEOIP_LOCK_TIMEOUT`) fails the run with exit 2, as the matching flag does,
  unless that flag is given.
- CLI (POSIX): `VERSION` is `2.1.0-posix`.

### Fixed
- CLI (POSIX): `/auth` retries now run under `dash`; `set -e` ended them after
  the first attempt.
- CLI (POSIX, bash): download retries and resume now run; `set -e` ended the
  background download job at the first curl failure, so a transient error
  failed the run.
- CLI (POSIX, bash, Python, Go): resumed downloads send `If-Range`, so an object
  that changes mid-download restarts from byte 0 and never produces a file
  mixed from two versions.
- CLI (all clients): a download that finally fails removes its `<name>.part`
  (Python: also after access denied or a failed validation).
- CLI (bash): on a partial failure the script waits for every download before
  exiting. It used to exit at the first failure, deleting its temp directory
  under downloads still running and releasing the lock early. The exit code is
  unchanged (curl's, for example `22`).
- CLI (PowerShell): every run where `/auth` returned more than one database
  failed with exit 1 (`Cannot convert System.Object[] to System.Int32`). A
  partial failure now exits 2 as documented.
- CLI (PowerShell): with `-Quiet`, a run where a download failed exited 0.
  `-Quiet` now only reduces output; exit codes match a run without it (partial
  failure 2, lock timeout 1), and errors go to stderr and `-LogFile`.
- CLI (PowerShell): `cmdkey` is called only where it exists, so Linux and macOS
  runs no longer print its warning.
- CLI (Go, Python): an invalid `GEOIP_*` value no longer fails a run when the
  matching command-line flag is given.
- The `cli/python-cron` and `cli/python-k8s` symlinks to the Python client and
  its `requirements.txt` resolve again.
- Docs: `cli/python-k8s/README.md` no longer lists `GEOIP_LOG_LEVEL`, which no
  client reads; `cli/config.example.yaml` shows the real `timeout` (1800) and
  `max_concurrent` (2) defaults.

### Tests
- A black-box conformance suite, `tests/conformance/` (pytest), runs every
  client (POSIX under `dash` and BusyBox `sh`, bash, Python, Go, PowerShell)
  against a local fake server that mirrors the production S3 behaviour: default
  behaviour, change detection, locking, staging, resilience, environment
  variables, the cron/k8s symlinks, and cross-client manifest compatibility.
  `tests/conformance/run.sh` runs it and `go test ./...` in Docker.
- `.github/workflows/tests.yml` runs the suite on pushes to `main` and on pull
  requests.

## [1.1.3] - 2026-06-16

### Fixed
- API: the web UI "By Database" view showed one database's values under another
  database's heading. `GeoIPReader.query()` flattened MaxMind and IP2Location
  into a single record where IP2Location overwrote MaxMind on overlapping fields
  (country/city/region/lat/long/isp), and the response only carried a map of
  which databases *touched* each field — so the per-database breakdown
  mislabeled the merged value (e.g. a Canadian MaxMind IP shown as Spain under
  "MaxMind"). Responses now include a `_by_database` block holding each
  database's own values, and the UI renders the per-database panels strictly
  from it. (#22)

### Changed
- API: when MaxMind and IP2Location disagree on a field, the merged/default
  `/query` answer now prefers MaxMind and lets IP2Location fill only the gaps
  (previously IP2Location silently overwrote MaxMind). (#22)

## [1.1.2] - 2026-06-11

### Fixed
- CLI: `--version` printed a doubled prefix (`vv1.1.1`) on released binaries.
  The release workflow injects a `v`-prefixed git tag via
  `-ldflags -X main.version=v1.1.1` while the handler also prepended its own
  `v`; local/Makefile builds (bare `1.1.1`) hid it. Now normalized to exactly
  one leading `v`. (#19)

## [1.1.1] - 2026-06-11

### Fixed
- CLI: `--timeout`/`-t` now accepts a Go duration string (`5m`, `300s`, `90s`)
  in addition to a bare integer in seconds (`1800`). The composite GitHub Action
  defaults its `timeout` input to `5m` and forwarded it raw to the binary, which
  previously declared `-timeout` as an integer — so every consumer on `v1.1.0`
  that didn't override `timeout` failed at runtime with
  `invalid value "5m" for flag -timeout: parse error`. The effective default is
  unchanged at 1800s (30m), and bare-integer callers keep working. (#17)

## [1.1.0] - 2026-06-10

### Added
- Web UI: "Clean IPs" button with IPv4/IPv6 deduplication.
- Web UI: URL synchronization for IP addresses and auto-fetch of full details.
- Deployment health checks that wait for database downloads to complete.

### Fixed
- CLI: resume interrupted downloads and apply stall-based timeouts so large
  databases complete on slow links (all CLI variants).
- Update pipeline: make IP2Location downloads resilient to a single database
  failure (keep the last published copy on S3 instead of failing the run).
- Build: bump the Go builder (1.21 → 1.26) to clear CVEs.
- Audit remediation across the CLI, API server, Terraform and Kubernetes manifests.
- Deployment workflow path/navigation fixes.

### Security
- Upload database objects to S3 **privately** (dropped `--acl public-read`) and
  removed the public direct-download URLs from the README; databases are now served
  only through the authenticated API. (#11, #12)
- Scrubbed private data — the real S3 bucket name, AWS account ID and ACM certificate
  ARN — from the code and from git history; untracked `terraform.tfvars`. (#13)

### Changed
- Hardcoded default S3 bucket replaced with the neutral placeholder
  `your-geoip-bucket` (still overridable via `S3_BUCKET`).

### Docs
- Rewrote the root README for self-hosting: architecture overview, repository
  structure with links to every component, required provider entitlements, and
  self-host installation instructions. Documented the optional dotenv.ca integration.
- Added `CONTRIBUTING.md`. (#14)

### CI
- Bumped GitHub Actions to Node 24-compatible versions.

## [1.0.0] - 2025-08-11

- Initial release: automated MaxMind + IP2Location database pipeline (GitHub Actions),
  S3 storage, authenticated download API (Lambda and Docker), multi-language CLI
  clients, and a reusable composite GitHub Action.

[1.1.2]: https://github.com/ytzcom/geoip/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/ytzcom/geoip/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/ytzcom/geoip/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/ytzcom/geoip/releases/tag/v1.0.0
