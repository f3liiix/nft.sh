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

assert_file_absent() {
    local file="$1" message="$2"
    if [[ -e "$file" ]]; then
        printf 'FAIL: %s\nunexpected file: %s\n' "$message" "$file" >&2
        sed -n '1,220p' "$file" >&2 || true
        exit 1
    fi
}

assert_file_equals() {
    local expected="$1" file="$2" message="$3"
    local actual
    actual="$(cat "$file")"
    assert_eq "$expected" "$actual" "$message"
}

assert_file_line_contains_all() {
    local file="$1" needle1="$2" needle2="$3" message="$4"
    if ! awk -v needle1="$needle1" -v needle2="$needle2" 'index($0, needle1) && index($0, needle2) { found=1; exit } END { exit found ? 0 : 1 }' "$file"; then
        printf 'FAIL: %s\nmissing line with: %s and %s\nfile: %s\n' "$message" "$needle1" "$needle2" "$file" >&2
        sed -n '1,220p' "$file" >&2 || true
        exit 1
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" message="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        printf 'FAIL: %s\nmissing: %s\ncontent:\n%s\n' "$message" "$needle" "$haystack" >&2
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

seed_domain_rule_fixture() {
    local now="${1:-1710000000}"
    local rule_id="pf_10000_443_1710000000000000000"
    local old_rule="${rule_id}|10000|example.com|93.184.216.34|443|0|domain rule"

    RULES=("${old_rule}")
    ensure_state_for_rules
    state_set STATE_PERIOD_START "${rule_id}" "${now}"
    state_set STATE_USED_BYTES "${rule_id}" 0
    state_set STATE_LAST_COUNTER "${rule_id}" 10
    state_set STATE_BLOCKED "${rule_id}" 0
    save_traffic_state
    write_rules_file
    write_conf_file

    TEST_RULE_ID="${rule_id}"
    TEST_OLD_RULE="${old_rule}"
    TEST_NEW_RULE="${rule_id}|10000|example.com|198.51.100.8|443|0|domain rule"
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
    local open_port_calls=0
    RULES=('pf_10000_443_1710000000000000000|10000|example.com|93.184.216.34|443|0|domain rule')
    firewall_open_port() {
        open_port_calls=$((open_port_calls + 1))
    }
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
    assert_eq "0" "${open_port_calls}" "refresh should not open firewall ports directly"
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

test_traffic_check_rolls_back_to_pre_load_rules_disk_state() (
    setup_case
    local legacy_conf='tcp dport 10000 dnat to 93.184.216.34:443'

    printf '%s\n' "${legacy_conf}" > "${NFT_FORWARD_CONF_FILE}"

    read_counter_bytes() {
        return 1
    }
    write_conf_file() {
        return 1
    }

    if traffic_check 1710000000; then
        fail "traffic_check should fail when write_conf_file fails during counter repair"
    fi

    assert_eq "${legacy_conf}" "$(cat "${NFT_FORWARD_CONF_FILE}")" "rollback should preserve pre-load legacy conf content"
    assert_file_absent "${NFT_FORWARD_RULES_FILE}" "rollback should delete migrated rules file when it did not exist before load_rules"
    assert_file_absent "${NFT_FORWARD_STATE_FILE}" "rollback should delete migrated state file when it did not exist before load_rules"
)

test_traffic_check_restores_files_when_save_traffic_state_fails_after_domain_refresh() (
    setup_case
    local old_rules_content old_conf_content old_state_content

    seed_domain_rule_fixture 1710000000
    old_rules_content="$(cat "${NFT_FORWARD_RULES_FILE}")"
    old_conf_content="$(cat "${NFT_FORWARD_CONF_FILE}")"
    old_state_content="$(cat "${NFT_FORWARD_STATE_FILE}")"

    read_counter_bytes() {
        printf '10\n'
    }
    resolve_target_ipv4() {
        printf '198.51.100.8\n'
    }
    save_traffic_state() {
        return 1
    }

    if traffic_check 1710000000; then
        fail "traffic_check should fail when save_traffic_state fails after domain refresh"
    fi

    assert_eq "${TEST_OLD_RULE}" "${RULES[0]}" "save_traffic_state failure should restore in-memory RULES to previous resolved IPv4"
    assert_file_equals "${old_rules_content}" "${NFT_FORWARD_RULES_FILE}" "save_traffic_state failure should preserve pre-check rules metadata"
    assert_file_equals "${old_conf_content}" "${NFT_FORWARD_CONF_FILE}" "save_traffic_state failure should preserve pre-check nft config"
    assert_file_equals "${old_state_content}" "${NFT_FORWARD_STATE_FILE}" "save_traffic_state failure should preserve pre-check traffic state"
)

test_traffic_check_restores_files_when_reload_rules_fails_after_domain_refresh() (
    setup_case
    local old_rules_content old_conf_content old_state_content

    seed_domain_rule_fixture 1710000000
    old_rules_content="$(cat "${NFT_FORWARD_RULES_FILE}")"
    old_conf_content="$(cat "${NFT_FORWARD_CONF_FILE}")"
    old_state_content="$(cat "${NFT_FORWARD_STATE_FILE}")"

    read_counter_bytes() {
        printf '10\n'
    }
    resolve_target_ipv4() {
        printf '198.51.100.8\n'
    }
    reload_rules() {
        return 1
    }

    if traffic_check 1710000000; then
        fail "traffic_check should fail when reload_rules fails after domain refresh"
    fi

    assert_eq "${TEST_OLD_RULE}" "${RULES[0]}" "reload_rules failure should restore in-memory RULES to previous resolved IPv4"
    assert_file_equals "${old_rules_content}" "${NFT_FORWARD_RULES_FILE}" "reload_rules failure should restore pre-check rules metadata"
    assert_file_equals "${old_conf_content}" "${NFT_FORWARD_CONF_FILE}" "reload_rules failure should restore pre-check nft config"
    assert_file_equals "${old_state_content}" "${NFT_FORWARD_STATE_FILE}" "reload_rules failure should restore pre-check traffic state"
)

test_traffic_check_syncs_firewall_when_domain_ip_changes() (
    setup_case
    local firewall_calls=""

    seed_domain_rule_fixture 1710000000

    read_counter_bytes() {
        printf '10\n'
    }
    resolve_target_ipv4() {
        printf '198.51.100.8\n'
    }
    reload_rules() {
        return 0
    }
    firewall_open_port() {
        firewall_calls+="open:$1:$2:$3"$'\n'
    }
    firewall_close_port() {
        fail "domain refresh should not remove the local listener firewall rule"
    }
    firewall_close_forward_target() {
        firewall_calls+="close-forward:$1:$2:$3"$'\n'
    }

    traffic_check 1710000000

    assert_eq "${TEST_NEW_RULE}" "${RULES[0]}" "traffic_check should keep refreshed in-memory RULES after successful reload"
    assert_contains "${firewall_calls}" "open:10000:198.51.100.8:443" "domain refresh should open firewall for new resolved IPv4"
    assert_contains "${firewall_calls}" "close-forward:10000:93.184.216.34:443" "domain refresh should remove old target-only firewall forwarding"
)

test_migrate_new_format_conf_preserves_rule_id_when_rules_file_missing() (
    setup_case
    local rule_id="pf_10000_443_1710000000000000000"

    RULES=("${rule_id}|10000|example.com|93.184.216.34|443|0|domain rule")
    write_conf_file
    rm -f "${NFT_FORWARD_RULES_FILE}"

    migrate_legacy_rules_if_needed

    assert_file_contains "${NFT_FORWARD_RULES_FILE}" "${rule_id}|10000|93.184.216.34|93.184.216.34|443|0|" "migration from generated conf should preserve timestamp rule_id"
)

test_install_traffic_timer_writes_expected_units() (
    setup_case
    install_traffic_timer
    assert_file_contains "${NFT_FORWARD_SYSTEMD_DIR}/nft-forward-traffic-check.service" "ExecStart=${SCRIPT} --traffic-check" "service should run the installed script path"
    assert_file_contains "${NFT_FORWARD_SYSTEMD_DIR}/nft-forward-traffic-check.timer" 'OnUnitActiveSec=2min' "timer should run every 2 minutes"
    assert_file_contains "${NFT_FORWARD_SYSTEMD_DIR}/nft-forward-traffic-check.timer" 'traffic and domain refresh check every 2 minutes' "timer description should mention domain refresh checks"
)

test_timer_unit_needs_install_detects_service_execstart_drift() (
    setup_case
    local timer_name

    install_traffic_timer
    timer_name="$(basename "${TRAFFIC_TIMER_FILE}")"
    has_systemctl() {
        return 0
    }
    systemctl() {
        if [[ "$1" == "is-enabled" && "$2" == "${timer_name}" ]]; then
            printf 'enabled\n'
            return 0
        fi
        if [[ "$1" == "is-active" && "$2" == "${timer_name}" ]]; then
            printf 'active\n'
            return 0
        fi
        return 1
    }

    if timer_unit_needs_install; then
        fail "matching timer/service units should not require reinstall"
    fi

    cat > "${TRAFFIC_SERVICE_FILE}" <<EOF
[Unit]
Description=nft-forward traffic quota check

[Service]
Type=oneshot
ExecStart=/root/nft.sh --traffic-check
EOF

    if ! timer_unit_needs_install; then
        fail "service ExecStart drift should require reinstall"
    fi
)

test_timer_unit_needs_install_detects_missing_service_file() (
    setup_case
    local timer_name

    install_traffic_timer
    timer_name="$(basename "${TRAFFIC_TIMER_FILE}")"
    has_systemctl() {
        return 0
    }
    systemctl() {
        if [[ "$1" == "is-enabled" && "$2" == "${timer_name}" ]]; then
            printf 'enabled\n'
            return 0
        fi
        if [[ "$1" == "is-active" && "$2" == "${timer_name}" ]]; then
            printf 'active\n'
            return 0
        fi
        return 1
    }

    rm -f "${TRAFFIC_SERVICE_FILE}"

    if ! timer_unit_needs_install; then
        fail "missing service file should require reinstall even if timer file exists"
    fi
)

main() {
    test_target_validation
    test_metadata_parses_legacy_and_new_formats
    test_write_conf_file_uses_resolved_ip_and_keeps_domain_comment
    test_refresh_updates_domain_ip_and_preserves_rule_id
    test_refresh_keeps_previous_ip_on_resolution_failure
    test_traffic_check_rolls_back_to_pre_load_rules_disk_state
    test_traffic_check_restores_files_when_save_traffic_state_fails_after_domain_refresh
    test_traffic_check_restores_files_when_reload_rules_fails_after_domain_refresh
    test_traffic_check_syncs_firewall_when_domain_ip_changes
    test_migrate_new_format_conf_preserves_rule_id_when_rules_file_missing
    test_install_traffic_timer_writes_expected_units
    test_timer_unit_needs_install_detects_service_execstart_drift
    test_timer_unit_needs_install_detects_missing_service_file
    printf 'All domain NAT tests passed\n'
}

main "$@"
