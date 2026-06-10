# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[1.1.0]: https://github.com/ytzcom/geoip/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/ytzcom/geoip/releases/tag/v1.0.0
