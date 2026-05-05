#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${NFT_FORWARD_BASE_URL:-https://nft.hide.ss}"
SCRIPT_URL="${NFT_FORWARD_SCRIPT_URL:-${BASE_URL%/}/nft.sh}"
SHA256_URL="${NFT_FORWARD_SHA256_URL:-${BASE_URL%/}/sha256.txt}"
SCRIPT_PATH="${NFT_FORWARD_SCRIPT_PATH:-/usr/local/sbin/nft.sh}"
TTY_PATH="${NFT_FORWARD_TTY_PATH:-/dev/tty}"

info() {
    printf '[信息] %s\n' "$1"
}

warn() {
    printf '[警告] %s\n' "$1" >&2
}

err() {
    printf '[错误] %s\n' "$1" >&2
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        err "缺少依赖命令: $1"
        exit 1
    }
}

sha256_file() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        return 1
    fi
}

expected_sha256_for_nft() {
    local sha_file="$1"
    awk '
        $2 == "nft.sh" || $2 == "./nft.sh" || NF == 1 {
            print $1
            exit
        }
    ' "$sha_file"
}

download_file() {
    local url="$1" output="$2"
    curl -fsSL "$url" > "$output"
}

tmp_dir="$(mktemp -d)"
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

need_cmd curl
need_cmd bash
need_cmd install

script_tmp="${tmp_dir}/nft.sh"
sha_tmp="${tmp_dir}/sha256.txt"

info "下载 ${SCRIPT_URL}"
download_file "$SCRIPT_URL" "$script_tmp"

if ! bash -n "$script_tmp"; then
    err "下载的 nft.sh 未通过 bash 语法检查。"
    exit 1
fi

if download_file "$SHA256_URL" "$sha_tmp"; then
    if actual_sha="$(sha256_file "$script_tmp")"; then
        expected_sha="$(expected_sha256_for_nft "$sha_tmp")"
        if [[ -z "$expected_sha" ]]; then
            err "sha256.txt 中未找到 nft.sh 校验值。"
            exit 1
        fi
        if [[ "$actual_sha" != "$expected_sha" ]]; then
            err "nft.sh SHA256 校验失败。"
            err "expected=${expected_sha}"
            err "actual=${actual_sha}"
            exit 1
        fi
        info "SHA256 校验通过。"
    else
        warn "未检测到 sha256sum/shasum，跳过 SHA256 校验。"
    fi
else
    warn "无法下载 ${SHA256_URL}，跳过 SHA256 校验。"
fi

mkdir -p "$(dirname "$SCRIPT_PATH")"
if [[ -e "$SCRIPT_PATH" ]]; then
    backup_path="${SCRIPT_PATH}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$SCRIPT_PATH" "$backup_path"
    info "已备份旧脚本到 ${backup_path}"
fi

install -m 0755 "$script_tmp" "$SCRIPT_PATH"
info "已安装 nft.sh 到 ${SCRIPT_PATH}"

export NFT_FORWARD_SCRIPT_URL="$SCRIPT_URL"
if [[ $# -eq 0 && -r "$TTY_PATH" ]]; then
    exec "$SCRIPT_PATH" < "$TTY_PATH"
fi

exec "$SCRIPT_PATH" "$@"
