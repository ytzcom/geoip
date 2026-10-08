#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
docker build -q -f tests/conformance/Dockerfile -t geoip-conformance . >/dev/null
exec docker run --rm geoip-conformance sh -c 'cd tests/conformance && python3 -m pytest -q -p no:cacheprovider "$@" && cd /repo/cli/go && go test ./...' -- "$@"
