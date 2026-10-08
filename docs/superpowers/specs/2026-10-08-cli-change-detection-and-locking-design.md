# CLI change detection, shared-path locking and consistency (v1.2.0)

Date: 2026-10-08

## Problem

The updater ships as seven clients that implement the same `/auth` protocol:

| Client | Path | Shipped as |
|---|---|---|
| POSIX sh | `cli/geoip-update-posix.sh` | `geoip-scripts` image |
| bash | `cli/geoip-update.sh` | `geoip-scripts` image, `setup-cron.sh`, systemd |
| Python | `cli/python/geoip-update.py` | `geoip-updater` image, pip |
| Python cron | `cli/python-cron/` (symlinks to `cli/python`, supercronic) | `geoip-updater-cron` image |
| Python k8s | `cli/python-k8s/` (symlinks to `cli/python`) | `geoip-updater-k8s` image |
| Go | `cli/go/main.go` | `geoip-updater-go` image, release binaries, `geoip-scripts` |
| PowerShell | `cli/geoip-update.ps1` | `geoip-scripts` image |

Verified on 2026-10-08:

- **Every run downloads every requested database.** No client checks whether the local copy is current. Production clients that run daily re-download about 2 GB per run.
- **Locking cannot be shared.**
  - bash, Python, Go and PowerShell take a lock by default (`--no-lock` turns it off). It is a PID file at a fixed path in the system temp directory.
  - The POSIX script has no lock.
  - Two containers sharing a target volume cannot see each other's `/tmp`.
  - The PID check is wrong across PID namespaces: a lock left by a killed process in one container can name a PID that is alive in another, PID 1 for example.
- **Downloads are not atomic in four clients.**
  - bash, Python and PowerShell download into the system temp directory and then move the file into the target directory.
  - Go renames, falling back to copy-and-delete across devices.
  - When the target is another filesystem (a Docker volume, a mount), the move is a copy, so readers can open a half-written database.
  - Only the POSIX script stages `<name>.part` beside the target and renames.
- **Environment variables differ by client:**
  - `GEOIP_DATABASES` is read only by POSIX.
  - `GEOIP_CONCURRENT` is read only by POSIX and bash.
  - `GEOIP_LOG_FILE` is read only by bash, Go and PowerShell.
  - Python reads three variables.
  - `cli/python-k8s/README.md` documents `GEOIP_TIMEOUT`, `GEOIP_MAX_RETRIES` and `GEOIP_LOG_LEVEL`, which nothing reads.
- **There are no tests for six clients,** and no workflow runs any tests. Go has three test files that CI never runs. The release job only runs `--version`, `--help` and `--list-databases` on the Go binaries.
- **The cron and k8s symlinks are broken in the working tree.** `cli/python-cron/{geoip-update.py,requirements.txt}` and `cli/python-k8s/{geoip-update.py,requirements.txt}` point at `/rsyncd-munged/../python/…`, which does not exist.

### Production download behaviour (probed 2026-10-08, geoipdb.net)

- `/auth` returns S3 pre-signed URLs (bucket `ytz-geoip`) signed for `GET` (`AWSAccessKeyId`, `Expires`, `Signature`).
- `HEAD` on those URLs returns `403`.
- A `GET` with `If-None-Match` returns:
  - `304` and no body when the ETag matches;
  - the normal response when it does not.
- `If-Modified-Since` with the object's `Last-Modified` returns `304`.
- ETags are multipart ETags, for example `"4849f91e782aa7e96b6293ddeb65116a-16"` for `GeoIP2-City.mmdb` (125,988,913 bytes). The part counts match the 8 MiB default part size of `aws s3 sync` (`github-actions/upload-to-s3.sh:43`), so identical content uploads to an identical ETag. This is inferred from the sizes, not observed across two uploads.

## Constraints

- **No breaking changes.** These clients run in production projects. With no new option set, every client behaves as it does today. The exceptions are the two listed under "Consistency fixes", which leave callers' results unchanged, and the existing bugs listed under "Bug fixes".
- The same behaviour and the same option names in every client.
- No new runtime dependencies. The POSIX script stays usable under BusyBox `sh` and `dash`.
- Version `1.2.0`.

## Design

### New options

Each client gets the same options, written in its own flag style:

| Purpose | POSIX / bash / Python / Go | PowerShell | Environment | Config key (POSIX, Python YAML) |
|---|---|---|---|---|
| Download only changed files | `--only-changed` | `-OnlyChanged` | `GEOIP_ONLY_CHANGED` (`true`, `1`, `yes`) | `only_changed` |
| Ignore change detection | `--force` | `-Force` | — | — |
| Lock on a shared path | `--lock-file PATH` | `-LockFile` | `GEOIP_LOCK_FILE` | `lock_file` |
| Lock wait limit | `--lock-timeout SECONDS` | `-LockTimeout` | `GEOIP_LOCK_TIMEOUT` | `lock_timeout` |

New options have long forms only, to avoid collisions with existing short flags. Precedence follows each client's existing order. Command-line flags always win.

### Change detection (`--only-changed`)

The manifest is `<target>/.geoip-update.json`:

```json
{
  "version": 1,
  "files": {
    "GeoIP2-City.mmdb": {"etag": "4849f91e782aa7e96b6293ddeb65116a-16", "last_modified": "Mon, 05 Oct 2026 00:38:39 GMT", "size": 125988913},
    "IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN": {"etag": "71a9307410a345a693ed0104fdb8857d-46", "last_modified": "Mon, 23 Mar 2026 00:34:53 GMT", "size": 384456432}
  }
}
```

**Format.** Every client writes exactly this canonical layout:
- keys in the order shown;
- one file entry per line, with files sorted by name in byte order (the shells sort on the name field only, `LC_ALL=C sort -t'|' -k1,1`, so a name that is a prefix of another sorts first, as in Python `sorted()`, Go `sort.Strings` and PowerShell ordinal order);
- 2-space indentation;
- the ETag stored without its surrounding double quotes.

A target directory can therefore be updated by any client, and the POSIX script can read the file without `jq`. If a manifest does not parse, it is treated as absent: everything downloads and a fresh manifest is written.

**Per database returned by `/auth`:**
1. If `--force` is set, or the target file is missing, or the manifest has no entry, or the file's size on disk differs from the entry's `size`: download normally.
2. Otherwise, send the first request with `If-None-Match: "<etag>"`:
   - `304` → log `Unchanged: <name>` and leave the file and its entry untouched;
   - `200` → download.
3. After a successful download, record the final response's ETag (outer quotes stripped), `Last-Modified` and the file's size in the manifest.
   - If a resumed request (`206`) returns a different ETag from the first response, the object changed mid-download. Discard `<name>.part` and restart; this counts as one retry. This check applies only in `--only-changed` mode.

**Writing the manifest.** It is written to `<target>/.geoip-update.json.part` and renamed, once at the end of the run. Entries for databases not requested in this run are kept.

**Without `--only-changed`,** no manifest is read or written.

**Exit status.** A run where every file is unchanged exits 0. Unchanged files count as successes in each client's existing summary and exit-code logic.

**Concurrency.** Two runs with `--only-changed` and no lock can race on the manifest. The last writer wins, and a lost entry only causes one extra download on a later run. The documentation recommends `--lock-file` together with `--only-changed`.

### Shared-path locking (`--lock-file`)

With `--lock-file PATH` set, the client takes an exclusive kernel lock on `PATH` (created if missing) before reading the manifest or calling `/auth`. It holds the lock until it exits.
- The OS releases the lock when the process exits for any reason, including `kill -9`, so no stale lock can block later runs.
- A second run waits for the lock, polling until `--lock-timeout` seconds (default `1800`). If the timeout expires it logs `Timed out after N s waiting for lock PATH` and exits 1.
- After acquiring the lock, the client writes `pid=<pid> host=<hostname> started=<UTC ISO-8601>` into the lock file, for diagnosis only. It never reads this back.

**Lock primitive per client:**

| Client | Primitive |
|---|---|
| POSIX sh, bash | `flock` on an open file descriptor when the `flock` command exists. Otherwise the fallback below. |
| Python | `fcntl.flock(LOCK_EX \| LOCK_NB)` polled; on Windows, `msvcrt.locking` polled. |
| Go | `syscall.Flock(LOCK_EX\|LOCK_NB)` polled on Unix; on Windows, `syscall.CreateFile` with share mode `0` polled. No new modules. |
| PowerShell | `[System.IO.File]::Open(PATH, OpenOrCreate, ReadWrite, FileShare.None)` polled; the handle is held until exit. |

**Shell fallback, when no `flock` command exists (for example macOS):**
- Take the lock with `mkdir "$PATH.d"`, which is atomic, and write a timestamp into it.
- Remove the directory with a `trap` on `EXIT`, `INT`, `TERM` and `HUP`.
- While the main shell lives, a background heartbeat rewrites the timestamp every 60 s; it exits when the main shell is gone and is stopped when the lock is released.
- A waiter treats `$PATH.d` as stale, removes it and retries once its timestamp is older than 300 s, independent of `--timeout`. This covers `kill -9`, where no trap runs, and never breaks a live run's lock.
- In both shell clients (POSIX, bash), background download jobs inherit the lock. If only the main process is SIGKILLed, its running background downloads keep the lock until they finish (at most `--timeout`). This is documented, not changed.
- Two test-only environment variables exist and are not documented in user-facing docs. `GEOIP_LOCK_FORCE_FALLBACK=1` selects the fallback on hosts that do have `flock`, so CI can exercise it. `GEOIP_LOCK_STALE_SECONDS` overrides the stale threshold (the heartbeat interval is a fifth of it), so a test can prove a killed holder's lock expires without waiting 5 minutes.

**Interaction with the existing lock:**
- Without `--lock-file`, bash, Python, Go and PowerShell keep today's PID lock and `--no-lock`, and POSIX keeps no lock.
- With `--lock-file`, the shared-path lock replaces the PID lock.
- `--lock-file` together with `--no-lock` is an error (exit 1, `--lock-file and --no-lock cannot be combined`).

### Consistency fixes (default behaviour, results unchanged for callers)

1. **Atomic staging everywhere.**
   - bash, Python, Go and PowerShell download to `<target>/<name>.part` and rename it to `<target>/<name>`, as the POSIX script does.
   - Each client keeps its existing resume, retry, stall and validation logic; only the staging location moves.
   - The visible change is a transient `<name>.part` file in the target directory during a download.
   - On failure a client removes its `.part`, as POSIX does today.
2. **The same environment variables in every client.** Each of the following is honoured by every client, as the default for its flag:
   - `GEOIP_API_KEY`, `GEOIP_API_ENDPOINT`, `GEOIP_TARGET_DIR`, `GEOIP_DATABASES`, `GEOIP_CONCURRENT`, `GEOIP_LOG_FILE`;
   - `GEOIP_TIMEOUT` (seconds; Go also accepts its duration strings, as for `--timeout`);
   - `GEOIP_MAX_RETRIES`.

   A variable a client did not read before takes effect when it is set. `GEOIP_LOG_LEVEL` is removed from `cli/python-k8s/README.md`; no client gains a log-level option.

On a partial download failure PowerShell keeps exit code `2`, bash keeps curl's exit code (for example `22`), and POSIX, Python and Go keep `1`. The exit codes are not unified, because that would change behaviour callers rely on.

### `--timeout` per client

`--timeout` keeps each client's existing meaning; it is documented per client, not unified:

| Client | `--timeout` / `-Timeout` |
|---|---|
| POSIX, bash | Overall download ceiling in seconds across all retry attempts (default 1800). `0` means no ceiling. A value that is not a plain decimal number (for example `1e1`) is passed to curl untouched, with no ceiling across attempts. |
| Python, Go | Does not abort a stalled transfer. |
| PowerShell | Does not abort a stalled transfer. `-Timeout 0` fails the download. |

### Bug fixes

These existing bugs are fixed and listed under "Fixed" in the `CHANGELOG.md`, because they change behaviour for existing users:
- POSIX: `/auth` retries run under `dash`; `set -e` inside the command substitution ended them after the first attempt.
- POSIX, bash: download retries and resume run; `set -e` ended the background download job at the first curl failure. A resumed request carries `If-Range: "<etag>"`, so a changed object returns a full `200` and restarts from byte 0, never a mixed file. A download that finally fails removes `<name>.part`. On a partial failure bash waits for every download before exiting.
- Python, Go: resumed requests carry `If-Range` in the same way.
- PowerShell: runs where `/auth` returned more than one database failed with exit 1 (`$urls.PSObject.Properties.Count` converted an array to `Int32`). Multi-database runs work, and a partial failure exits `2`.
- PowerShell: under `-Quiet`, logging an error threw, so failed runs exited 0. `-Quiet` only reduces output; exit codes match a run without it.
- PowerShell: `-Databases` accepts one comma-separated value (for `pwsh -File`), and `cmdkey` is called only where it exists.
- Python, Go: an invalid `GEOIP_*` value is checked only when its flag is not given, so flags win over invalid environment values.

### Repository fixes

- Restore the four `cli/python-cron` and `cli/python-k8s` symlinks to `../python/geoip-update.py` and `../python/requirements.txt`. `.serena/project.yml` is left untouched.
- Bump the version to `1.2.0` everywhere it is hardcoded:
  - `cli/python/geoip-update.py`, `cli/setup.py`;
  - `cli/go/main.go`, `cli/go/Makefile`, `docker-scripts/Dockerfile` (two `-X main.version` flags);
  - `cli/geoip-update.ps1`;
  - `api-server/app.py` (three places);
  - `k8s/base/cronjob.yaml`, `k8s/base/cronjob-secure.yaml`, `k8s/overlays/prod/kustomization.yaml`;
  - a `CHANGELOG.md` entry.
- The POSIX script's own `VERSION="2.0.0-posix"` becomes `2.1.0-posix`.

### Documentation

Every document that lists client options describes the new options, the manifest, the shared-path lock and the unified environment variables:
- `README.md`, `cli/README.md`;
- `cli/python/README.md`, `cli/go/README.md`, `cli/python-cron/README.md`, `cli/python-k8s/README.md`, `cli/systemd/README.md`;
- `docker-scripts/README.md`;
- `docs/LARAVEL_INTEGRATION.md`, `docs/TROUBLESHOOTING.md`;
- `USAGE_EXAMPLES.md`, `cli/config.example.yaml`.

The recommended setup for shared volumes and daily runs is `--only-changed --lock-file <target>/.geoip-update.lock`.

## Testing

A conformance suite, `tests/conformance/` (pytest), runs every client as a black box against a local fake server:

**The fake server** (Python `ThreadingHTTPServer`) mirrors the production behaviour probed above:
- `POST /auth` checks `X-API-Key` and returns `name → URL` for requested names or aliases.
- `GET` on a URL serves the bytes with `ETag`, `Last-Modified`, `Content-Length`, `Range` and `206`. It answers `If-None-Match` and `If-Modified-Since` with `304`.
- `HEAD` returns `403`.
- Content can be changed between runs, a response can be slowed to hold a lock, a mid-download ETag change can be injected, and requests are counted per file.

**Clients run:**
- POSIX under `dash` and `busybox sh`;
- bash;
- Python (from `cli/python`);
- Go (`go build ./cli/go`);
- PowerShell under `pwsh`.

**Cases, per client:**
1. **Baseline (written first, passing before any change):**
   - a default run downloads every requested file byte-for-byte and exits 0;
   - partial failure exits with today's code (PowerShell `2`, bash curl's code `22`, others `1`) and keeps the successful files;
   - no manifest and no `.part` file are left behind;
   - today's default lock behaviour holds (POSIX: none, not pinned because the outcome is a race on `<name>.part`; Go: a second concurrent run succeeds; bash, Python and PowerShell: it fails).
2. **Change detection:**
   - the first `--only-changed` run downloads everything and writes the canonical manifest;
   - a second run makes one conditional request per file, downloads nothing, and logs `Unchanged`;
   - changed content downloads only that file;
   - a wrong local size or a missing file downloads;
   - `--force` downloads everything;
   - a corrupt manifest downloads everything and rewrites it;
   - a mid-download ETag change restarts the file.
3. **Manifest compatibility:** a manifest written by each client is read by every other client, which reports every file unchanged.
4. **Locking:**
   - two runs with the same `--lock-file` serialise: the second waits, then finds everything unchanged;
   - `--lock-timeout` expiry exits 1 with the message;
   - after `kill -9` of the lock holder, the next run proceeds immediately (shell fallback: after the stale threshold, shortened in the test with `GEOIP_LOCK_STALE_SECONDS`);
   - `--lock-file` with `--no-lock` exits 1.
5. **Atomic staging:** while a slowed download is in progress, the target name is either absent or the complete previous file, never partial.
6. **Environment variables:** each unified variable changes the corresponding behaviour in every client.
7. **Symlinks:** the cron and k8s symlinks resolve to the Python client.

**CI:** a new `.github/workflows/tests.yml` runs on pushes to `main` and on pull requests.
- It sets up Python, Go, `pwsh` and BusyBox.
- It runs the conformance suite and `go test ./...` in `cli/go`.

## Delivery

- Work happens on the branch `feat/cli-only-changed-and-locking`, with one commit per area: tests first, then each client, docs and the version bump. Nothing is pushed by the agent.
- Nuno reviews and pushes. The release follows `docs/RELEASE_PROCESS.md`: a `chore(release): v1.2.0` change and the `v1.2.0` tag. `release.yml` then publishes `ytzcom/geoip-scripts:v1.2.0` and the other images.

## Out of scope

- The API server, `action.yml` (the GitHub Action), and `update-geoip.yml` and its scripts.
- The `PX2BIN` (IP2Proxy) download has failed with `NO PERMISSION` on every recent scheduled run. Its S3 copy has been unchanged since 23 Mar 2026, and the workflow still reports success (run `37248258796`, 2026-10-05). This is an IP2Location entitlement matter for Nuno, not part of this change.
- DomainManager adopting v1.2.0 (its own step 5a revision).
