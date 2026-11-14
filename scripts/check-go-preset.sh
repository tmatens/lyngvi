#!/usr/bin/env bash
# Proves the proxy's go preset end to end, with the agent image's own Go toolchain:
#   - without the preset, `go mod download` is refused by the proxy;
#   - with PROXY_PRESETS=go, the same download succeeds through it;
#   - an unknown preset name fails the proxy build.
# Builds throwaway proxy images and uses throwaway networks; removes them after.
#   scripts/check-go-preset.sh AGENT_IMAGE      (an image built with WITH_GO=1)
set -euo pipefail
agent="${1:?usage: $0 AGENT_IMAGE (built with WITH_GO=1)}"
cd "$(dirname "${BASH_SOURCE[0]}")/.."
id="gopreset-$$"
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  docker rm -f "$id-proxy" >/dev/null 2>&1 || true
  docker network rm "$id-in" "$id-out" >/dev/null 2>&1 || true
  docker rmi "$id-proxy:none" "$id-proxy:go" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail=0

docker build -q -f proxy/Dockerfile -t "$id-proxy:none" . >/dev/null
docker build -q -f proxy/Dockerfile --build-arg PROXY_PRESETS=go -t "$id-proxy:go" . >/dev/null
if docker build -q -f proxy/Dockerfile --build-arg PROXY_PRESETS=nosuchpreset . >/dev/null 2>&1; then
  echo "FAIL an unknown preset name built"; fail=1
else
  echo "ok   an unknown preset name fails the build"
fi

docker network create "$id-out" >/dev/null
docker network create --internal "$id-in" >/dev/null

# $1 = proxy tag; prints the download's last line and returns its exit status.
download() {
  docker rm -f "$id-proxy" >/dev/null 2>&1 || true
  docker run -d --name "$id-proxy" --network "$id-out" "$id-proxy:$1" >/dev/null
  docker network connect "$id-in" "$id-proxy"
  sleep 2
  docker run --rm --network "$id-in" --user 1000 -e HOME=/tmp/h -e GOPATH=/tmp/h/go -e GOMODCACHE=/tmp/h/mod -e GOCACHE=/tmp/h/cache \
    -e HTTPS_PROXY="http://$id-proxy:3128" -e HTTP_PROXY="http://$id-proxy:3128" \
    --entrypoint sh "$agent" -c 'mkdir -p /tmp/h/m && cd /tmp/h/m && /usr/local/go/bin/go mod init probe >/dev/null 2>&1 && /usr/local/go/bin/go mod download golang.org/x/mod@v0.20.0' 2>&1 | tail -n1
  return "${PIPESTATUS[0]}"
}

if out=$(download none); then
  echo "FAIL without the preset the download succeeded"; fail=1
elif [[ "$out" == *Filtered* || "$out" == *403* ]]; then
  echo "ok   without the preset the proxy refuses the Go module proxy"
else
  echo "FAIL without the preset the download failed for another reason: $out"; fail=1
fi

if out=$(download go); then
  echo "ok   with PROXY_PRESETS=go, go mod download succeeds through the proxy"
else
  echo "FAIL with PROXY_PRESETS=go the download failed: $out"; fail=1
fi
exit "$fail"
