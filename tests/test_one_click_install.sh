#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT="${REPO_DIR}/nft.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
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

test_nft_sh_downloads_canonical_script_when_source_is_not_regular_file() {
    local tmp out script_path downloaded trace
    tmp="$(mktemp -d)"
    script_path="${tmp}/usr/local/sbin/nft.sh"
    downloaded="${tmp}/downloaded-nft.sh"
    trace="${tmp}/curl-trace"
    cat > "$downloaded" <<'EOF'
#!/usr/bin/env bash
printf 'downloaded script\n'
EOF

    out="$(NFT_FORWARD_SCRIPT_PATH="$script_path" \
        NFT_FORWARD_SCRIPT_URL="https://nft.hide.ss/nft.sh" \
        NFT_FORWARD_CONF_DIR="${tmp}/etc/nftables.d" \
        NFT_FORWARD_MAIN_CONF="${tmp}/etc/nftables.conf" \
        NFT_FORWARD_LOG_FILE="${tmp}/var/log/nft-forward.log" \
        bash -s "$SCRIPT" "$downloaded" "$trace" <<'EOF'
source "$1"
DOWNLOADED="$2"
TRACE_FILE="$3"
source_script_path() {
    printf '/dev/fd/63\n'
}
curl_with_timeout() {
    printf 'curl:%s\n' "$*" >> "$TRACE_FILE"
    cp "$DOWNLOADED" "$3"
}
info() {
    printf 'INFO:%s\n' "$1"
}
warn() {
    printf 'WARN:%s\n' "$1"
}
install_current_script_to_script_path
printf 'installed=%s\n' "$(cat "$SCRIPT_PATH")"
EOF
    )"

    assert_file_contains "$trace" 'curl:-fsSL -o .+ https://nft\.hide\.ss/nft\.sh' "nft.sh should download the canonical script URL when the source is not a regular file"
    assert_file_contains <(printf '%s\n' "$out") "INFO:已安装脚本到 ${script_path}，用于流量限制定时检查。" "nft.sh should report successful fallback installation"
    assert_file_contains <(printf '%s\n' "$out") "downloaded script" "nft.sh should install the downloaded script content"
    assert_file_executable "$script_path" "downloaded nft.sh should be executable"
}

main() {
    test_nft_sh_downloads_canonical_script_when_source_is_not_regular_file
    printf 'All one-click install tests passed\n'
}

main "$@"
