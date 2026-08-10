#!/usr/bin/env bash

set -eu

TEST_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BOOTSTRAP_SCRIPT="${TEST_ROOT}/skills/datalens-sdk/scripts/bootstrap.sh"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/datalens-bootstrap-tests.XXXXXX")"
TEST_SYSTEM_PYTHON="$(command -v python3)"
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
    printf '%s\n' "$1" | grep -Fq -- "$2" || fail "expected output to contain: $2"
}

assert_not_contains() {
    if printf '%s\n' "$1" | grep -Fq -- "$2"; then
        fail "expected output not to contain: $2"
    fi
}

make_tools() {
    local tools_dir="$1"
    local tool=""
    local tool_path=""
    mkdir -p "$tools_dir"
    for tool in awk cat chmod cp grep mkdir mktemp paste rm sort touch tr; do
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
    local env_identity="${11:-valid}"
    local project_python_result="${12:-compatible}"
    local project_requires_python="${13:-}"
    local pip_output_fixture="${14:-}"
    local probe_runtime="${15:-available}"
    local required_pip_config="${16:-}"
    local venv_probe_runtime="${17:-available}"

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
        printf 'MOCK_ENV_IDENTITY=%q\n' "$env_identity"
        printf 'MOCK_PROJECT_PYTHON_RESULT=%q\n' "$project_python_result"
        printf 'MOCK_PROJECT_REQUIRES_PYTHON=%q\n' "$project_requires_python"
        printf 'MOCK_PIP_OUTPUT_FIXTURE=%q\n' "$pip_output_fixture"
        printf 'MOCK_PROBE_RUNTIME=%q\n' "$probe_runtime"
        printf 'MOCK_REQUIRED_PIP_CONFIG=%q\n' "$required_pip_config"
        printf 'MOCK_VENV_PROBE_RUNTIME=%q\n' "$venv_probe_runtime"
        printf 'MOCK_DISTRIBUTION=%q\n' "$MOCK_DISTRIBUTION"
        printf 'MOCK_IMPORT_MODULE=%q\n' "$MOCK_IMPORT_MODULE"
        printf 'MOCK_IS_VIRTUALENV=no\n'
        printf 'MOCK_CALL_LOG=%q\n' "${CASE_DIR}/python-calls"
    } >"${python_path}.config"
    MOCK_MANAGER_AVAILABLE_VERSION="$sdk_version"
    export MOCK_MANAGER_AVAILABLE_VERSION
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

make_uv() {
    local uv_path="$1"
    cat >"$uv_path" <<'EOF'
#!/bin/bash
case "${1:-}" in
    run)
        [ "${2:-}" = "--no-sync" ] || exit 1
        [ "${3:-}" = "python" ] || exit 1
        shift 3
        exec "${MOCK_UV_PYTHON:?}" "$@"
        ;;
    lock)
        printf '%s\n' "$*" >>"${MOCK_MANAGER_LOG:?}"
        [ "${MOCK_MANAGER_RESOLVE_MODE:-success}" = "success" ] || exit 1
        current="$(<"${MOCK_UV_PYTHON:?}.sdk-installed")"
        if [ "$current" != "${MOCK_MANAGER_AVAILABLE_VERSION:?}" ]; then
            printf 'Updated %s v%s -> v%s\n' "$MOCK_DISTRIBUTION" "$current" "$MOCK_MANAGER_AVAILABLE_VERSION"
        else
            printf 'Resolved project without changes\n'
        fi
        ;;
    sync)
        printf '%s\n' "$*" >>"${MOCK_MANAGER_LOG:?}"
        case "$*" in
            *'--dry-run'*)
                case "${MOCK_MANAGER_OWNERSHIP_MODE:-owned}" in
                    owned) printf 'Audited project environment\n' ;;
                    unowned)
                        printf 'Would uninstall 1 package\n'
                        printf ' - %s==%s\n' "$MOCK_DISTRIBUTION" "$(<"${MOCK_UV_PYTHON:?}.sdk-installed")"
                        ;;
                    update)
                        printf 'Would uninstall 1 package\nWould install 1 package\n'
                        printf ' - %s==%s\n' "$MOCK_DISTRIBUTION" "$(<"${MOCK_UV_PYTHON:?}.sdk-installed")"
                        printf ' + %s==%s\n' "$MOCK_DISTRIBUTION" "${MOCK_MANAGER_LOCKED_VERSION:?}"
                        ;;
                    stale_lock)
                        case "$*" in
                            *'--frozen'*) printf 'Audited project environment\n' ;;
                            *)
                                printf 'Would uninstall 1 package\nWould install 1 package\n'
                                printf ' - %s==%s\n' "$MOCK_DISTRIBUTION" "$(<"${MOCK_UV_PYTHON:?}.sdk-installed")"
                                printf ' + %s==%s\n' "$MOCK_DISTRIBUTION" "${MOCK_MANAGER_MANIFEST_VERSION:?}"
                                ;;
                        esac
                        ;;
                    fail) exit 1 ;;
                    *) exit 2 ;;
                esac
                ;;
            *)
                [ "${MOCK_MANAGER_SYNC_MODE:-success}" = "success" ] || exit 1
                case "${MOCK_MANAGER_OWNERSHIP_MODE:-owned}" in
                    update)
                        printf '%s\n' "${MOCK_MANAGER_LOCKED_VERSION:?}" \
                            >"${MOCK_UV_PYTHON:?}.sdk-installed"
                        printf 'Installed %s==%s\n' "$MOCK_DISTRIBUTION" "$MOCK_MANAGER_LOCKED_VERSION"
                        ;;
                    stale_lock)
                        case "$*" in *'--frozen'*) exit 3 ;; esac
                        printf '%s\n' "${MOCK_MANAGER_MANIFEST_VERSION:?}" \
                            >"${MOCK_MANAGER_LOCK_FILE:?}"
                        printf '%s\n' "$MOCK_MANAGER_MANIFEST_VERSION" \
                            >"${MOCK_UV_PYTHON:?}.sdk-installed"
                        printf 'Installed %s==%s\n' "$MOCK_DISTRIBUTION" "$MOCK_MANAGER_MANIFEST_VERSION"
                        ;;
                    *) exit 2 ;;
                esac
                ;;
        esac
        ;;
    add)
        printf '%s\n' "$*" >>"${MOCK_MANAGER_LOG:?}"
        [ "${MOCK_MANAGER_ADD_MODE:-success}" = "success" ] || exit 1
        case "${2:-}" in
            "${MOCK_DISTRIBUTION}"==*) printf '%s\n' "${2#${MOCK_DISTRIBUTION}==}" >"${MOCK_UV_PYTHON:?}.sdk-installed" ;;
            "${MOCK_DISTRIBUTION}") printf '%s\n' "${MOCK_MANAGER_AVAILABLE_VERSION:?}" >"${MOCK_UV_PYTHON:?}.sdk-installed" ;;
            *) exit 1 ;;
        esac
        ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$uv_path"
}

make_poetry() {
    local poetry_path="$1"
    cat >"$poetry_path" <<'EOF'
#!/bin/bash
case "${1:-}" in
    source)
        printf '%s\n' "$*" >>"${MOCK_MANAGER_LOG:?}"
        [ "${2:-}" = "show" ] || exit 1
        [ "${MOCK_POETRY_SOURCE_MODE:-present}" = "present" ] || exit 1
        printf ' name : %s\n' "${DATALENS_BOOTSTRAP_POETRY_SOURCE:?}"
        ;;
    run)
        [ "${2:-}" = "python" ] || exit 1
        shift 2
        exec "${MOCK_POETRY_PYTHON:?}" "$@"
        ;;
    add)
        printf '%s\n' "$*" >>"${MOCK_MANAGER_LOG:?}"
        if [ "${2:-}" = "--dry-run" ]; then
            [ "${MOCK_MANAGER_RESOLVE_MODE:-success}" = "success" ] || exit 1
            current="$(<"${MOCK_POETRY_PYTHON:?}.sdk-installed")"
            if [ "$current" != "${MOCK_MANAGER_AVAILABLE_VERSION:?}" ]; then
                printf '  - Updating %s (%s -> %s)\n' "$MOCK_DISTRIBUTION" "$current" "$MOCK_MANAGER_AVAILABLE_VERSION"
            else
                printf 'No dependencies to install or update\n'
            fi
            exit 0
        fi
        [ "${MOCK_MANAGER_ADD_MODE:-success}" = "success" ] || exit 1
        case "${2:-}" in
            "${MOCK_DISTRIBUTION}"==*) printf '%s\n' "${2#${MOCK_DISTRIBUTION}==}" >"${MOCK_POETRY_PYTHON:?}.sdk-installed" ;;
            "${MOCK_DISTRIBUTION}") printf '%s\n' "${MOCK_MANAGER_AVAILABLE_VERSION:?}" >"${MOCK_POETRY_PYTHON:?}.sdk-installed" ;;
            *) exit 1 ;;
        esac
        ;;
    install)
        printf '%s\n' "$*" >>"${MOCK_MANAGER_LOG:?}"
        case "$*" in
            *'--sync --dry-run'*)
                case "${MOCK_MANAGER_OWNERSHIP_MODE:-owned}" in
                    owned) printf 'No dependencies to install or update\n' ;;
                    unowned)
                        printf 'Package operations: 0 installs, 0 updates, 1 removal\n'
                        printf '  - Removing %s (%s)\n' "$MOCK_DISTRIBUTION" "$(<"${MOCK_POETRY_PYTHON:?}.sdk-installed")"
                        ;;
                    update)
                        printf 'Package operations: 0 installs, 1 update, 0 removals\n'
                        printf '  - Updating %s (%s -> %s)\n' "$MOCK_DISTRIBUTION" \
                            "$(<"${MOCK_POETRY_PYTHON:?}.sdk-installed")" "${MOCK_MANAGER_LOCKED_VERSION:?}"
                        ;;
                    downgrade)
                        printf 'Package operations: 0 installs, 0 updates, 1 downgrade\n'
                        printf '  • Downgrading %s (%s -> %s)\n' "$MOCK_DISTRIBUTION" \
                            "$(<"${MOCK_POETRY_PYTHON:?}.sdk-installed")" "${MOCK_MANAGER_LOCKED_VERSION:?}"
                        ;;
                    fail) exit 1 ;;
                    *) exit 2 ;;
                esac
                ;;
            *'--dry-run --no-root'*)
                case "${MOCK_POETRY_DEPENDENCY_MODE:-undeclared}" in
                    declared)
                        printf 'Package operations: 1 install, 0 updates, 0 removals\n'
                        printf '  • Installing %s (%s)\n' "$MOCK_DISTRIBUTION" "${MOCK_POETRY_DECLARED_VERSION:?}"
                        ;;
                    downgrade)
                        printf 'Package operations: 0 installs, 0 updates, 1 downgrade\n'
                        printf '  - Downgrading %s (9.9.0 -> %s)\n' "$MOCK_DISTRIBUTION" \
                            "${MOCK_POETRY_DECLARED_VERSION:?}"
                        ;;
                    undeclared) printf 'No dependencies to install or update\n' ;;
                    fail) exit 1 ;;
                    *) exit 2 ;;
                esac
                ;;
            *'--no-root'*)
                [ "${MOCK_MANAGER_SYNC_MODE:-success}" = "success" ] || exit 1
                case "${MOCK_POETRY_DEPENDENCY_MODE:-undeclared}" in
                    declared|downgrade) : ;;
                    *) exit 2 ;;
                esac
                printf '%s\n' "${MOCK_POETRY_DECLARED_VERSION:?}" \
                    >"${MOCK_POETRY_PYTHON:?}.sdk-installed"
                printf '  - Installing %s (%s)\n' "$MOCK_DISTRIBUTION" "$MOCK_POETRY_DECLARED_VERSION"
                ;;
            *) exit 2 ;;
        esac
        ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$poetry_path"
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
    MOCK_MANAGER_LOG="${CASE_DIR}/manager-calls"
    MOCK_DISTRIBUTION="datalens-sdk"
    MOCK_IMPORT_MODULE="datalens_sdk"
    : >"${CASE_DIR}/python-calls"
    MOCK_MANAGER_ADD_MODE="success"
    MOCK_MANAGER_RESOLVE_MODE="success"
    MOCK_MANAGER_AVAILABLE_VERSION="9.9.0"
    MOCK_MANAGER_LOCKED_VERSION="9.9.0"
    MOCK_MANAGER_MANIFEST_VERSION="9.9.0"
    MOCK_MANAGER_LOCK_FILE="${CASE_PROJECT}/uv.lock"
    MOCK_MANAGER_OWNERSHIP_MODE="owned"
    MOCK_MANAGER_SYNC_MODE="success"
    MOCK_POETRY_DEPENDENCY_MODE="undeclared"
    MOCK_POETRY_DECLARED_VERSION="0.3.0"
    MOCK_POETRY_SOURCE_MODE="present"
    export MOCK_MANAGER_LOG MOCK_MANAGER_ADD_MODE MOCK_MANAGER_RESOLVE_MODE MOCK_MANAGER_AVAILABLE_VERSION \
        MOCK_MANAGER_LOCKED_VERSION MOCK_MANAGER_MANIFEST_VERSION MOCK_MANAGER_LOCK_FILE \
        MOCK_MANAGER_OWNERSHIP_MODE MOCK_MANAGER_SYNC_MODE \
        MOCK_POETRY_DEPENDENCY_MODE MOCK_POETRY_DECLARED_VERSION MOCK_POETRY_SOURCE_MODE \
        MOCK_DISTRIBUTION MOCK_IMPORT_MODULE
    unset MOCK_PYENV_VERSION MOCK_PYENV_PREFIX MOCK_UV_PYTHON MOCK_POETRY_PYTHON UV_PROJECT_ENVIRONMENT || true
    unset PIP_REQUIRE_VIRTUALENV || true
    unset DATALENS_BOOTSTRAP_DISTRIBUTION DATALENS_BOOTSTRAP_IMPORT_MODULE \
        DATALENS_BOOTSTRAP_CHANGELOG_URL DATALENS_BOOTSTRAP_POETRY_SOURCE || true
}

run_bootstrap() {
    CASE_OUTPUT="$(cd "$CASE_PROJECT" && PATH="$CASE_PATH" TMPDIR="$CASE_TMP" /bin/bash "$BOOTSTRAP_SCRIPT" "$@" 2>"$CASE_STDERR")"
    CASE_ERROR_OUTPUT="$(<"$CASE_STDERR")"
}

use_alternate_profile() {
    DATALENS_BOOTSTRAP_DISTRIBUTION="example-private-sdk"
    DATALENS_BOOTSTRAP_IMPORT_MODULE="example_private_sdk"
    DATALENS_BOOTSTRAP_CHANGELOG_URL="${1:-}"
    MOCK_DISTRIBUTION="$DATALENS_BOOTSTRAP_DISTRIBUTION"
    MOCK_IMPORT_MODULE="$DATALENS_BOOTSTRAP_IMPORT_MODULE"
    export DATALENS_BOOTSTRAP_DISTRIBUTION DATALENS_BOOTSTRAP_IMPORT_MODULE \
        DATALENS_BOOTSTRAP_CHANGELOG_URL MOCK_DISTRIBUTION MOCK_IMPORT_MODULE
}

use_alternate_poetry_profile() {
    use_alternate_profile
    DATALENS_BOOTSTRAP_POETRY_SOURCE="yandex-team"
    export DATALENS_BOOTSTRAP_POETRY_SOURCE
}

test_stale_project_python_symlink_is_rejected() {
    new_case stale-project-python
    mkdir -p "$CASE_PROJECT/.venv/bin"
    ln -s "$TEST_SYSTEM_PYTHON" "$CASE_PROJECT/.venv/bin/python"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "VENV=failed"
    assert_contains "$CASE_OUTPUT" "SDK=missing"
    assert_contains "$CASE_OUTPUT" "REASON=venv_invalid"
    assert_contains "$CASE_OUTPUT" "STATUS=blocked"
    assert_not_contains "$CASE_ERROR_OUTPUT" "Installing datalens-sdk"
    assert_not_contains "$CASE_ERROR_OUTPUT" "Upgrading datalens-sdk"
}

test_environment_identity_is_rechecked_before_project_pip() {
    new_case identity-changed
    make_python "$CASE_PROJECT/.venv/bin/python" "7.4.2" success "9.8.7" success ">=3" no success "9.8.7" newer valid_once
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "VENV=failed"
    assert_contains "$CASE_OUTPUT" "SDK=missing"
    assert_contains "$CASE_OUTPUT" "REASON=venv_invalid"
    assert_contains "$CASE_OUTPUT" "STATUS=blocked"
    assert_not_contains "$CASE_ERROR_OUTPUT" "Installing datalens-sdk"
    [ ! -e "$CASE_PROJECT/.venv/bin/python.sdk-installed" ] || fail "identity change reached project pip"
}

test_uv_managed_environment_is_reused() {
    new_case uv-managed
    touch "$CASE_PROJECT/uv.lock"
    MOCK_UV_PYTHON="$CASE_PROJECT/.venv/bin/python"
    export MOCK_UV_PYTHON
    make_python "$MOCK_UV_PYTHON" "7.4.2" success "9.8.7" success ">=3" yes
    make_uv "$CASE_TOOLS/uv"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "VENV=reused"
    assert_contains "$CASE_OUTPUT" "PYTHON=$MOCK_UV_PYTHON"
    assert_contains "$CASE_OUTPUT" "PYTHON_SOURCE=uv"
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=9.8.7"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    [ -e "$CASE_PROJECT/.venv/bin/python" ] || fail "bootstrap did not preserve the uv-owned .venv"
}

test_poetry_managed_environment_is_reused() {
    new_case poetry-managed
    touch "$CASE_PROJECT/poetry.lock"
    MOCK_POETRY_PYTHON="$CASE_PROJECT/.venv/bin/python"
    export MOCK_POETRY_PYTHON
    make_python "$MOCK_POETRY_PYTHON" "7.4.2" success "9.8.7" success ">=3" yes
    make_poetry "$CASE_TOOLS/poetry"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "VENV=reused"
    assert_contains "$CASE_OUTPUT" "PYTHON=$MOCK_POETRY_PYTHON"
    assert_contains "$CASE_OUTPUT" "PYTHON_SOURCE=poetry"
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=9.8.7"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    [ -e "$CASE_PROJECT/.venv/bin/python" ] || fail "bootstrap did not preserve the Poetry-owned .venv"
}

test_uv_marker_only_is_detected_with_bsd_grep() {
    new_case uv-marker-only
    printf '%s\n' '[tool.uv]' >"$CASE_PROJECT/pyproject.toml"
    MOCK_UV_PYTHON="$CASE_PROJECT/.venv/bin/python"
    export MOCK_UV_PYTHON
    make_python "$MOCK_UV_PYTHON" "7.4.2" success "9.8.7" success ">=3" yes
    make_uv "$CASE_TOOLS/uv"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "PYTHON_SOURCE=uv"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
}

test_poetry_marker_only_is_detected_with_bsd_grep() {
    new_case poetry-marker-only
    printf '%s\n' '[tool.poetry]' >"$CASE_PROJECT/pyproject.toml"
    MOCK_POETRY_PYTHON="$CASE_PROJECT/.venv/bin/python"
    export MOCK_POETRY_PYTHON
    make_python "$MOCK_POETRY_PYTHON" "7.4.2" success "9.8.7" success ">=3" yes
    make_poetry "$CASE_TOOLS/poetry"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "PYTHON_SOURCE=poetry"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
}

test_uv_array_source_marker_uses_native_resolver() {
    local manifest_before=""
    new_case uv-array-source
    printf '%s\n' '[[tool.uv.index]]' 'name = "private"' 'url = "https://packages.example/simple"' >"$CASE_PROJECT/pyproject.toml"
    manifest_before="$(<"$CASE_PROJECT/pyproject.toml")"
    MOCK_UV_PYTHON="$CASE_PROJECT/.venv/bin/python"
    export MOCK_UV_PYTHON
    make_python "$MOCK_UV_PYTHON" "7.4.2" success "11.0.0" success ">=3" yes success "10.0.0" newer
    make_uv "$CASE_TOOLS/uv"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "AVAILABLE_SDK_VERSION=11.0.0"
    assert_contains "$CASE_OUTPUT" "REASON=sdk_update_available"
    assert_contains "$(<"$MOCK_MANAGER_LOG")" "lock --dry-run --upgrade-package datalens-sdk"
    assert_not_contains "$(<"$CASE_DIR/python-calls")" "pip index versions datalens-sdk"
    [ "$(<"$CASE_PROJECT/pyproject.toml")" = "$manifest_before" ] || fail "uv freshness changed pyproject.toml"
    [ ! -e "$CASE_PROJECT/uv.lock" ] || fail "uv freshness wrote a lockfile"
}

test_poetry_array_source_marker_uses_native_resolver() {
    local manifest_before=""
    new_case poetry-array-source
    printf '%s\n' '[[tool.poetry.source]]' 'name = "private"' 'url = "https://packages.example/simple"' >"$CASE_PROJECT/pyproject.toml"
    manifest_before="$(<"$CASE_PROJECT/pyproject.toml")"
    MOCK_POETRY_PYTHON="$CASE_PROJECT/.venv/bin/python"
    export MOCK_POETRY_PYTHON
    make_python "$MOCK_POETRY_PYTHON" "7.4.2" success "11.0.0" success ">=3" yes success "10.0.0" newer
    make_poetry "$CASE_TOOLS/poetry"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "AVAILABLE_SDK_VERSION=11.0.0"
    assert_contains "$CASE_OUTPUT" "REASON=sdk_update_available"
    assert_contains "$(<"$MOCK_MANAGER_LOG")" "add --dry-run --no-interaction --no-ansi datalens-sdk@latest"
    assert_not_contains "$(<"$CASE_DIR/python-calls")" "pip index versions datalens-sdk"
    [ "$(<"$CASE_PROJECT/pyproject.toml")" = "$manifest_before" ] || fail "Poetry freshness changed pyproject.toml"
    [ ! -e "$CASE_PROJECT/poetry.lock" ] || fail "Poetry freshness wrote a lockfile"
}

test_uv_plugin_section_does_not_claim_plain_venv() {
    new_case uv-plugin-section
    printf '%s\n' '[tool.uv-dynamic-versioning]' >"$CASE_PROJECT/pyproject.toml"
    make_python "$CASE_PROJECT/.venv/bin/python" "7.4.2" success "9.8.7" success ">=3" yes
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "PYTHON_SOURCE=venv"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_not_contains "$CASE_OUTPUT" "PYTHON_SOURCE=uv"
}

test_managed_install_requires_consent_and_uses_uv() {
    new_case uv-install-consent
    touch "$CASE_PROJECT/uv.lock"
    MOCK_UV_PYTHON="$CASE_PROJECT/.venv/bin/python"
    export MOCK_UV_PYTHON
    make_python "$MOCK_UV_PYTHON" "7.4.2" success "9.9.0"
    make_uv "$CASE_TOOLS/uv"

    run_bootstrap
    assert_contains "$CASE_OUTPUT" "REASON=sdk_install_required"
    assert_contains "$CASE_OUTPUT" "STATUS=decision_required"
    assert_not_contains "$CASE_OUTPUT" "AVAILABLE_SDK_VERSION="
    [ ! -e "$MOCK_UV_PYTHON.sdk-installed" ] || fail "managed SDK was installed without consent"
    [ ! -s "$MOCK_MANAGER_LOG" ] || fail "uv add ran without consent"

    run_bootstrap --install-sdk
    assert_contains "$CASE_OUTPUT" "SDK=installed_now"
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=9.9.0"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_contains "$(<"$MOCK_MANAGER_LOG")" "add datalens-sdk"
}

test_declared_poetry_dependency_is_installed_without_readding() {
    local manifest_before=""
    local lock_before=""
    new_case poetry-declared-missing
    printf '%s\n' \
        '[tool.poetry]' \
        'name = "example"' \
        'version = "0.1.0"' \
        '[tool.poetry.dependencies]' \
        'python = "^3.10"' \
        'datalens-sdk = "0.3.0"' >"$CASE_PROJECT/pyproject.toml"
    printf '%s\n' '[[package]]' 'name = "datalens-sdk"' 'version = "0.3.0"' \
        >"$CASE_PROJECT/poetry.lock"
    manifest_before="$(<"$CASE_PROJECT/pyproject.toml")"
    lock_before="$(<"$CASE_PROJECT/poetry.lock")"
    MOCK_POETRY_PYTHON="$CASE_PROJECT/.venv/bin/python"
    MOCK_POETRY_DEPENDENCY_MODE="declared"
    MOCK_POETRY_DECLARED_VERSION="0.3.0"
    export MOCK_POETRY_PYTHON MOCK_POETRY_DEPENDENCY_MODE MOCK_POETRY_DECLARED_VERSION
    make_python "$MOCK_POETRY_PYTHON" "3.12.11" success "9.9.0"
    make_poetry "$CASE_TOOLS/poetry"

    run_bootstrap
    assert_contains "$CASE_OUTPUT" "REASON=sdk_install_required"
    assert_contains "$CASE_OUTPUT" "STATUS=decision_required"
    [ ! -e "$MOCK_POETRY_PYTHON.sdk-installed" ] || fail "Poetry SDK was installed without consent"
    [ ! -s "$MOCK_MANAGER_LOG" ] || fail "Poetry install planning ran without consent"

    run_bootstrap --install-sdk
    assert_contains "$CASE_OUTPUT" "SDK=installed_now"
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=0.3.0"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_contains "$(<"$MOCK_MANAGER_LOG")" "install --dry-run --no-root --no-interaction --no-ansi"
    assert_contains "$(<"$MOCK_MANAGER_LOG")" "install --no-root --no-interaction --no-ansi"
    assert_not_contains "$(<"$MOCK_MANAGER_LOG")" "add datalens-sdk"
    [ "$(<"$CASE_PROJECT/pyproject.toml")" = "$manifest_before" ] \
        || fail "Poetry install changed the declared SDK constraint"
    [ "$(<"$CASE_PROJECT/poetry.lock")" = "$lock_before" ] \
        || fail "Poetry install changed the existing lock"
}

test_poetry_install_plan_failure_does_not_mutate_project() {
    new_case poetry-install-plan-failure
    touch "$CASE_PROJECT/poetry.lock"
    MOCK_POETRY_PYTHON="$CASE_PROJECT/.venv/bin/python"
    MOCK_POETRY_DEPENDENCY_MODE="fail"
    export MOCK_POETRY_PYTHON MOCK_POETRY_DEPENDENCY_MODE
    make_python "$MOCK_POETRY_PYTHON" "3.12.11" success "9.9.0"
    make_poetry "$CASE_TOOLS/poetry"

    run_bootstrap --install-sdk
    assert_contains "$CASE_OUTPUT" "SDK=missing"
    assert_contains "$CASE_OUTPUT" "REASON=sdk_install_failed"
    assert_contains "$CASE_OUTPUT" "STATUS=blocked"
    assert_contains "$(<"$MOCK_MANAGER_LOG")" "install --dry-run --no-root --no-interaction --no-ansi"
    assert_not_contains "$(<"$MOCK_MANAGER_LOG")" "install --no-root --no-interaction --no-ansi"
    assert_not_contains "$(<"$MOCK_MANAGER_LOG")" "add datalens-sdk"
    [ ! -e "$MOCK_POETRY_PYTHON.sdk-installed" ] || fail "failed Poetry plan installed the SDK"
}

test_poetry_declared_sdk_downgrade_uses_install() {
    new_case poetry-declared-downgrade
    touch "$CASE_PROJECT/poetry.lock"
    MOCK_POETRY_PYTHON="$CASE_PROJECT/.venv/bin/python"
    MOCK_POETRY_DEPENDENCY_MODE="downgrade"
    MOCK_POETRY_DECLARED_VERSION="0.3.0"
    export MOCK_POETRY_PYTHON MOCK_POETRY_DEPENDENCY_MODE MOCK_POETRY_DECLARED_VERSION
    make_python "$MOCK_POETRY_PYTHON" "3.12.11" success "9.9.0"
    make_poetry "$CASE_TOOLS/poetry"

    run_bootstrap --install-sdk
    assert_contains "$CASE_OUTPUT" "SDK=installed_now"
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=0.3.0"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_contains "$(<"$MOCK_MANAGER_LOG")" "install --no-root --no-interaction --no-ansi"
    assert_not_contains "$(<"$MOCK_MANAGER_LOG")" "add datalens-sdk"
}

test_managed_upgrade_uses_poetry_after_consent() {
    new_case poetry-upgrade-consent
    touch "$CASE_PROJECT/poetry.lock"
    MOCK_POETRY_PYTHON="$CASE_PROJECT/.venv/bin/python"
    export MOCK_POETRY_PYTHON
    make_python "$MOCK_POETRY_PYTHON" "7.4.2" success "9.9.0" success ">=3" yes success "9.8.7" newer
    make_poetry "$CASE_TOOLS/poetry"

    run_bootstrap
    assert_contains "$CASE_OUTPUT" "REASON=sdk_update_available"
    assert_not_contains "$(<"$MOCK_MANAGER_LOG")" "add datalens-sdk=="

    run_bootstrap --upgrade-sdk 9.9.0
    assert_contains "$CASE_OUTPUT" "SDK=upgraded"
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=9.9.0"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_contains "$(<"$MOCK_MANAGER_LOG")" "add datalens-sdk==9.9.0"
}

test_managed_install_rejects_legacy_version_argument() {
    new_case uv-install-legacy-argument
    touch "$CASE_PROJECT/uv.lock"
    MOCK_UV_PYTHON="$CASE_PROJECT/.venv/bin/python"
    export MOCK_UV_PYTHON
    make_python "$MOCK_UV_PYTHON" "7.4.2" success "10.0.0"
    make_uv "$CASE_TOOLS/uv"

    run_bootstrap --install-sdk 9.9.0
    assert_contains "$CASE_OUTPUT" "REASON=invalid_arguments"
    assert_contains "$CASE_OUTPUT" "STATUS=blocked"
    [ ! -s "$MOCK_MANAGER_LOG" ] || fail "legacy install form changed managed dependencies"
}

test_managed_install_failure_preserves_environment() {
    new_case poetry-install-failure
    touch "$CASE_PROJECT/poetry.lock"
    MOCK_POETRY_PYTHON="$CASE_PROJECT/.venv/bin/python"
    export MOCK_POETRY_PYTHON
    make_python "$MOCK_POETRY_PYTHON" "7.4.2" success "9.9.0"
    make_poetry "$CASE_TOOLS/poetry"
    touch "$CASE_PROJECT/.venv/user-sentinel"
    MOCK_MANAGER_ADD_MODE="fail"
    export MOCK_MANAGER_ADD_MODE

    run_bootstrap --install-sdk
    assert_contains "$CASE_OUTPUT" "VENV=reused"
    assert_contains "$CASE_OUTPUT" "SDK=missing"
    assert_contains "$CASE_OUTPUT" "REASON=sdk_install_failed"
    assert_contains "$CASE_OUTPUT" "STATUS=blocked"
    [ -e "$CASE_PROJECT/.venv/user-sentinel" ] || fail "managed install failure replaced the environment"
}

test_uv_pip_installed_sdk_requires_manager_ownership() {
    new_case uv-unowned-sdk
    touch "$CASE_PROJECT/uv.lock"
    MOCK_UV_PYTHON="$CASE_PROJECT/.venv/bin/python"
    export MOCK_UV_PYTHON
    make_python "$MOCK_UV_PYTHON" "7.4.2" success "9.9.0" success ">=3" yes
    make_uv "$CASE_TOOLS/uv"
    MOCK_MANAGER_OWNERSHIP_MODE="unowned"
    export MOCK_MANAGER_OWNERSHIP_MODE

    run_bootstrap
    assert_contains "$CASE_OUTPUT" "SDK=missing"
    assert_not_contains "$CASE_OUTPUT" "SDK_VERSION="
    assert_contains "$CASE_OUTPUT" "REASON=sdk_install_required"
    assert_contains "$CASE_OUTPUT" "STATUS=decision_required"
    assert_contains "$(<"$MOCK_MANAGER_LOG")" "sync --dry-run"
    assert_not_contains "$(<"$MOCK_MANAGER_LOG")" "add datalens-sdk"

    run_bootstrap --install-sdk
    assert_contains "$CASE_OUTPUT" "SDK=installed_now"
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=9.9.0"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_contains "$(<"$MOCK_MANAGER_LOG")" "add datalens-sdk"
}

test_poetry_pip_installed_sdk_requires_manager_ownership() {
    new_case poetry-unowned-sdk
    touch "$CASE_PROJECT/poetry.lock"
    MOCK_POETRY_PYTHON="$CASE_PROJECT/.venv/bin/python"
    export MOCK_POETRY_PYTHON
    make_python "$MOCK_POETRY_PYTHON" "7.4.2" success "9.9.0" success ">=3" yes
    make_poetry "$CASE_TOOLS/poetry"
    MOCK_MANAGER_OWNERSHIP_MODE="unowned"
    export MOCK_MANAGER_OWNERSHIP_MODE

    run_bootstrap
    assert_contains "$CASE_OUTPUT" "SDK=missing"
    assert_not_contains "$CASE_OUTPUT" "SDK_VERSION="
    assert_contains "$CASE_OUTPUT" "REASON=sdk_install_required"
    assert_contains "$CASE_OUTPUT" "STATUS=decision_required"
    assert_contains "$(<"$MOCK_MANAGER_LOG")" "install --sync --dry-run"
    assert_not_contains "$(<"$MOCK_MANAGER_LOG")" "add datalens-sdk"

    run_bootstrap --install-sdk
    assert_contains "$CASE_OUTPUT" "SDK=installed_now"
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=9.9.0"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_contains "$(<"$MOCK_MANAGER_LOG")" "add datalens-sdk"
}

test_uv_version_drift_requires_sync_before_freshness() {
    new_case uv-version-drift
    touch "$CASE_PROJECT/uv.lock"
    MOCK_UV_PYTHON="$CASE_PROJECT/.venv/bin/python"
    MOCK_MANAGER_OWNERSHIP_MODE="update"
    MOCK_MANAGER_LOCKED_VERSION="0.4.0"
    MOCK_MANAGER_AVAILABLE_VERSION="0.6.0"
    export MOCK_UV_PYTHON MOCK_MANAGER_OWNERSHIP_MODE MOCK_MANAGER_LOCKED_VERSION \
        MOCK_MANAGER_AVAILABLE_VERSION
    make_python "$MOCK_UV_PYTHON" "3.12.11" success "0.6.0" success ">=3" yes success "0.5.0"
    MOCK_MANAGER_AVAILABLE_VERSION="0.6.0"
    export MOCK_MANAGER_AVAILABLE_VERSION
    make_uv "$CASE_TOOLS/uv"

    run_bootstrap
    assert_contains "$CASE_OUTPUT" "SDK=missing"
    assert_not_contains "$CASE_OUTPUT" "SDK_VERSION="
    assert_contains "$CASE_OUTPUT" "REASON=sdk_install_required"
    assert_contains "$CASE_OUTPUT" "STATUS=decision_required"
    assert_contains "$(<"$MOCK_MANAGER_LOG")" "sync --dry-run --python"
    assert_not_contains "$(<"$MOCK_MANAGER_LOG")" "--frozen"
    assert_not_contains "$(<"$MOCK_MANAGER_LOG")" "lock --dry-run"
    assert_not_contains "$(<"$MOCK_MANAGER_LOG")" "add datalens-sdk"
    [ "$(<"$MOCK_UV_PYTHON.sdk-installed")" = "0.5.0" ] \
        || fail "uv drift check changed the installed SDK"

    run_bootstrap --install-sdk
    assert_contains "$CASE_OUTPUT" "SDK=installed_now"
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=0.4.0"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_contains "$(<"$MOCK_MANAGER_LOG")" "sync --python"
    assert_not_contains "$(<"$MOCK_MANAGER_LOG")" "--frozen"
    assert_not_contains "$(<"$MOCK_MANAGER_LOG")" "add datalens-sdk"
    [ "$(<"$MOCK_UV_PYTHON.sdk-installed")" = "0.4.0" ] \
        || fail "uv sync did not restore the locked SDK"
}

test_uv_stale_lock_requires_sync_before_freshness() {
    new_case uv-stale-lock
    printf '[project]\ndependencies = ["datalens-sdk==0.3.0"]\n' >"$CASE_PROJECT/pyproject.toml"
    printf '0.4.0\n' >"$CASE_PROJECT/uv.lock"
    MOCK_UV_PYTHON="$CASE_PROJECT/.venv/bin/python"
    MOCK_MANAGER_OWNERSHIP_MODE="stale_lock"
    MOCK_MANAGER_LOCKED_VERSION="0.4.0"
    MOCK_MANAGER_MANIFEST_VERSION="0.3.0"
    MOCK_MANAGER_AVAILABLE_VERSION="0.3.0"
    export MOCK_UV_PYTHON MOCK_MANAGER_OWNERSHIP_MODE MOCK_MANAGER_LOCKED_VERSION \
        MOCK_MANAGER_MANIFEST_VERSION MOCK_MANAGER_AVAILABLE_VERSION
    make_python "$MOCK_UV_PYTHON" "3.12.11" success "0.3.0" success ">=3" yes success "0.4.0"
    MOCK_MANAGER_AVAILABLE_VERSION="0.3.0"
    export MOCK_MANAGER_AVAILABLE_VERSION
    make_uv "$CASE_TOOLS/uv"

    run_bootstrap
    assert_contains "$CASE_OUTPUT" "SDK=missing"
    assert_not_contains "$CASE_OUTPUT" "SDK_VERSION="
    assert_not_contains "$CASE_OUTPUT" "AVAILABLE_SDK_VERSION="
    assert_contains "$CASE_OUTPUT" "REASON=sdk_install_required"
    assert_contains "$CASE_OUTPUT" "STATUS=decision_required"
    assert_contains "$(<"$MOCK_MANAGER_LOG")" "sync --dry-run --python"
    assert_not_contains "$(<"$MOCK_MANAGER_LOG")" "--frozen"
    assert_not_contains "$(<"$MOCK_MANAGER_LOG")" "lock --dry-run"
    assert_not_contains "$(<"$MOCK_MANAGER_LOG")" "add datalens-sdk"
    [ "$(<"$CASE_PROJECT/uv.lock")" = "0.4.0" ] \
        || fail "uv drift check changed the stale lock"
    [ "$(<"$MOCK_UV_PYTHON.sdk-installed")" = "0.4.0" ] \
        || fail "uv drift check changed the installed SDK"

    run_bootstrap --install-sdk
    assert_contains "$CASE_OUTPUT" "SDK=installed_now"
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=0.3.0"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_contains "$(<"$MOCK_MANAGER_LOG")" "sync --python"
    assert_not_contains "$(<"$MOCK_MANAGER_LOG")" "--frozen"
    assert_not_contains "$(<"$MOCK_MANAGER_LOG")" "add datalens-sdk"
    [ "$(<"$CASE_PROJECT/uv.lock")" = "0.3.0" ] \
        || fail "uv sync did not update the stale lock"
    [ "$(<"$MOCK_UV_PYTHON.sdk-installed")" = "0.3.0" ] \
        || fail "uv sync did not install the manifest SDK"
}

test_poetry_version_drift_requires_install_before_freshness() {
    new_case poetry-version-drift
    touch "$CASE_PROJECT/poetry.lock"
    MOCK_POETRY_PYTHON="$CASE_PROJECT/.venv/bin/python"
    MOCK_MANAGER_OWNERSHIP_MODE="downgrade"
    MOCK_MANAGER_LOCKED_VERSION="0.3.0"
    MOCK_MANAGER_AVAILABLE_VERSION="0.6.0"
    MOCK_POETRY_DEPENDENCY_MODE="downgrade"
    MOCK_POETRY_DECLARED_VERSION="0.3.0"
    export MOCK_POETRY_PYTHON MOCK_MANAGER_OWNERSHIP_MODE MOCK_MANAGER_LOCKED_VERSION \
        MOCK_MANAGER_AVAILABLE_VERSION MOCK_POETRY_DEPENDENCY_MODE MOCK_POETRY_DECLARED_VERSION
    make_python "$MOCK_POETRY_PYTHON" "3.12.11" success "0.6.0" success ">=3" yes success "0.5.0"
    MOCK_MANAGER_AVAILABLE_VERSION="0.6.0"
    export MOCK_MANAGER_AVAILABLE_VERSION
    make_poetry "$CASE_TOOLS/poetry"

    run_bootstrap
    assert_contains "$CASE_OUTPUT" "SDK=missing"
    assert_not_contains "$CASE_OUTPUT" "SDK_VERSION="
    assert_contains "$CASE_OUTPUT" "REASON=sdk_install_required"
    assert_contains "$CASE_OUTPUT" "STATUS=decision_required"
    assert_contains "$(<"$MOCK_MANAGER_LOG")" "install --sync --dry-run"
    assert_not_contains "$(<"$MOCK_MANAGER_LOG")" "add --dry-run"
    assert_not_contains "$(<"$MOCK_MANAGER_LOG")" "add datalens-sdk"
    [ "$(<"$MOCK_POETRY_PYTHON.sdk-installed")" = "0.5.0" ] \
        || fail "Poetry drift check changed the installed SDK"

    run_bootstrap --install-sdk
    assert_contains "$CASE_OUTPUT" "SDK=installed_now"
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=0.3.0"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_contains "$(<"$MOCK_MANAGER_LOG")" "install --no-root --no-interaction --no-ansi"
    assert_not_contains "$(<"$MOCK_MANAGER_LOG")" "add datalens-sdk"
    [ "$(<"$MOCK_POETRY_PYTHON.sdk-installed")" = "0.3.0" ] \
        || fail "Poetry install did not restore the locked SDK"
}

test_managed_drift_reconciliation_failure_preserves_environment() {
    new_case uv-drift-sync-failure
    touch "$CASE_PROJECT/uv.lock"
    MOCK_UV_PYTHON="$CASE_PROJECT/.venv/bin/python"
    MOCK_MANAGER_OWNERSHIP_MODE="update"
    MOCK_MANAGER_LOCKED_VERSION="0.4.0"
    MOCK_MANAGER_SYNC_MODE="fail"
    export MOCK_UV_PYTHON MOCK_MANAGER_OWNERSHIP_MODE MOCK_MANAGER_LOCKED_VERSION \
        MOCK_MANAGER_SYNC_MODE
    make_python "$MOCK_UV_PYTHON" "3.12.11" success "0.6.0" success ">=3" yes success "0.5.0"
    make_uv "$CASE_TOOLS/uv"
    touch "$CASE_PROJECT/.venv/user-sentinel"

    run_bootstrap --install-sdk
    assert_contains "$CASE_OUTPUT" "VENV=reused"
    assert_contains "$CASE_OUTPUT" "SDK=missing"
    assert_contains "$CASE_OUTPUT" "REASON=sdk_install_failed"
    assert_contains "$CASE_OUTPUT" "STATUS=blocked"
    assert_not_contains "$(<"$MOCK_MANAGER_LOG")" "add datalens-sdk"
    [ "$(<"$MOCK_UV_PYTHON.sdk-installed")" = "0.5.0" ] \
        || fail "failed uv sync changed the installed SDK"
    [ -e "$CASE_PROJECT/.venv/user-sentinel" ] \
        || fail "failed uv sync replaced the managed environment"
}

test_managed_ownership_check_failure_never_reports_ready() {
    new_case uv-ownership-failed
    touch "$CASE_PROJECT/uv.lock"
    MOCK_UV_PYTHON="$CASE_PROJECT/.venv/bin/python"
    export MOCK_UV_PYTHON
    make_python "$MOCK_UV_PYTHON" "7.4.2" success "9.9.0" success ">=3" yes
    make_uv "$CASE_TOOLS/uv"
    MOCK_MANAGER_OWNERSHIP_MODE="fail"
    export MOCK_MANAGER_OWNERSHIP_MODE

    run_bootstrap
    assert_contains "$CASE_OUTPUT" "SDK=installed"
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=9.9.0"
    assert_contains "$CASE_OUTPUT" "REASON=sdk_version_check_failed"
    assert_contains "$CASE_OUTPUT" "STATUS=decision_required"
    assert_not_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_not_contains "$(<"$MOCK_MANAGER_LOG")" "lock --dry-run"
}

test_managed_project_without_tool_is_preserved() {
    new_case managed-tool-missing
    touch "$CASE_PROJECT/uv.lock"
    make_python "$CASE_TOOLS/python3" "7.4.2" success "9.8.7"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "PYTHON_SOURCE=uv"
    assert_contains "$CASE_OUTPUT" "REASON=managed_environment_unavailable"
    assert_contains "$CASE_OUTPUT" "STATUS=blocked"
    [ ! -e "$CASE_PROJECT/.venv" ] || fail "bootstrap created .venv for an unresolved managed project"
}

test_invalid_managed_environment_is_preserved() {
    new_case managed-env-invalid
    touch "$CASE_PROJECT/poetry.lock"
    MOCK_POETRY_PYTHON="${CASE_DIR}/poetry-cache/bin/python"
    export MOCK_POETRY_PYTHON
    make_python "$MOCK_POETRY_PYTHON" "7.4.2" success "9.8.7" success ">=3" yes success "9.8.7" newer invalid
    make_poetry "$CASE_TOOLS/poetry"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "PYTHON_SOURCE=poetry"
    assert_contains "$CASE_OUTPUT" "REASON=managed_environment_invalid"
    assert_contains "$CASE_OUTPUT" "STATUS=blocked"
    [ ! -e "$CASE_PROJECT/.venv" ] || fail "bootstrap replaced an invalid managed environment"
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
    assert_contains "$(<"$CASE_DIR/python-calls")" "pip index versions datalens-sdk"
    assert_not_contains "$(<"$CASE_DIR/python-calls")" "pip install"
    assert_not_contains "$(<"$CASE_DIR/python-calls")" "--upgrade pip"
}

test_existing_venv_uses_its_own_pip_policy() {
    local expected_project=""
    new_case selected-pip-policy
    mkdir -p "$CASE_PROJECT/.venv"
    expected_project="$(cd "$CASE_PROJECT" && pwd -P)"
    printf '%s\n' '[global]' 'index-url = https://packages.example/simple' >"$CASE_PROJECT/.venv/pip.conf"
    make_python "$CASE_PROJECT/.venv/bin/python" "7.4.2" success "9.8.7" success ">=3" yes
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_contains "$(<"$CASE_DIR/python-calls")" "$expected_project/.venv/bin/python -m pip index versions datalens-sdk"
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

test_base_without_pip_uses_policy_preserving_probe() {
    local base_prefix=""
    new_case base-without-pip
    base_prefix="${CASE_DIR}/base-python"
    printf '%s\n' '[project]' 'requires-python = ">=3.10,<3.14"' >"$CASE_PROJECT/pyproject.toml"
    make_python "${base_prefix}/bin/python3" "3.12.11" success "9.9.0" success ">=3.10" no \
        success "9.9.0" newer valid compatible ">=3.10,<3.14" "" missing private-index-policy
    printf '%s\n' '[global]' '# private-index-policy' \
        'index-url = https://packages.example/simple' >"${base_prefix}/pip.conf"
    CASE_PATH="${base_prefix}/bin:${CASE_TOOLS}"

    run_bootstrap
    assert_contains "$CASE_OUTPUT" "VENV=created"
    assert_contains "$CASE_OUTPUT" "PYTHON_VERSION=3.12.11"
    assert_contains "$CASE_OUTPUT" "PROJECT_REQUIRES_PYTHON=>=3.10,<3.14"
    assert_contains "$CASE_OUTPUT" "SDK=installed_now"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_contains "$(<"$CASE_DIR/python-calls")" "/probe."
    assert_not_contains "$(<"$CASE_DIR/python-calls")" "${base_prefix}/bin/python3 -m pip"
    grep -Fq -- private-index-policy "$CASE_PROJECT/.venv/pip.conf" \
        || fail "project venv did not retain the base pip source policy"
}

test_fresh_bootstrap_uses_venv_when_pip_requires_virtualenv() {
    local base_prefix=""
    new_case require-virtualenv
    base_prefix="${CASE_DIR}/base-python"
    make_python "${base_prefix}/bin/python3" "3.12.11" success "9.9.0"
    CASE_PATH="${base_prefix}/bin:${CASE_TOOLS}"
    PIP_REQUIRE_VIRTUALENV=true
    export PIP_REQUIRE_VIRTUALENV

    run_bootstrap
    assert_contains "$CASE_OUTPUT" "VENV=created"
    assert_contains "$CASE_OUTPUT" "PYTHON_VERSION=3.12.11"
    assert_contains "$CASE_OUTPUT" "SDK=installed_now"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_contains "$(<"$CASE_DIR/python-calls")" "/probe."
    assert_not_contains "$(<"$CASE_DIR/python-calls")" "${base_prefix}/bin/python3 -m pip"
}

test_old_ensurepip_probe_uses_vendored_toml() {
    local base_prefix=""
    new_case legacy-ensurepip
    base_prefix="${CASE_DIR}/base-python"
    printf '%s\n' '[project]' 'requires-python = ">=3.8"' >"$CASE_PROJECT/pyproject.toml"
    make_python "${base_prefix}/bin/python3" "3.8.6" success "9.9.0" success ">=3.8" no \
        success "9.9.0" newer valid compatible ">=3.8" "" available "" legacy
    CASE_PATH="${base_prefix}/bin:${CASE_TOOLS}"

    run_bootstrap
    assert_contains "$CASE_OUTPUT" "VENV=created"
    assert_contains "$CASE_OUTPUT" "PYTHON_VERSION=3.8.6"
    assert_contains "$CASE_OUTPUT" "PROJECT_REQUIRES_PYTHON=>=3.8"
    assert_contains "$CASE_OUTPUT" "SDK=installed_now"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_contains "$(<"$CASE_DIR/python-calls")" "/probe."
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

test_pip_21_macos_incompatibility_output_finds_alternative() {
    local fixture="$TEST_ROOT/tests/datalens-sdk/fixtures/pip-21.2.4-python-incompatible.txt"
    new_case pip-21-macos
    make_python "$CASE_TOOLS/python3" "3.9.6" incompatible_fixture unused success unused no success unused newer valid compatible "" "$fixture"
    make_python "$CASE_TOOLS/python3.13" "3.13.6" success "9.9.0"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "PYTHON_VERSION=3.13.6"
    assert_contains "$CASE_OUTPUT" "REQUIRES_PYTHON=>=3.10"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
}

test_current_pip_incompatibility_output_finds_alternative() {
    local fixture="$TEST_ROOT/tests/datalens-sdk/fixtures/pip-26.0.1-python-incompatible.txt"
    new_case pip-current
    make_python "$CASE_TOOLS/python3" "3.9.0" incompatible_fixture unused success unused no success unused newer valid compatible "" "$fixture"
    make_python "$CASE_TOOLS/python3.12" "3.12.11" success "9.9.0"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "PYTHON_VERSION=3.12.11"
    assert_contains "$CASE_OUTPUT" "REQUIRES_PYTHON=>=3.10"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
}

test_hidden_requires_python_finds_alternative_without_misreporting_index() {
    new_case hidden-requires-python
    make_python "$CASE_TOOLS/python3" "3.9.6" incompatible_silent "9.9.0"
    make_python "$CASE_TOOLS/python3.13" "3.13.6" success "9.9.0"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "PYTHON_VERSION=3.13.6"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_not_contains "$CASE_OUTPUT" "REASON=package_index_query_failed"
    assert_contains "$(<"$CASE_DIR/python-calls")" "--ignore-requires-python"
}

test_requires_python_space_format_is_recognized() {
    local fixture="$TEST_ROOT/tests/datalens-sdk/fixtures/pip-requires-python-python-incompatible.txt"
    new_case pip-requires-python-space
    make_python "$CASE_TOOLS/python3" "3.9.0" incompatible_fixture unused success unused no success unused newer valid compatible "" "$fixture"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "REQUIRES_PYTHON=>=3.10"
    assert_contains "$CASE_OUTPUT" "REASON=no_compatible_python"
}

test_project_requires_python_selects_intersection() {
    new_case project-requires-python
    printf '%s\n' '[project]' 'requires-python = ">=3.10,<3.14"' >"$CASE_PROJECT/pyproject.toml"
    make_python "$CASE_TOOLS/python3" "3.14.0" success "9.9.0" success ">=3" no success "9.9.0" newer valid incompatible ">=3.10,<3.14"
    make_python "$CASE_TOOLS/python3.13" "3.13.6" success "9.9.0" success ">=3" no success "9.9.0" newer valid compatible ">=3.10,<3.14"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "PYTHON_VERSION=3.13.6"
    assert_contains "$CASE_OUTPUT" "PROJECT_REQUIRES_PYTHON=>=3.10,<3.14"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_not_contains "$(<"$CASE_DIR/python-calls")" "$CASE_TOOLS/python3 -m pip index versions datalens-sdk"
}

test_python_version_pin_is_not_overridden() {
    new_case configured-python
    printf '%s\n' '3.12' >"$CASE_PROJECT/.python-version"
    make_python "$CASE_TOOLS/python3" "3.14.0" success "9.9.0"
    make_python "$CASE_TOOLS/python3.13" "3.13.6" success "9.9.0"
    make_python "$CASE_TOOLS/python3.12" "3.12.11" success "9.9.0"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "CONFIGURED_PYTHON=3.12"
    assert_contains "$CASE_OUTPUT" "PYTHON_VERSION=3.12.11"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
}

test_unavailable_python_version_pin_blocks_creation() {
    new_case configured-python-unavailable
    printf '%s\n' '3.12' >"$CASE_PROJECT/.python-version"
    make_python "$CASE_TOOLS/python3" "3.14.0" success "9.9.0"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "CONFIGURED_PYTHON=3.12"
    assert_contains "$CASE_OUTPUT" "REASON=configured_python_unavailable"
    assert_contains "$CASE_OUTPUT" "STATUS=blocked"
    [ ! -e "$CASE_PROJECT/.venv" ] || fail "unavailable configured Python created a venv"
}

test_non_numeric_python_version_pin_blocks_creation() {
    new_case configured-python-non-numeric
    printf '%s\n' '3.bad.12' >"$CASE_PROJECT/.python-version"
    make_python "$CASE_TOOLS/python3" "3.12.11" success "9.9.0"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "CONFIGURED_PYTHON=3.bad.12"
    assert_contains "$CASE_OUTPUT" "REASON=configured_python_unavailable"
    assert_contains "$CASE_OUTPUT" "STATUS=blocked"
    [ ! -e "$CASE_PROJECT/.venv" ] || fail "non-numeric configured Python created a venv"
}

test_incompatible_python_version_pin_blocks_creation() {
    new_case configured-python-incompatible
    printf '%s\n' '3.14' >"$CASE_PROJECT/.python-version"
    printf '%s\n' '[project]' 'requires-python = "<3.14"' >"$CASE_PROJECT/pyproject.toml"
    make_python "$CASE_TOOLS/python3" "3.14.0" success "9.9.0" success ">=3" no success "9.9.0" newer valid incompatible "<3.14"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "CONFIGURED_PYTHON=3.14"
    assert_contains "$CASE_OUTPUT" "PROJECT_REQUIRES_PYTHON=<3.14"
    assert_contains "$CASE_OUTPUT" "REASON=configured_python_incompatible"
    assert_contains "$CASE_OUTPUT" "STATUS=blocked"
    [ ! -e "$CASE_PROJECT/.venv" ] || fail "incompatible configured Python created a venv"
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
    assert_contains "$CASE_OUTPUT" "REASON=package_index_query_failed"
    assert_contains "$CASE_OUTPUT" "STATUS=blocked"
    assert_not_contains "$CASE_ERROR_OUTPUT" "Python 3.9.9"
    [ ! -e "$CASE_PROJECT/.venv" ] || fail "non-Python failure created .venv"
}

test_package_index_query_failure_is_distinct() {
    new_case index-query-error
    make_python "$CASE_TOOLS/python3" "5.1.0" fail "unused"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "REASON=package_index_query_failed"
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
        'REASON=sdk_install_required' \
        'REASON=sdk_update_available' \
        'REASON=sdk_version_check_failed' \
        'REASON=sdk_upgrade_failed' \
        'REASON=sdk_upgrade_target_unavailable' \
        'managed_environment_unavailable' \
        'managed_environment_invalid' \
        'configured_python_unavailable' \
        'configured_python_incompatible' \
        'PROJECT_REQUIRES_PYTHON' \
        'venv_invalid' \
        'CHANGELOG_URL' \
        '--install-sdk' \
        '--upgrade-sdk "$AVAILABLE_SDK_VERSION"'
    do
        grep -Fq -- "$required_text" "$skill_file" || fail "skill omits bootstrap contract: $required_text"
    done
}

test_sdk_version_check_failure_requires_installed_sdk() {
    if grep -Fq -- 'bootstrap_emit_install_decision "sdk_version_check_failed"' "$BOOTSTRAP_SCRIPT"; then
        fail "sdk_version_check_failed must not be emitted for a missing SDK"
    fi
}

test_informational_guard_precedes_bootstrap() {
    local skill_file="$TEST_ROOT/skills/datalens-sdk/SKILL.md"
    local guard_line=""
    local bootstrap_line=""
    guard_line="$(grep -n -m1 'Do not run bootstrap' "$skill_file" | awk -F: '{print $1}')"
    bootstrap_line="$(grep -n -m1 'scripts/bootstrap.sh' "$skill_file" | awk -F: '{print $1}')"
    [ -n "$guard_line" ] && [ -n "$bootstrap_line" ] && [ "$guard_line" -lt "$bootstrap_line" ] \
        || fail "informational guard must precede the bootstrap command"
}

test_alternate_profile_reuses_common_pip_flow() {
    new_case alternate-profile-pip
    use_alternate_profile "https://example.test/private-sdk/changelog"
    make_python "$CASE_PROJECT/.venv/bin/python" "3.12.4" success "1.2.3" success ">=3.10" yes
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=1.2.3"
    assert_contains "$CASE_OUTPUT" "CHANGELOG_URL=https://example.test/private-sdk/changelog"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_contains "$(<"$CASE_DIR/python-calls")" "index versions example-private-sdk"
    assert_contains "$CASE_ERROR_OUTPUT" "example-private-sdk 1.2.3"
    assert_not_contains "$CASE_ERROR_OUTPUT" "installed datalens-sdk"
}

test_alternate_profile_uses_native_uv_commands() {
    new_case alternate-profile-uv
    use_alternate_profile
    touch "$CASE_PROJECT/uv.lock"
    MOCK_UV_PYTHON="$CASE_PROJECT/.venv/bin/python"
    export MOCK_UV_PYTHON
    make_python "$MOCK_UV_PYTHON" "3.12.4" success "1.2.3"
    make_uv "$CASE_TOOLS/uv"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "REASON=sdk_install_required"
    assert_contains "$CASE_OUTPUT" "STATUS=decision_required"
    run_bootstrap --install-sdk
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=1.2.3"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_contains "$(<"$MOCK_MANAGER_LOG")" "add example-private-sdk"
}

test_invalid_profile_blocks_before_project_mutation() {
    new_case invalid-profile
    DATALENS_BOOTSTRAP_DISTRIBUTION='../unsafe'
    DATALENS_BOOTSTRAP_IMPORT_MODULE='unsafe-module'
    DATALENS_BOOTSTRAP_CHANGELOG_URL=''
    export DATALENS_BOOTSTRAP_DISTRIBUTION DATALENS_BOOTSTRAP_IMPORT_MODULE \
        DATALENS_BOOTSTRAP_CHANGELOG_URL
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "REASON=invalid_profile"
    assert_contains "$CASE_OUTPUT" "STATUS=blocked"
    [ ! -e "$CASE_PROJECT/.venv" ] || fail "invalid profile changed the project"
    [ ! -s "$CASE_DIR/python-calls" ] || fail "invalid profile invoked Python"
}

test_partial_profiles_are_rejected_before_project_inspection() {
    local combination=""
    for combination in distribution import changelog distribution-import distribution-changelog import-changelog; do
        new_case "partial-profile-${combination}"
        case "$combination" in
            distribution)
                DATALENS_BOOTSTRAP_DISTRIBUTION="example-private-sdk"
                export DATALENS_BOOTSTRAP_DISTRIBUTION
                ;;
            import)
                DATALENS_BOOTSTRAP_IMPORT_MODULE="example_private_sdk"
                export DATALENS_BOOTSTRAP_IMPORT_MODULE
                ;;
            changelog)
                DATALENS_BOOTSTRAP_CHANGELOG_URL=""
                export DATALENS_BOOTSTRAP_CHANGELOG_URL
                ;;
            distribution-import)
                DATALENS_BOOTSTRAP_DISTRIBUTION="example-private-sdk"
                DATALENS_BOOTSTRAP_IMPORT_MODULE="example_private_sdk"
                export DATALENS_BOOTSTRAP_DISTRIBUTION DATALENS_BOOTSTRAP_IMPORT_MODULE
                ;;
            distribution-changelog)
                DATALENS_BOOTSTRAP_DISTRIBUTION="example-private-sdk"
                DATALENS_BOOTSTRAP_CHANGELOG_URL=""
                export DATALENS_BOOTSTRAP_DISTRIBUTION DATALENS_BOOTSTRAP_CHANGELOG_URL
                ;;
            import-changelog)
                DATALENS_BOOTSTRAP_IMPORT_MODULE="example_private_sdk"
                DATALENS_BOOTSTRAP_CHANGELOG_URL=""
                export DATALENS_BOOTSTRAP_IMPORT_MODULE DATALENS_BOOTSTRAP_CHANGELOG_URL
                ;;
        esac
        make_python "$CASE_PROJECT/.venv/bin/python" "3.12.4" success "1.2.3" success ">=3.10" yes
        run_bootstrap
        assert_contains "$CASE_OUTPUT" "REASON=invalid_profile"
        assert_contains "$CASE_OUTPUT" "STATUS=blocked"
        [ ! -s "$CASE_DIR/python-calls" ] || fail "partial profile ${combination} inspected the project"
    done
}

test_empty_profile_identity_fields_are_rejected() {
    local field=""
    for field in distribution import; do
        new_case "empty-profile-${field}"
        use_alternate_profile
        case "$field" in
            distribution) DATALENS_BOOTSTRAP_DISTRIBUTION="" ;;
            import) DATALENS_BOOTSTRAP_IMPORT_MODULE="" ;;
        esac
        export DATALENS_BOOTSTRAP_DISTRIBUTION DATALENS_BOOTSTRAP_IMPORT_MODULE
        run_bootstrap
        assert_contains "$CASE_OUTPUT" "REASON=invalid_profile"
        assert_contains "$CASE_OUTPUT" "STATUS=blocked"
        [ ! -s "$CASE_DIR/python-calls" ] || fail "empty ${field} invoked Python"
    done
}

test_empty_alternate_changelog_is_valid() {
    new_case empty-alternate-changelog
    use_alternate_profile
    make_python "$CASE_PROJECT/.venv/bin/python" "3.12.4" success "1.2.3" success ">=3.10" yes
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=1.2.3"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_not_contains "$CASE_OUTPUT" "CHANGELOG_URL="
}

test_partial_profile_cannot_report_false_ready() {
    new_case partial-profile-false-ready
    MOCK_DISTRIBUTION="example-private-sdk"
    MOCK_IMPORT_MODULE="datalens_sdk"
    DATALENS_BOOTSTRAP_DISTRIBUTION="$MOCK_DISTRIBUTION"
    export MOCK_DISTRIBUTION MOCK_IMPORT_MODULE DATALENS_BOOTSTRAP_DISTRIBUTION
    make_python "$CASE_PROJECT/.venv/bin/python" "3.12.4" success "1.2.3" success ">=3.10" yes
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "REASON=invalid_profile"
    assert_contains "$CASE_OUTPUT" "STATUS=blocked"
    assert_not_contains "$CASE_OUTPUT" "STATUS=ready"
    [ ! -s "$CASE_DIR/python-calls" ] || fail "mixed package identity reached the health check"
}

test_poetry_source_without_alternate_profile_is_rejected() {
    new_case poetry-source-without-profile
    DATALENS_BOOTSTRAP_POETRY_SOURCE="yandex-team"
    export DATALENS_BOOTSTRAP_POETRY_SOURCE
    make_python "$CASE_PROJECT/.venv/bin/python" "3.12.4" success "1.2.3" success ">=3.10" yes
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "REASON=invalid_profile"
    assert_contains "$CASE_OUTPUT" "STATUS=blocked"
    [ ! -s "$CASE_DIR/python-calls" ] || fail "standalone Poetry source inspected the project"
}

test_alternate_profile_poetry_requires_configured_source() {
    new_case alternate-profile-poetry-source-missing
    use_alternate_poetry_profile
    touch "$CASE_PROJECT/poetry.lock"
    MOCK_POETRY_PYTHON="$CASE_PROJECT/.venv/bin/python"
    MOCK_POETRY_SOURCE_MODE="missing"
    export MOCK_POETRY_PYTHON MOCK_POETRY_SOURCE_MODE
    make_python "$MOCK_POETRY_PYTHON" "3.12.4" success "1.2.3"
    make_poetry "$CASE_TOOLS/poetry"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "PYTHON_SOURCE=poetry"
    assert_contains "$CASE_OUTPUT" "REASON=poetry_source_configuration_required"
    assert_contains "$CASE_OUTPUT" "STATUS=blocked"
    assert_contains "$(<"$MOCK_MANAGER_LOG")" "source show --no-interaction --no-ansi yandex-team"
    assert_not_contains "$(<"$MOCK_MANAGER_LOG")" "add "
    [ ! -s "$CASE_DIR/python-calls" ] || fail "missing Poetry source reached the environment"
}

test_alternate_profile_poetry_installs_undeclared_dependency() {
    new_case alternate-profile-poetry-undeclared
    use_alternate_poetry_profile
    touch "$CASE_PROJECT/poetry.lock"
    MOCK_POETRY_PYTHON="$CASE_PROJECT/.venv/bin/python"
    export MOCK_POETRY_PYTHON
    make_python "$MOCK_POETRY_PYTHON" "3.12.4" success "1.2.3"
    make_poetry "$CASE_TOOLS/poetry"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "REASON=sdk_install_required"
    run_bootstrap --install-sdk
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=1.2.3"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_contains "$(<"$MOCK_MANAGER_LOG")" "add example-private-sdk --source yandex-team"
}

test_alternate_profile_poetry_reconciles_declared_dependency() {
    new_case alternate-profile-poetry-declared
    use_alternate_poetry_profile
    printf '%s\n' '[tool.poetry.dependencies]' 'example-private-sdk = "0.3.0"' >"$CASE_PROJECT/pyproject.toml"
    printf '%s\n' '[[package]]' 'name = "example-private-sdk"' 'version = "0.3.0"' >"$CASE_PROJECT/poetry.lock"
    MOCK_POETRY_PYTHON="$CASE_PROJECT/.venv/bin/python"
    MOCK_POETRY_DEPENDENCY_MODE="declared"
    MOCK_POETRY_DECLARED_VERSION="0.3.0"
    export MOCK_POETRY_PYTHON MOCK_POETRY_DEPENDENCY_MODE MOCK_POETRY_DECLARED_VERSION
    make_python "$MOCK_POETRY_PYTHON" "3.12.4" success "1.2.3"
    make_poetry "$CASE_TOOLS/poetry"
    run_bootstrap --install-sdk
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=0.3.0"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_contains "$(<"$MOCK_MANAGER_LOG")" "install --no-root --no-interaction --no-ansi"
    assert_not_contains "$(<"$MOCK_MANAGER_LOG")" "add example-private-sdk"
}

test_alternate_profile_poetry_checks_and_applies_upgrade() {
    new_case alternate-profile-poetry-upgrade
    use_alternate_poetry_profile
    touch "$CASE_PROJECT/poetry.lock"
    MOCK_POETRY_PYTHON="$CASE_PROJECT/.venv/bin/python"
    export MOCK_POETRY_PYTHON
    make_python "$MOCK_POETRY_PYTHON" "3.12.4" success "1.3.0" success ">=3.10" yes success "1.2.3" newer
    make_poetry "$CASE_TOOLS/poetry"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "AVAILABLE_SDK_VERSION=1.3.0"
    assert_contains "$CASE_OUTPUT" "REASON=sdk_update_available"
    assert_contains "$(<"$MOCK_MANAGER_LOG")" \
        "add --dry-run --no-interaction --no-ansi example-private-sdk@latest --source yandex-team"
    run_bootstrap --upgrade-sdk 1.3.0
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=1.3.0"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_contains "$(<"$MOCK_MANAGER_LOG")" \
        "add example-private-sdk==1.3.0 --source yandex-team"
}

test_alternate_profile_poetry_reconciles_ownership_drift() {
    new_case alternate-profile-poetry-drift
    use_alternate_poetry_profile
    touch "$CASE_PROJECT/poetry.lock"
    MOCK_POETRY_PYTHON="$CASE_PROJECT/.venv/bin/python"
    MOCK_MANAGER_OWNERSHIP_MODE="downgrade"
    MOCK_MANAGER_LOCKED_VERSION="0.3.0"
    MOCK_MANAGER_AVAILABLE_VERSION="0.6.0"
    MOCK_POETRY_DEPENDENCY_MODE="downgrade"
    MOCK_POETRY_DECLARED_VERSION="0.3.0"
    export MOCK_POETRY_PYTHON MOCK_MANAGER_OWNERSHIP_MODE MOCK_MANAGER_LOCKED_VERSION \
        MOCK_MANAGER_AVAILABLE_VERSION MOCK_POETRY_DEPENDENCY_MODE MOCK_POETRY_DECLARED_VERSION
    make_python "$MOCK_POETRY_PYTHON" "3.12.4" success "0.6.0" success ">=3.10" yes success "0.5.0"
    MOCK_MANAGER_AVAILABLE_VERSION="0.6.0"
    export MOCK_MANAGER_AVAILABLE_VERSION
    make_poetry "$CASE_TOOLS/poetry"
    run_bootstrap
    assert_contains "$CASE_OUTPUT" "REASON=sdk_install_required"
    assert_not_contains "$(<"$MOCK_MANAGER_LOG")" "add --dry-run"
    run_bootstrap --install-sdk
    assert_contains "$CASE_OUTPUT" "SDK_VERSION=0.3.0"
    assert_contains "$CASE_OUTPUT" "STATUS=ready"
    assert_contains "$(<"$MOCK_MANAGER_LOG")" "install --no-root --no-interaction --no-ansi"
    assert_not_contains "$(<"$MOCK_MANAGER_LOG")" "add example-private-sdk"
}

for test_name in \
    test_stale_project_python_symlink_is_rejected \
    test_environment_identity_is_rechecked_before_project_pip \
    test_uv_managed_environment_is_reused \
    test_poetry_managed_environment_is_reused \
    test_uv_marker_only_is_detected_with_bsd_grep \
    test_poetry_marker_only_is_detected_with_bsd_grep \
    test_uv_array_source_marker_uses_native_resolver \
    test_poetry_array_source_marker_uses_native_resolver \
    test_uv_plugin_section_does_not_claim_plain_venv \
    test_managed_install_requires_consent_and_uses_uv \
    test_declared_poetry_dependency_is_installed_without_readding \
    test_poetry_install_plan_failure_does_not_mutate_project \
    test_poetry_declared_sdk_downgrade_uses_install \
    test_managed_upgrade_uses_poetry_after_consent \
    test_managed_install_rejects_legacy_version_argument \
    test_managed_install_failure_preserves_environment \
    test_uv_pip_installed_sdk_requires_manager_ownership \
    test_poetry_pip_installed_sdk_requires_manager_ownership \
    test_uv_version_drift_requires_sync_before_freshness \
    test_uv_stale_lock_requires_sync_before_freshness \
    test_poetry_version_drift_requires_install_before_freshness \
    test_managed_drift_reconciliation_failure_preserves_environment \
    test_managed_ownership_check_failure_never_reports_ready \
    test_managed_project_without_tool_is_preserved \
    test_invalid_managed_environment_is_preserved \
    test_existing_current_sdk_is_reused_after_check \
    test_existing_venv_uses_its_own_pip_policy \
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
    test_base_without_pip_uses_policy_preserving_probe \
    test_fresh_bootstrap_uses_venv_when_pip_requires_virtualenv \
    test_old_ensurepip_probe_uses_vendored_toml \
    test_path_alternative_after_python_rejection \
    test_pip_21_macos_incompatibility_output_finds_alternative \
    test_current_pip_incompatibility_output_finds_alternative \
    test_hidden_requires_python_finds_alternative_without_misreporting_index \
    test_requires_python_space_format_is_recognized \
    test_project_requires_python_selects_intersection \
    test_python_version_pin_is_not_overridden \
    test_unavailable_python_version_pin_blocks_creation \
    test_non_numeric_python_version_pin_blocks_creation \
    test_incompatible_python_version_pin_blocks_creation \
    test_pyenv_alternative_after_python_rejection \
    test_broken_default_shim_does_not_hide_later_python \
    test_non_python_error_does_not_cycle \
    test_package_index_query_failure_is_distinct \
    test_existing_incompatible_venv_is_preserved \
    test_no_compatible_python \
    test_failed_project_creation_leaves_no_venv \
    test_failed_project_install_leaves_no_venv \
    test_project_path_with_spaces \
    test_no_static_version_pins \
    test_skill_documents_consent_protocol \
    test_sdk_version_check_failure_requires_installed_sdk \
    test_informational_guard_precedes_bootstrap \
    test_alternate_profile_reuses_common_pip_flow \
    test_alternate_profile_uses_native_uv_commands \
    test_invalid_profile_blocks_before_project_mutation \
    test_partial_profiles_are_rejected_before_project_inspection \
    test_empty_profile_identity_fields_are_rejected \
    test_empty_alternate_changelog_is_valid \
    test_partial_profile_cannot_report_false_ready \
    test_poetry_source_without_alternate_profile_is_rejected \
    test_alternate_profile_poetry_requires_configured_source \
    test_alternate_profile_poetry_installs_undeclared_dependency \
    test_alternate_profile_poetry_reconciles_declared_dependency \
    test_alternate_profile_poetry_checks_and_applies_upgrade \
    test_alternate_profile_poetry_reconciles_ownership_drift
do
    "$test_name"
    TESTS_RUN=$((TESTS_RUN + 1))
    printf 'ok %d - %s\n' "$TESTS_RUN" "$test_name"
done

printf '%d bootstrap tests passed\n' "$TESTS_RUN"
