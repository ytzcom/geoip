FROM mcr.microsoft.com/powershell:lts-ubuntu-22.04
RUN apt-get update \
 && apt-get install -y --no-install-recommends bash dash busybox curl jq python3 python3-pip util-linux ca-certificates hostname \
 && rm -rf /var/lib/apt/lists/*
COPY --from=golang:1.27 /usr/local/go /usr/local/go
ENV PATH=/usr/local/go/bin:$PATH GOFLAGS=-mod=mod
COPY cli/python/requirements.txt /tmp/req/client.txt
COPY tests/conformance/requirements.txt /tmp/req/tests.txt
RUN pip3 install --no-cache-dir -r /tmp/req/client.txt -r /tmp/req/tests.txt
WORKDIR /repo
COPY . .
CMD ["sh", "-c", "cd tests/conformance && python3 -m pytest -q -p no:cacheprovider \"$@\" && cd /repo/cli/go && go test ./...", "--"]
