#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALLER="${REPO_DIR}/deploy/cloudflare/public/install.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" message="$3"
    if [[ "$expected" != "$actual" ]]; then
        printf 'FAIL: %s\nexpected: %s\nactual:   %s\n' "$message" "$expected" "$actual" >&2
        exit 1
    fi
}

assert_file_contains() {
    local file="$1" pattern="$2" message="$3"
    if ! grep -qE -- "$pattern" "$file"; then
        printf 'FAIL: %s\nmissing pattern: %s\nfile: %s\n' "$message" "$pattern" "$file" >&2
        sed -n '1,220p' "$file" >&2 || true
        exit 1
    fi
}

assert_file_executable() {
    local file="$1" message="$2"
    if [[ ! -x "$file" ]]; then
        printf 'FAIL: %s\nfile is not executable: %s\n' "$message" "$file" >&2
        exit 1
    fi
}

test_installer_downloads_verifies_installs_and_execs_nft_script() {
    local tmp script_path expected_hash out curl_trace
    tmp="$(mktemp -d)"
    script_path="${tmp}/usr/local/sbin/nft.sh"
    curl_trace="${tmp}/curl-trace"
    mkdir -p "${tmp}/bin"
    cat > "${tmp}/remote-nft.sh" <<'EOF'
#!/usr/bin/env bash
printf 'installed-nft:%s\n' "$*"
EOF
    expected_hash="$(sha256sum "${tmp}/remote-nft.sh" | awk '{print $1}')"
    printf '%s  nft.sh\n' "$expected_hash" > "${tmp}/remote-sha256.txt"
    cat > "${tmp}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${TEST_CURL_TRACE}"
url="${@: -1}"
case "$url" in
    https://nft.hide.ss/nft.sh)
        cat "${TEST_REMOTE_NFT}"
        ;;
    https://nft.hide.ss/sha256.txt)
        cat "${TEST_REMOTE_SHA256}"
        ;;
    *)
        printf 'unexpected url: %s\n' "$url" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "${tmp}/bin/curl"

    out="$(PATH="${tmp}/bin:${PATH}" \
        TEST_CURL_TRACE="$curl_trace" \
        TEST_REMOTE_NFT="${tmp}/remote-nft.sh" \
        TEST_REMOTE_SHA256="${tmp}/remote-sha256.txt" \
        NFT_FORWARD_SCRIPT_PATH="$script_path" \
        NFT_FORWARD_BASE_URL="https://nft.hide.ss" \
        bash "$INSTALLER" --traffic-check)"

    assert_file_contains "$curl_trace" '-fsSL https://nft\.hide\.ss/nft\.sh' "installer should download the main script from the configured base URL"
    assert_file_contains "$curl_trace" '-fsSL https://nft\.hide\.ss/sha256\.txt' "installer should download sha256 metadata from the configured base URL"
    assert_file_contains <(printf '%s\n' "$out") "installed-nft:--traffic-check" "installer should exec the installed script with original arguments"
    assert_file_contains "$script_path" "installed-nft" "installer should install the downloaded nft.sh"
    assert_file_executable "$script_path" "installer should install nft.sh as executable"
}

test_installer_reconnects_stdin_for_interactive_run() {
    local tmp script_path expected_hash out tty_input
    tmp="$(mktemp -d)"
    script_path="${tmp}/usr/local/sbin/nft.sh"
    tty_input="${tmp}/tty-input"
    mkdir -p "${tmp}/bin"
    printf 'menu-input\n' > "$tty_input"
    cat > "${tmp}/remote-nft.sh" <<'EOF'
#!/usr/bin/env bash
IFS= read -r value || value="EOF"
printf 'stdin:%s\n' "$value"
EOF
    expected_hash="$(sha256sum "${tmp}/remote-nft.sh" | awk '{print $1}')"
    printf '%s  nft.sh\n' "$expected_hash" > "${tmp}/remote-sha256.txt"
    cat > "${tmp}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${@: -1}"
case "$url" in
    https://nft.hide.ss/nft.sh)
        cat "${TEST_REMOTE_NFT}"
        ;;
    https://nft.hide.ss/sha256.txt)
        cat "${TEST_REMOTE_SHA256}"
        ;;
    *)
        printf 'unexpected url: %s\n' "$url" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "${tmp}/bin/curl"

    out="$(PATH="${tmp}/bin:${PATH}" \
        TEST_REMOTE_NFT="${tmp}/remote-nft.sh" \
        TEST_REMOTE_SHA256="${tmp}/remote-sha256.txt" \
        NFT_FORWARD_SCRIPT_PATH="$script_path" \
        NFT_FORWARD_BASE_URL="https://nft.hide.ss" \
        NFT_FORWARD_TTY_PATH="$tty_input" \
        bash "$INSTALLER" < /dev/null)"

    assert_file_contains <(printf '%s\n' "$out") "stdin:menu-input" "installer should reconnect stdin for interactive nft.sh runs"
}

test_cloudflare_distribution_files_are_present() {
    "${REPO_DIR}/deploy/cloudflare/prepare-release.sh" >/dev/null
    [[ -f "${REPO_DIR}/deploy/cloudflare/wrangler.toml" ]] || fail "wrangler.toml should exist"
    [[ -f "${REPO_DIR}/deploy/cloudflare/src/worker.js" ]] || fail "worker.js should exist"
    [[ -f "${REPO_DIR}/deploy/cloudflare/public/nft.sh" ]] || fail "generated nft.sh should exist"
    [[ -f "${REPO_DIR}/deploy/cloudflare/public/version" ]] || fail "version file should exist"
    [[ -f "${REPO_DIR}/deploy/cloudflare/public/sha256.txt" ]] || fail "sha256 file should exist"
    assert_file_contains "${REPO_DIR}/deploy/cloudflare/wrangler.toml" 'name = "nft-hide-ss"' "wrangler config should name the Worker"
    assert_file_contains "${REPO_DIR}/deploy/cloudflare/wrangler.toml" 'directory = "./public"' "wrangler config should serve public assets"
    assert_file_contains "${REPO_DIR}/deploy/cloudflare/src/worker.js" 'install.sh' "worker should map the root path to install.sh"
}

main() {
    test_installer_downloads_verifies_installs_and_execs_nft_script
    test_installer_reconnects_stdin_for_interactive_run
    test_cloudflare_distribution_files_are_present
    printf 'All Cloudflare installer tests passed\n'
}

main "$@"
