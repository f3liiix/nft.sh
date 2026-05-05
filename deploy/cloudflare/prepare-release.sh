#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PUBLIC_DIR="${SCRIPT_DIR}/public"

mkdir -p "$PUBLIC_DIR"
install -m 0644 "${REPO_DIR}/nft.sh" "${PUBLIC_DIR}/nft.sh"

if command -v sha256sum >/dev/null 2>&1; then
    hash_value="$(sha256sum "${PUBLIC_DIR}/nft.sh" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
    hash_value="$(shasum -a 256 "${PUBLIC_DIR}/nft.sh" | awk '{print $1}')"
else
    printf '缺少 sha256sum 或 shasum，无法生成 sha256.txt。\n' >&2
    exit 1
fi

printf '%s  nft.sh\n' "$hash_value" > "${PUBLIC_DIR}/sha256.txt"
printf 'Prepared %s and %s\n' "${PUBLIC_DIR}/nft.sh" "${PUBLIC_DIR}/sha256.txt"
