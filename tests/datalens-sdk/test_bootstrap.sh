#!/usr/bin/env bash

set -eu

TEST_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BOOTSTRAP_SCRIPT="${TEST_ROOT}/skills/datalens-sdk/scripts/bootstrap.sh"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/datalens-bootstrap-tests.XXXXXX")"
TESTS_RUN=0

cleanup() {
    rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    printf '%s\n' "$1" | grep -Fq "$2" || fail "expected output to contain: $2"
}

assert_not_contains() {
    if printf '%s\n' "$1" | grep -Fq "$2"; then
        fail "expected output not to contain: $2"
    fi
}

make_tools() {
    local tools_dir="$1"
    local tool=""
    local tool_path=""
    mkdir -p "$tools_dir"
    for tool in awk chmod cp grep mkdir mktemp paste rm sort touch tr; do
        tool_path="$(command -v "$tool")"
        ln -s "$tool_path" "${tools_dir}/${tool}"
    done
}

make_python() {
    local python_path="$1"
    local version="$2"
    local install_mode="$3"
    local sdk_version="$4"
    local pip_upgrade_mode="${5:-success}"
    local requirements="${6:->=3}"
    local installed="${7:-no}"
    local venv_mode="${8:-success}"
    local installed_sdk_version="${9:-$sdk_version}"
    local version_relation="${10:-newer}"

    mkdir -p "$(dirname "$python_path")"
    cp "${TEST_ROOT}/tests/datalens-sdk/fixtures/mock_python.sh" "$python_path"
    chmod +x "$python_path"
    {
        printf 'MOCK_VERSION=%q\n' "$version"
        printf 'MOCK_INSTALL_MODE=%q\n' "$install_mode"
        printf 'MOCK_SDK_VERSION=%q\n' "$sdk_version"
        printf 'MOCK_PIP_UPGRADE_MODE=%q\n' "$pip_upgrade_mode"
        printf 'MOCK_REQUIREMENTS=%q\n' "$requirements"
        printf 'MOCK_VENV_MODE=%q\n' "$venv_mode"
        printf 'MOCK_INSTALLED_SDK_VERSION=%q\n' "$installed_sdk_version"
        printf 'MOCK_VERSION_RELATION=%q\n' "$version_relation"
    } >"${python_path}.config"
    if [ "$installed" = "yes" ]; then
        printf '%s\n' "$installed_sdk_version" >"${python_path}.sdk-installed"
    fi
}

make_pyenv() {
    local pyenv_path="$1"
    cat >"$pyenv_path" <<'EOF'
#!/bin/bash
case "${1:-}" in
    versions)
        printf '%s\n' "${MOCK_PYENV_VERSION:?}"
        ;;
    prefix)
        [ "${2:-}" = "${MOCK_PYENV_VERSION:?}" ] || exit 1
        printf '%s\n' "${MOCK_PYENV_PREFIX:?}"
        ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$pyenv_path"
}

new_case() {
    local name="$1"
    CASE_DIR="${TEST_TMP}/${name}"
    CASE_PROJECT="${CASE_DIR}/project"
    CASE_TOOLS="${CASE_DIR}/tools"
    CASE_PATH="$CASE_TOOLS"
    CASE_TMP="${CASE_DIR}/tmp"
    CASE_STDERR="${CASE_DIR}/stderr"
    mkdir -p "$CASE_PROJECT" "$CASE_TMP"
    make_tools "$CASE_TOOLS"
    unset MOCK_PYENV_VERSION MOCK_PYENV_PREFIX || true
}

run_bootstrap() {
    CASE_OUTPUT="$(cd "$CASE_PROJECT" && PATH="$CASE_PATH" TMPDIR="$CASE_TMP" /bin/bash "$BOOTSTRAP_SCRIPT" "$@" 2>"$CASE_STDERR")"
    CASE_ERROR_OUTPUT="$(<"$CASE_STDERR")"
}

test_existing_current_sdk_is_reused_after_check() {
    new_case existing-sdk
    make_python "$CASE_PROJECT/.venv/bin/python" "7.4.2" success "9.8.7" success ">=3" yes
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "VENV=reused"
    assert_contains "$CASE_OUTPUT" "SDK=installed"
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=9.8.7"
    assert_contains "$CASE_OUTPUT" "AVAILABLE_SDK_VERSION=9.8.7"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_contains "$CASE_ERROR_OUTPUT" "Checking the installed datalens-sdk 9.8.7"
}

test_existing_older_sdk_requires_decision_without_mutation() {
    new_case update-available
    make_python "$CASE_PROJECT/.venv/bin/python" "7.4.2" success "9.9.0" success ">=3" yes success "9.8.7" newer
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=9.8.7"
    assert_contains "$CASE_OUTPUT" "AVAILABLE_SDK_VERSION=9.9.0"
    assert_contains "$CASE_OUTPUT" "CHANGELOG_URL=https://github.com/datalens-tech/datalens-sdk/blob/main/CHANGELOG.md"
    assert_contains "$CASE_OUTPUT" "REASON=sdk_update_available"
    assert_contains "$CASE_OUTPUT" "STATUS=decision_required"
    [ "$(<"$CASE_PROJECT/.venv/bin/python.sdk-installed")" = "9.8.7" ] || fail "update check modified installed SDK"
}

test_approved_upgrade_installs_exact_reported_version() {
    new_case approved-upgrade
    make_python "$CASE_PROJECT/.venv/bin/python" "7.4.2" success "9.9.0" success ">=3" yes success "9.8.7" newer
    run_bootstrap --upgrade-sdk 9.9.0
    assert_contains "$CASE_OUTPUT" "VENV=reused"
    assert_contains "$CASE_OUTPUT" "SDK=upgraded"
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=9.9.0"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_not_contains "$CASE_OUTPUT" "REASON="
    [ "$(<"$CASE_PROJECT/.venv/bin/python.sdk-installed")" = "9.9.0" ] || fail "approved SDK version was not installed"
}

test_changed_available_version_requires_fresh_decision() {
    new_case changed-version
    make_python "$CASE_PROJECT/.venv/bin/python" "7.4.2" success "10.0.0" success ">=3" yes success "9.8.7" newer
    run_bootstrap --upgrade-sdk 9.9.0
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=9.8.7"
    assert_contains "$CASE_OUTPUT" "AVAILABLE_SDK_VERSION=10.0.0"
    assert_contains "$CASE_OUTPUT" "REASON=sdk_update_available"
    assert_contains "$CASE_OUTPUT" "STATUS=decision_required"
    [ "$(<"$CASE_PROJECT/.venv/bin/python.sdk-installed")" = "9.8.7" ] || fail "stale consent changed installed SDK"
}

test_approved_version_disappearing_never_downgrades() {
    new_case approved-version-disappeared
    make_python "$CASE_PROJECT/.venv/bin/python" "7.4.2" success "9.7.0" success ">=3" yes success "9.8.7" older
    run_bootstrap --upgrade-sdk 9.9.0
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=9.8.7"
    assert_contains "$CASE_OUTPUT" "AVAILABLE_SDK_VERSION=9.7.0"
    assert_contains "$CASE_OUTPUT" "REASON=sdk_upgrade_target_unavailable"
    assert_contains "$CASE_OUTPUT" "STATUS=decision_required"
    [ "$(<"$CASE_PROJECT/.venv/bin/python.sdk-installed")" = "9.8.7" ] || fail "unavailable target caused a downgrade"
}

test_version_check_failure_preserves_working_sdk() {
    new_case version-check-failure
    make_python "$CASE_PROJECT/.venv/bin/python" "7.4.2" fail "unused" success ">=3" yes success "9.8.7"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "SDK=installed"
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=9.8.7"
    assert_contains "$CASE_OUTPUT" "REASON=sdk_version_check_failed"
    assert_contains "$CASE_OUTPUT" "STATUS=decision_required"
    [ "$(<"$CASE_PROJECT/.venv/bin/python.sdk-installed")" = "9.8.7" ] || fail "failed version check modified installed SDK"
}

test_failed_upgrade_reports_healthy_installed_version() {
    new_case upgrade-failure
    make_python "$CASE_PROJECT/.venv/bin/python" "7.4.2" fail_project_install "9.9.0" success ">=3" yes success "9.8.7" newer
    run_bootstrap --upgrade-sdk 9.9.0
    assert_contains "$CASE_OUTPUT" "SDK=installed"
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=9.8.7"
    assert_contains "$CASE_OUTPUT" "REASON=sdk_upgrade_failed"
    assert_contains "$CASE_OUTPUT" "STATUS=decision_required"
}

test_installed_version_newer_than_index_is_not_downgraded() {
    new_case installed-newer
    make_python "$CASE_PROJECT/.venv/bin/python" "7.4.2" success "9.9.0" success ">=3" yes success "10.0.0" older
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=10.0.0"
    assert_contains "$CASE_OUTPUT" "AVAILABLE_SDK_VERSION=9.9.0"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_not_contains "$CASE_OUTPUT" "REASON=sdk_update_available"
    [ "$(<"$CASE_PROJECT/.venv/bin/python.sdk-installed")" = "10.0.0" ] || fail "bootstrap downgraded the SDK"
}

test_pep440_multi_digit_versions_use_probe_comparator() {
    new_case pep440-multi-digit
    make_python "$CASE_PROJECT/.venv/bin/python" "7.4.2" success "0.10.0" success ">=3" yes success "0.9.0" newer
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=0.9.0"
    assert_contains "$CASE_OUTPUT" "AVAILABLE_SDK_VERSION=0.10.0"
    assert_contains "$CASE_OUTPUT" "REASON=sdk_update_available"
}

test_version_comparison_failure_requests_decision() {
    new_case comparison-failure
    make_python "$CASE_PROJECT/.venv/bin/python" "7.4.2" success "9.9.0" success ">=3" yes success "9.8.7" fail
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=9.8.7"
    assert_contains "$CASE_OUTPUT" "REASON=sdk_version_check_failed"
    assert_contains "$CASE_OUTPUT" "STATUS=decision_required"
}

test_failed_upgrade_that_breaks_sdk_is_blocked() {
    new_case broken-upgrade
    make_python "$CASE_PROJECT/.venv/bin/python" "7.4.2" fail_project_break_sdk "9.9.0" success ">=3" yes success "9.8.7" newer
    run_bootstrap --upgrade-sdk 9.9.0
    assert_contains "$CASE_OUTPUT" "VENV=failed"
    assert_contains "$CASE_OUTPUT" "SDK=missing"
    assert_contains "$CASE_OUTPUT" "REASON=sdk_upgrade_failed"
    assert_contains "$CASE_OUTPUT" "STATUS=blocked"
}

test_upgrade_requires_prior_installed_sdk() {
    new_case upgrade-without-sdk
    make_python "$CASE_TOOLS/python3" "7.4.2" success "9.9.0"
    run_bootstrap --upgrade-sdk 9.9.0
    assert_contains "$CASE_OUTPUT" "REASON=upgrade_requires_installed_sdk"
    assert_contains "$CASE_OUTPUT" "STATUS=blocked"
    [ ! -e "$CASE_PROJECT/.venv" ] || fail "upgrade mode created a project environment"
}

test_invalid_arguments_do_not_modify_project() {
    new_case invalid-arguments
    make_python "$CASE_PROJECT/.venv/bin/python" "7.4.2" success "9.9.0" success ">=3" yes success "9.8.7" newer
    run_bootstrap --upgrade-sdk
    assert_contains "$CASE_OUTPUT" "REASON=invalid_arguments"
    assert_contains "$CASE_OUTPUT" "STATUS=blocked"
    [ "$(<"$CASE_PROJECT/.venv/bin/python.sdk-installed")" = "9.8.7" ] || fail "invalid arguments modified installed SDK"
}

test_existing_compatible_venv_is_installed_in_place() {
    new_case existing-compatible
    make_python "$CASE_PROJECT/.venv/bin/python" "7.5.0" success "9.9.1"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "VENV=reused"
    assert_contains "$CASE_OUTPUT" "PYTHON_SOURCE=venv"
    assert_contains "$CASE_OUTPUT" "SDK=installed_now"
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=9.9.1"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    [ -e "$CASE_PROJECT/.venv/bin/python.sdk-installed" ] || fail "SDK was not installed into compatible .venv"
}

test_path_alternative_after_python_rejection() {
    new_case path-alternative
    make_python "$CASE_TOOLS/python3" "3.1.0" incompatible "unused" success ">=4; release Requires-Python >=5"
    make_python "$CASE_TOOLS/python3.8" "3.8.6" success "4.6.8"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "VENV=created"
    assert_contains "$CASE_OUTPUT" "PYTHON_SOURCE=path"
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=4.6.8"
    assert_contains "$CASE_OUTPUT" "REQUIRES_PYTHON=>=4|>=5"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
}

test_pyenv_alternative_after_python_rejection() {
    new_case pyenv-alternative
    make_python "$CASE_TOOLS/python3" "3.2.0" incompatible "unused" success ">=7"
    make_pyenv "$CASE_TOOLS/pyenv"
    MOCK_PYENV_VERSION="8.3.1"
    MOCK_PYENV_PREFIX="${CASE_DIR}/pyenv versions/8.3.1"
    export MOCK_PYENV_VERSION MOCK_PYENV_PREFIX
    make_python "$MOCK_PYENV_PREFIX/bin/python" "8.3.1" success "6.4.2"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "PYTHON_SOURCE=pyenv"
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=6.4.2"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
}

test_broken_default_shim_does_not_hide_later_python() {
    local later_bin=""
    new_case broken-default-shim
    cat >"$CASE_TOOLS/python3" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$CASE_TOOLS/python3"
    later_bin="${CASE_DIR}/later-bin"
    make_python "$later_bin/python3" "9.1.2" success "11.4.0"
    CASE_PATH="${CASE_TOOLS}:${later_bin}"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "PYTHON_SOURCE=path"
    assert_contains "$CASE_OUTPUT" "PYTHON_VERSION=9.1.2"
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=11.4.0"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
}

test_non_python_error_does_not_cycle() {
    new_case install-error
    make_python "$CASE_TOOLS/python3" "5.0.0" fail "unused"
    make_python "$CASE_TOOLS/python3.9" "3.9.9" success "would-have-worked"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "REASON=package_install_failed"
    assert_contains "$CASE_OUTPUT" "STATUS=blocked"
    assert_not_contains "$CASE_ERROR_OUTPUT" "Python 3.9.9"
    [ ! -e "$CASE_PROJECT/.venv" ] || fail "non-Python failure created .venv"
}

test_probe_pip_upgrade_failure_is_distinct() {
    new_case pip-upgrade-error
    make_python "$CASE_TOOLS/python3" "5.1.0" success "unused" fail
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "REASON=probe_pip_upgrade_failed"
    assert_contains "$CASE_OUTPUT" "STATUS=blocked"
}

test_existing_incompatible_venv_is_preserved() {
    new_case existing-incompatible
    make_python "$CASE_PROJECT/.venv/bin/python" "2.7.0" incompatible "unused" success ">=3"
    printf 'keep me\n' >"$CASE_PROJECT/.venv/user-sentinel"
    make_python "$CASE_TOOLS/python3.9" "3.9.1" success "7.1.0"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "VENV=incompatible"
    assert_contains "$CASE_OUTPUT" "AVAILABLE_PYTHON_VERSION=3.9.1"
    assert_contains "$CASE_OUTPUT" "REASON=venv_python_incompatible"
    assert_contains "$CASE_OUTPUT" "STATUS=blocked"
    [ "$(<"$CASE_PROJECT/.venv/user-sentinel")" = "keep me" ] || fail "existing .venv was modified"
    [ ! -e "$CASE_PROJECT/.venv/bin/python.sdk-installed" ] || fail "SDK was installed into incompatible .venv"
}

test_no_compatible_python() {
    new_case no-compatible-python
    make_python "$CASE_TOOLS/python3" "2.6.0" incompatible "unused" success ">=3"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "REASON=no_compatible_python"
    assert_contains "$CASE_OUTPUT" "REQUIRES_PYTHON=>=3"
    assert_contains "$CASE_OUTPUT" "STATUS=blocked"
}

test_failed_project_creation_leaves_no_venv() {
    new_case venv-create-failure
    make_python "$CASE_TOOLS/python3" "6.0.0" success "8.0.0" success ">=1" no fail_project
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "REASON=venv_create_failed"
    assert_contains "$CASE_OUTPUT" "STATUS=blocked"
    [ ! -e "$CASE_PROJECT/.venv" ] || fail "failed creation left a partial .venv"
}

test_failed_project_install_leaves_no_venv() {
    new_case project-install-failure
    make_python "$CASE_TOOLS/python3" "6.1.0" fail_project_install "8.1.0"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "REASON=package_install_failed"
    assert_contains "$CASE_OUTPUT" "STATUS=blocked"
    [ ! -e "$CASE_PROJECT/.venv" ] || fail "failed installation left a partial .venv"
}

test_project_path_with_spaces() {
    local expected_project=""
    new_case path-with-spaces
    CASE_PROJECT="${CASE_DIR}/project with spaces"
    mkdir -p "$CASE_PROJECT"
    expected_project="$(cd "$CASE_PROJECT" && pwd -P)"
    make_python "$CASE_TOOLS/python3" "6.2.0" success "10.2.3"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "PYTHON=$expected_project/.venv/bin/python"
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=10.2.3"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
}

test_no_static_version_pins() {
    if grep -Eq 'datalens-sdk==[0-9]|MIN_PYTHON|PIN_VERSION|Requires-Python[[:space:]]+[<>=!~][0-9]' \
        "$TEST_ROOT/skills/datalens-sdk/SKILL.md" "$BOOTSTRAP_SCRIPT"; then
        fail "wrapper skill or bootstrap contains a static SDK/Python compatibility pin"
    fi
}

test_skill_documents_consent_protocol() {
    local skill_file="$TEST_ROOT/skills/datalens-sdk/SKILL.md"
    local required_text=""
    for required_text in \
        'STATUS=decision_required' \
        'REASON=sdk_update_available' \
        'REASON=sdk_version_check_failed' \
        'REASON=sdk_upgrade_failed' \
        'REASON=sdk_upgrade_target_unavailable' \
        'CHANGELOG_URL' \
        '--upgrade-sdk "$AVAILABLE_SDK_VERSION"'
    do
        grep -Fq -- "$required_text" "$skill_file" || fail "skill omits bootstrap contract: $required_text"
    done
}

for test_name in \
    test_existing_current_sdk_is_reused_after_check \
    test_existing_older_sdk_requires_decision_without_mutation \
    test_approved_upgrade_installs_exact_reported_version \
    test_changed_available_version_requires_fresh_decision \
    test_approved_version_disappearing_never_downgrades \
    test_version_check_failure_preserves_working_sdk \
    test_failed_upgrade_reports_healthy_installed_version \
    test_installed_version_newer_than_index_is_not_downgraded \
    test_pep440_multi_digit_versions_use_probe_comparator \
    test_version_comparison_failure_requests_decision \
    test_failed_upgrade_that_breaks_sdk_is_blocked \
    test_upgrade_requires_prior_installed_sdk \
    test_invalid_arguments_do_not_modify_project \
    test_existing_compatible_venv_is_installed_in_place \
    test_path_alternative_after_python_rejection \
    test_pyenv_alternative_after_python_rejection \
    test_broken_default_shim_does_not_hide_later_python \
    test_non_python_error_does_not_cycle \
    test_probe_pip_upgrade_failure_is_distinct \
    test_existing_incompatible_venv_is_preserved \
    test_no_compatible_python \
    test_failed_project_creation_leaves_no_venv \
    test_failed_project_install_leaves_no_venv \
    test_project_path_with_spaces \
    test_no_static_version_pins \
    test_skill_documents_consent_protocol
do
    "$test_name"
    TESTS_RUN=$((TESTS_RUN + 1))
    printf 'ok %d - %s\n' "$TESTS_RUN" "$test_name"
done

printf '%d bootstrap tests passed\n' "$TESTS_RUN"
