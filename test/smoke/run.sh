#!/usr/bin/env bash
# Smoke-test an image: Traefik starts, and each embedded plugin loads without
# Yaegi and does its job.
#
# usage: IMAGE=<image> test/smoke/run.sh
set -euo pipefail
cd "$(dirname "$0")"

: "${IMAGE:?set IMAGE to the image under test}"
export IMAGE

web=http://127.0.0.1:8000
api=http://127.0.0.1:8080
failures=0

check() { # check <description> <expected> <actual>
	if [[ "$3" == "$2" ]]; then
		echo "ok   - $1"
	else
		echo "FAIL - $1: expected '$2', got '$3'"
		failures=$((failures + 1))
	fi
}

cleanup() {
	if ((failures > 0)); then
		echo "--- traefik logs ---"
		docker compose logs traefik || true
	fi
	docker compose down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_for() { # wait_for <url> <status>
	for _ in $(seq 1 30); do
		[[ "$(curl -s -o /dev/null -w '%{http_code}' "$1")" == "$2" ]] && return 0
		sleep 1
	done
	echo "timed out waiting for $1 to return $2" >&2
	failures=$((failures + 1))
	exit 1
}

docker compose up -d --quiet-pull
wait_for "$api/ping" 200
wait_for "$web/plain" 200 # file provider loaded and whoami is up

routers=$(curl -fsS "$api/api/http/routers")
for r in plain robots captcha modsecurity fake-waf; do
	check "router $r enabled" enabled \
		"$(jq -r --arg n "$r@file" '.[] | select(.name == $n) | .status' <<<"$routers")"
done

robots=$(curl -fsS "$web/robots.txt" || true)
check "robots-txt serves the custom rule" yes \
	"$(grep -qx 'Disallow: /smoke-test/' <<<"$robots" && echo yes || echo no)"

check "captcha-protect redirects to its challenge" "302 /challenge" \
	"$(curl -s -o /dev/null -w '%{http_code} %header{location}' -H 'X-Forwarded-For: 203.0.113.7' \
		"$web/captcha/page" | cut -d'?' -f1)"

check "modsecurity blocks when the WAF denies" 403 \
	"$(curl -s -o /dev/null -w '%{http_code}' "$web/modsecurity/page")"

check "dashboard is embedded" 200 \
	"$(curl -s -o /dev/null -w '%{http_code}' "$api/dashboard/")"

check "license files shipped under /licenses" \
	"/licenses/NOTICE /licenses/captcha-protect/LICENSE /licenses/modsecurity/LICENSE /licenses/robots-txt/LICENSE /licenses/traefik/LICENSE.md" \
	"$(docker run --rm --entrypoint find "$IMAGE" /licenses -type f 2>&1 | sort | xargs)"

check "no error lines in traefik log" 0 \
	"$(docker compose logs --no-log-prefix traefik 2>&1 | grep -cE ' ERR |level=ERROR' || true)"

if ((failures > 0)); then
	echo "$failures check(s) failed"
	exit 1
fi
echo "all smoke checks passed"
