#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT="${REPO_DIR}/nft.sh"

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
    local file="$1" needle="$2" message="$3"
    if ! grep -qF "$needle" "$file"; then
        printf 'FAIL: %s\nmissing: %s\nfile: %s\n' "$message" "$needle" "$file" >&2
        sed -n '1,220p' "$file" >&2 || true
        exit 1
    fi
}

assert_file_not_contains() {
    local file="$1" needle="$2" message="$3"
    if grep -qF "$needle" "$file"; then
        printf 'FAIL: %s\nunexpected: %s\nfile: %s\n' "$message" "$needle" "$file" >&2
        sed -n '1,220p' "$file" >&2 || true
        exit 1
    fi
}

assert_file_line_contains_all() {
    local file="$1" needle1="$2" needle2="$3" message="$4"
    if ! awk -v needle1="$needle1" -v needle2="$needle2" 'index($0, needle1) && index($0, needle2) { found=1; exit } END { exit found ? 0 : 1 }' "$file"; then
        printf 'FAIL: %s\nmissing line with: %s and %s\nfile: %s\n' "$message" "$needle1" "$needle2" "$file" >&2
        sed -n '1,220p' "$file" >&2 || true
        exit 1
    fi
}

setup_case() {
    CASE_DIR="$(mktemp -d)"
    trap 'rm -rf "${CASE_DIR}"' EXIT
    export NFT_FORWARD_TEST_MODE=1
    export NFT_FORWARD_CONF_DIR="${CASE_DIR}/etc/nftables.d"
    export NFT_FORWARD_CONF_FILE="${NFT_FORWARD_CONF_DIR}/port-forward.conf"
    export NFT_FORWARD_RULES_FILE="${NFT_FORWARD_CONF_DIR}/port-forward.rules"
    export NFT_FORWARD_BACKUP_DIR="${NFT_FORWARD_CONF_DIR}/backups"
    export NFT_FORWARD_MAIN_CONF="${CASE_DIR}/etc/nftables.conf"
    export NFT_FORWARD_SYSCTL_CONF="${CASE_DIR}/etc/sysctl.d/99-nft-forward.conf"
    export NFT_FORWARD_LOG_FILE="${CASE_DIR}/var/log/nft-forward.log"
    export NFT_FORWARD_LOGROTATE_CONF="${CASE_DIR}/etc/logrotate.d/nft-forward"
    export NFT_FORWARD_STATE_DIR="${CASE_DIR}/var/lib/nft-forward"
    export NFT_FORWARD_STATE_FILE="${NFT_FORWARD_STATE_DIR}/traffic-state"
    export NFT_FORWARD_SYSTEMD_DIR="${CASE_DIR}/etc/systemd/system"
    export NFT_FORWARD_SCRIPT_PATH="${SCRIPT}"
    mkdir -p "${NFT_FORWARD_CONF_DIR}" "${NFT_FORWARD_STATE_DIR}" "${NFT_FORWARD_SYSTEMD_DIR}" "$(dirname "${NFT_FORWARD_LOG_FILE}")"
    source "${SCRIPT}"
    get_snat_ip_for_dest() {
        printf '10.0.0.1\n'
    }
}

test_target_validation() (
    setup_case
    validate_target_host "192.0.2.10" || fail "IPv4 target should be valid"
    validate_target_host "example.com" || fail "domain target should be valid"
    validate_target_host "a-b.example.co.uk" || fail "hyphenated domain target should be valid"
    if validate_target_host "-bad.example.com"; then
        fail "leading hyphen domain should be invalid"
    fi
    if validate_target_host "bad_host.example.com"; then
        fail "underscore domain should be invalid"
    fi
)

test_metadata_parses_legacy_and_new_formats() (
    setup_case
    local legacy new_no_remark new_with_remark
    legacy="$(parse_rule_metadata_line 'pf_10000_192_0_2_10_443|10000|192.0.2.10|443|200|legacy rule')"
    assert_eq 'pf_10000_192_0_2_10_443|10000|192.0.2.10|192.0.2.10|443|200|legacy rule' "$legacy" "legacy metadata should migrate to target_host + resolved_ip"

    new_no_remark="$(parse_rule_metadata_line 'pf_10000_443_1710000000000000000|10000|example.com|93.184.216.34|443|0')"
    assert_eq 'pf_10000_443_1710000000000000000|10000|example.com|93.184.216.34|443|0|' "$new_no_remark" "new metadata without remark should parse"

    new_with_remark="$(parse_rule_metadata_line 'pf_10000_443_1710000000000000000|10000|example.com|93.184.216.34|443|50|domain rule')"
    assert_eq 'pf_10000_443_1710000000000000000|10000|example.com|93.184.216.34|443|50|domain rule' "$new_with_remark" "new metadata with remark should parse"
)

test_write_conf_file_uses_resolved_ip_and_keeps_domain_comment() (
    setup_case
    RULES=('pf_10000_443_1710000000000000000|10000|example.com|93.184.216.34|443|0|domain rule')
    write_conf_file
    assert_file_contains "${NFT_FORWARD_CONF_FILE}" 'dnat to 93.184.216.34:443' "nft DNAT should use resolved IPv4"
    assert_file_contains "${NFT_FORWARD_CONF_FILE}" 'ip daddr 93.184.216.34 tcp dport 443' "forward path should match resolved IPv4"
    assert_file_line_contains_all "${NFT_FORWARD_CONF_FILE}" 'example.com' '93.184.216.34' "comments should show domain and resolved IPv4"
    assert_file_not_contains "${NFT_FORWARD_CONF_FILE}" 'dnat to example.com:443' "nft config must not use domain directly"
)

test_refresh_updates_domain_ip_and_preserves_rule_id() (
    setup_case
    RULES=('pf_10000_443_1710000000000000000|10000|example.com|93.184.216.34|443|0|domain rule')
    resolve_target_ipv4() {
        if [[ "$1" == "example.com" ]]; then
            printf '198.51.100.8\n'
            return 0
        fi
        return 1
    }
    refresh_rule_resolved_ips
    assert_eq "1" "${DOMAIN_RESOLUTION_CHANGED}" "refresh should report a changed resolved IP"
    assert_eq 'pf_10000_443_1710000000000000000|10000|example.com|198.51.100.8|443|0|domain rule' "${RULES[0]}" "refresh should preserve rule_id and update resolved_ip"
)

test_refresh_keeps_previous_ip_on_resolution_failure() (
    setup_case
    RULES=('pf_10000_443_1710000000000000000|10000|example.com|93.184.216.34|443|0|domain rule')
    resolve_target_ipv4() {
        return 1
    }
    refresh_rule_resolved_ips
    assert_eq "0" "${DOMAIN_RESOLUTION_CHANGED}" "failed refresh should not report a change"
    assert_eq 'pf_10000_443_1710000000000000000|10000|example.com|93.184.216.34|443|0|domain rule' "${RULES[0]}" "failed refresh should preserve previous resolved_ip"
)

test_timer_uses_two_minutes() (
    setup_case
    install_traffic_timer
    assert_file_contains "${NFT_FORWARD_SYSTEMD_DIR}/nft-forward-traffic-check.timer" 'OnUnitActiveSec=2min' "timer should run every 2 minutes"
)

main() {
    test_target_validation
    test_metadata_parses_legacy_and_new_formats
    test_write_conf_file_uses_resolved_ip_and_keeps_domain_comment
    test_refresh_updates_domain_ip_and_preserves_rule_id
    test_refresh_keeps_previous_ip_on_resolution_failure
    test_timer_uses_two_minutes
    printf 'All domain NAT tests passed\n'
}

main "$@"
