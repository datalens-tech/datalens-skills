#!/usr/bin/env bash
# Bootstrap datalens-sdk without encoding SDK or Python compatibility versions.
#
# Run from the user's project directory. The script:
#   * prefers a uv/Poetry-managed environment over a same-named ./.venv;
#   * verifies environment identity before every project-environment mutation;
#   * queries the package index without installing the SDK or its dependencies;
#   * asks its caller to obtain consent before changing managed dependencies;
#   * changes interpreter only after pip reports Requires-Python incompatibility;
#   * creates ./.venv only after a compatible interpreter has been proven.
#
# Machine-readable output follows the ---BOOTSTRAP--- marker. The script always
# exits zero; callers must act on STATUS. Pass --install-sdk VERSION or
# --upgrade-sdk VERSION only after the user approves the exact
# AVAILABLE_SDK_VERSION reported by a prior run.

set -uo pipefail

BOOTSTRAP_CWD="$(pwd -P)"
BOOTSTRAP_PROJECT_VENV="${BOOTSTRAP_CWD}/.venv"
BOOTSTRAP_VENV="$BOOTSTRAP_PROJECT_VENV"
BOOTSTRAP_TMP_ROOT=""

BOOTSTRAP_VENV_STATE="failed"
BOOTSTRAP_PYTHON=""
BOOTSTRAP_PYTHON_VERSION=""
BOOTSTRAP_PYTHON_SOURCE=""
BOOTSTRAP_SDK="missing"
BOOTSTRAP_SDK_VERSION=""
BOOTSTRAP_AVAILABLE_SDK_VERSION=""
BOOTSTRAP_CHANGELOG_URL="https://github.com/datalens-tech/datalens-sdk/blob/main/CHANGELOG.md"
BOOTSTRAP_REQUIRES_PYTHON=""
BOOTSTRAP_AVAILABLE_PYTHON=""
BOOTSTRAP_AVAILABLE_VERSION=""
BOOTSTRAP_REASON=""
BOOTSTRAP_STATUS="blocked"
BOOTSTRAP_ACTION="check"
BOOTSTRAP_EXPECTED_SDK_VERSION=""

PROBE_RESULT=""
PROBE_PYTHON=""
PROBE_SDK_VERSION=""
PROBE_REQUIREMENTS=""
PROBE_REASON=""
VERSION_RELATION=""
INSTALLED_AVAILABLE_RELATION=""
MANAGED_RESULT="none"
MANAGED_SOURCE=""

CANDIDATE_PATH=""
CANDIDATE_VERSION=""
CANDIDATE_SCORE=""
CANDIDATE_SOURCE=""
CANDIDATE_CANONICAL=""

bootstrap_note() {
    printf '%s\n' "$*" >&2
}

bootstrap_cleanup() {
    if [ -n "$BOOTSTRAP_TMP_ROOT" ] && [ -d "$BOOTSTRAP_TMP_ROOT" ]; then
        rm -rf -- "$BOOTSTRAP_TMP_ROOT"
    fi
}
trap bootstrap_cleanup EXIT HUP INT TERM

bootstrap_emit() {
    echo "---BOOTSTRAP---"
    echo "VENV=$BOOTSTRAP_VENV_STATE"
    [ -n "$BOOTSTRAP_PYTHON" ] && echo "PYTHON=$BOOTSTRAP_PYTHON"
    [ -n "$BOOTSTRAP_PYTHON_VERSION" ] && echo "PYTHON_VERSION=$BOOTSTRAP_PYTHON_VERSION"
    [ -n "$BOOTSTRAP_PYTHON_SOURCE" ] && echo "PYTHON_SOURCE=$BOOTSTRAP_PYTHON_SOURCE"
    echo "SDK=$BOOTSTRAP_SDK"
    [ -n "$BOOTSTRAP_SDK_VERSION" ] && echo "SDK_VERSION=$BOOTSTRAP_SDK_VERSION"
    [ -n "$BOOTSTRAP_AVAILABLE_SDK_VERSION" ] && echo "AVAILABLE_SDK_VERSION=$BOOTSTRAP_AVAILABLE_SDK_VERSION"
    [ -n "$BOOTSTRAP_CHANGELOG_URL" ] && echo "CHANGELOG_URL=$BOOTSTRAP_CHANGELOG_URL"
    [ -n "$BOOTSTRAP_REQUIRES_PYTHON" ] && echo "REQUIRES_PYTHON=$BOOTSTRAP_REQUIRES_PYTHON"
    [ -n "$BOOTSTRAP_AVAILABLE_PYTHON" ] && echo "AVAILABLE_PYTHON=$BOOTSTRAP_AVAILABLE_PYTHON"
    [ -n "$BOOTSTRAP_AVAILABLE_VERSION" ] && echo "AVAILABLE_PYTHON_VERSION=$BOOTSTRAP_AVAILABLE_VERSION"
    [ -n "$BOOTSTRAP_REASON" ] && echo "REASON=$BOOTSTRAP_REASON"
    echo "STATUS=$BOOTSTRAP_STATUS"
}

bootstrap_python_info() {
    # Sets version, sortable numeric score, and canonical executable path.
    # Executing the candidate filters out non-functional version-manager shims.
    local python_path="$1"
    local info=""
    info="$("$python_path" -c 'import os, sys; v=sys.version_info; print(f"{v.major}.{v.minor}.{v.micro}|{v.major * 100000000 + v.minor * 100000 + v.micro}|{os.path.realpath(sys.executable)}")' 2>/dev/null)" || return 1
    case "$info" in
        *'|'*'|'*) : ;;
        *) return 1 ;;
    esac
    CANDIDATE_VERSION="${info%%|*}"
    info="${info#*|}"
    CANDIDATE_SCORE="${info%%|*}"
    CANDIDATE_CANONICAL="${info#*|}"
    [ -n "$CANDIDATE_VERSION" ] && [ -n "$CANDIDATE_SCORE" ] && [ -n "$CANDIDATE_CANONICAL" ]
}

bootstrap_environment_identity() {
    # A path named bin/python is not enough: it may be a stale symlink to a
    # system or version-manager interpreter. Require Python itself to report
    # the selected environment as sys.prefix and to identify it as a venv.
    local python_path="$1"
    local expected_prefix="$2"
    "$python_path" -c '
import os
import sys

expected = os.path.realpath(sys.argv[1])
prefix = os.path.realpath(sys.prefix)
base_prefix = os.path.realpath(getattr(sys, "base_prefix", sys.prefix))
is_virtualenv = prefix != base_prefix or hasattr(sys, "real_prefix")
raise SystemExit(0 if is_virtualenv and prefix == expected else 1)
' "$expected_prefix" >/dev/null 2>&1
}

bootstrap_managed_python_info() {
    local source="$1"
    local info=""
    local log="${BOOTSTRAP_TMP_ROOT}/${source}-environment.log"
    local python_code='import sys; print(f"{sys.executable}|{sys.prefix}")'

    case "$source" in
        uv)
            info="$(uv run --no-sync python -c "$python_code" 2>"$log")" || return 1
            ;;
        poetry)
            info="$(poetry run python -c "$python_code" 2>"$log")" || return 1
            ;;
        *) return 1 ;;
    esac
    case "$info" in
        *'|'*) : ;;
        *) return 1 ;;
    esac
    BOOTSTRAP_PYTHON="${info%%|*}"
    BOOTSTRAP_VENV="${info#*|}"
    [ -x "$BOOTSTRAP_PYTHON" ] && [ -d "$BOOTSTRAP_VENV" ] || return 1
    bootstrap_environment_identity "$BOOTSTRAP_PYTHON" "$BOOTSTRAP_VENV"
}

bootstrap_find_managed_environment() {
    local has_uv_project="no"
    local has_poetry_project="no"

    MANAGED_RESULT="none"
    MANAGED_SOURCE=""
    if [ -f "${BOOTSTRAP_CWD}/uv.lock" ] || [ -f "${BOOTSTRAP_CWD}/uv.toml" ] \
        || [ -n "${UV_PROJECT_ENVIRONMENT:-}" ] \
        || { [ -f "${BOOTSTRAP_CWD}/pyproject.toml" ] \
            && grep -Eq '^[[:space:]]*\[tool\.uv([][.[:space:]])' "${BOOTSTRAP_CWD}/pyproject.toml"; }; then
        has_uv_project="yes"
    fi
    if [ -f "${BOOTSTRAP_CWD}/poetry.lock" ] \
        || { [ -f "${BOOTSTRAP_CWD}/pyproject.toml" ] \
            && grep -Eq '^[[:space:]]*\[tool\.poetry([][.[:space:]])' "${BOOTSTRAP_CWD}/pyproject.toml"; }; then
        has_poetry_project="yes"
    fi

    if [ "$has_uv_project" = "yes" ]; then
        MANAGED_SOURCE="uv"
    elif [ "$has_poetry_project" = "yes" ]; then
        MANAGED_SOURCE="poetry"
    else
        return 0
    fi

    if ! command -v "$MANAGED_SOURCE" >/dev/null 2>&1; then
        MANAGED_RESULT="unavailable"
        return 0
    fi
    if bootstrap_managed_python_info "$MANAGED_SOURCE"; then
        MANAGED_RESULT="found"
    else
        MANAGED_RESULT="invalid"
    fi
}

bootstrap_sdk_version() {
    "$1" -c 'import importlib.metadata, datalens_sdk; print(importlib.metadata.version("datalens-sdk"))' 2>/dev/null
}

bootstrap_compare_versions() {
    # Set VERSION_RELATION to the second version's relation to the first.
    # The disposable query environment's vendored packaging implementation
    # gives us canonical PEP 440 ordering without changing the project.
    local first="$1"
    local second="$2"
    VERSION_RELATION=""
    [ -x "$PROBE_PYTHON" ] || return 1
    VERSION_RELATION="$(
        "$PROBE_PYTHON" -c '
import sys
from pip._vendor.packaging.version import InvalidVersion, Version

try:
    first = Version(sys.argv[1])
    second = Version(sys.argv[2])
except InvalidVersion:
    raise SystemExit(1)
print("newer" if second > first else "older" if second < first else "equal")
' "$first" "$second" 2>/dev/null
    )" || return 1
    case "$VERSION_RELATION" in
        newer|equal|older) return 0 ;;
        *) return 1 ;;
    esac
}

bootstrap_extract_requirements() {
    # Modern pip emits one or more "Requires-Python <specifier>" fragments.
    # Keep only PEP 440 comparison tokens; never echo arbitrary pip output or URLs.
    awk '
    {
        rest = $0
        while (match(rest, /Requires-Python[[:space:]]+[<>=!~][<>=!~0-9A-Za-z.*+_,[:space:]-]*/)) {
            value = substr(rest, RSTART, RLENGTH)
            sub(/^Requires-Python[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            gsub(/[[:space:]]*,[[:space:]]*/, ",", value)
            if (value != "") print value
            rest = substr(rest, RSTART + RLENGTH)
        }
    }
    ' "$1" | sort -u | paste -sd '|' -
}

bootstrap_merge_requirements() {
    local incoming="$1"
    local merged=""
    [ -n "$incoming" ] || return 0
    if [ -z "$BOOTSTRAP_REQUIRES_PYTHON" ]; then
        BOOTSTRAP_REQUIRES_PYTHON="$incoming"
        return 0
    fi
    merged="$(printf '%s\n' "$BOOTSTRAP_REQUIRES_PYTHON" "$incoming" | tr '|' '\n' | sort -u | paste -sd '|' -)"
    BOOTSTRAP_REQUIRES_PYTHON="$merged"
}

bootstrap_probe() {
    local base_python="$1"
    local probe_dir=""
    local probe_python=""
    local query_log=""

    PROBE_RESULT=""
    PROBE_PYTHON=""
    PROBE_SDK_VERSION=""
    PROBE_REQUIREMENTS=""
    PROBE_REASON=""

    probe_dir="$(mktemp -d "${BOOTSTRAP_TMP_ROOT}/probe.XXXXXX")" || {
        PROBE_RESULT="failed"
        PROBE_REASON="venv_create_failed"
        return 0
    }
    if ! "$base_python" -m venv "${probe_dir}/venv" >/dev/null 2>&1; then
        PROBE_RESULT="failed"
        PROBE_REASON="venv_create_failed"
        return 0
    fi
    probe_python="${probe_dir}/venv/bin/python"
    [ -x "$probe_python" ] || probe_python="${probe_dir}/venv/bin/python3"
    if [ ! -x "$probe_python" ]; then
        PROBE_RESULT="failed"
        PROBE_REASON="venv_create_failed"
        return 0
    fi
    PROBE_PYTHON="$probe_python"
    if ! bootstrap_environment_identity "$PROBE_PYTHON" "${probe_dir}/venv"; then
        PROBE_RESULT="failed"
        PROBE_REASON="probe_venv_invalid"
        return 0
    fi

    query_log="${probe_dir}/sdk-index.log"
    if "$probe_python" -m pip index versions datalens-sdk \
        --disable-pip-version-check --no-input --no-color -v >"$query_log" 2>&1; then
        PROBE_SDK_VERSION="$(awk '
            /^datalens-sdk \([^()]+\)$/ {
                value = $0
                sub(/^datalens-sdk \(/, "", value)
                sub(/\)$/, "", value)
                if (value ~ /^[0-9A-Za-z][0-9A-Za-z.!+_-]*$/) {
                    print value
                    exit
                }
            }
        ' "$query_log")"
        if [ -z "$PROBE_SDK_VERSION" ]; then
            PROBE_RESULT="failed"
            PROBE_REASON="package_index_query_failed"
            return 0
        fi
        PROBE_RESULT="compatible"
        return 0
    fi

    PROBE_REQUIREMENTS="$(bootstrap_extract_requirements "$query_log")"
    if [ -n "$PROBE_REQUIREMENTS" ]; then
        PROBE_RESULT="incompatible"
        PROBE_REASON="python_incompatible"
    else
        PROBE_RESULT="failed"
        PROBE_REASON="package_index_query_failed"
    fi
}

bootstrap_add_candidate() {
    local python_path="$1"
    local source="$2"
    local seen_file="$3"
    local candidates_file="$4"
    [ -x "$python_path" ] || return 0
    bootstrap_python_info "$python_path" || return 0
    grep -Fqx "$CANDIDATE_CANONICAL" "$seen_file" 2>/dev/null && return 0
    printf '%s\n' "$CANDIDATE_CANONICAL" >>"$seen_file"
    printf '%s|%s|%s|%s\n' "$CANDIDATE_SCORE" "$CANDIDATE_VERSION" "$source" "$CANDIDATE_CANONICAL" >>"$candidates_file"
}

bootstrap_collect_candidates() {
    local excluded="$1"
    local seen_file="${BOOTSTRAP_TMP_ROOT}/seen-candidates"
    local candidates_file="${BOOTSTRAP_TMP_ROOT}/candidates"
    local path_dir=""
    local python_path=""
    local pyenv_version=""
    local pyenv_prefix=""
    local old_ifs="$IFS"

    : >"$seen_file"
    : >"$candidates_file"
    [ -n "$excluded" ] && printf '%s\n' "$excluded" >"$seen_file"

    IFS=':'
    for path_dir in $PATH; do
        [ -n "$path_dir" ] || path_dir='.'
        # Include every unversioned python3 on PATH as well as versioned names.
        # `command -v python3` sees only the first entry, which may be a broken
        # version-manager shim hiding a working interpreter later on PATH.
        for python_path in "$path_dir"/python3 "$path_dir"/python3.*; do
            bootstrap_add_candidate "$python_path" "path" "$seen_file" "$candidates_file"
        done
    done
    IFS="$old_ifs"

    if command -v pyenv >/dev/null 2>&1; then
        while IFS= read -r pyenv_version; do
            case "$pyenv_version" in
                [0-9]*.[0-9]*|[0-9]*.[0-9]*.[0-9]*) : ;;
                *) continue ;;
            esac
            pyenv_prefix="$(pyenv prefix "$pyenv_version" 2>/dev/null)" || continue
            bootstrap_add_candidate "${pyenv_prefix}/bin/python" "pyenv" "$seen_file" "$candidates_file"
        done < <(pyenv versions --bare 2>/dev/null)
    fi

    sort -t '|' -k1,1nr "$candidates_file"
}

bootstrap_find_compatible_alternative() {
    local excluded="$1"
    local candidate_line=""
    local score=""
    local version=""
    local source=""
    local path=""
    local candidates_sorted="${BOOTSTRAP_TMP_ROOT}/candidates-sorted"

    bootstrap_collect_candidates "$excluded" >"$candidates_sorted"
    while IFS='|' read -r score version source path; do
        [ -n "$path" ] || continue
        bootstrap_note "Probing Python ${version} from ${source} for datalens-sdk compatibility..."
        bootstrap_probe "$path"
        bootstrap_merge_requirements "$PROBE_REQUIREMENTS"
        case "$PROBE_RESULT" in
            compatible)
                CANDIDATE_PATH="$path"
                CANDIDATE_VERSION="$version"
                CANDIDATE_SOURCE="$source"
                CANDIDATE_CANONICAL="$path"
                return 0
                ;;
            incompatible) : ;;
            failed)
                BOOTSTRAP_REASON="$PROBE_REASON"
                return 2
                ;;
        esac
    done <"$candidates_sorted"
    return 1
}

bootstrap_install_project() {
    local project_python="$1"
    local target_version="${2:-}"
    local install_log="${BOOTSTRAP_TMP_ROOT}/project-install.log"
    local requirement="datalens-sdk==${target_version}"
    local action="Installing"
    [ "$BOOTSTRAP_ACTION" = "upgrade" ] && action="Upgrading"
    [ -n "$target_version" ] || return 1
    if ! bootstrap_environment_identity "$project_python" "$BOOTSTRAP_VENV"; then
        BOOTSTRAP_REASON="venv_invalid"
        return 2
    fi
    bootstrap_note "${action} datalens-sdk into ${BOOTSTRAP_VENV}..."
    case "$MANAGED_SOURCE" in
        uv)
            uv add "$requirement" >"$install_log" 2>&1 || return 1
            bootstrap_managed_python_info uv || return 1
            project_python="$BOOTSTRAP_PYTHON"
            ;;
        poetry)
            poetry add "$requirement" >"$install_log" 2>&1 || return 1
            bootstrap_managed_python_info poetry || return 1
            project_python="$BOOTSTRAP_PYTHON"
            ;;
        "")
            "$project_python" -m pip install --disable-pip-version-check --no-input --upgrade "$requirement" >"$install_log" 2>&1 || {
                bootstrap_merge_requirements "$(bootstrap_extract_requirements "$install_log")"
                return 1
            }
            ;;
        *) return 1 ;;
    esac
    BOOTSTRAP_SDK_VERSION="$(bootstrap_sdk_version "$project_python")"
    [ "$BOOTSTRAP_SDK_VERSION" = "$target_version" ] && return 0
    bootstrap_merge_requirements "$(bootstrap_extract_requirements "$install_log")"
    return 1
}

bootstrap_emit_version_decision() {
    BOOTSTRAP_VENV_STATE="reused"
    BOOTSTRAP_SDK="installed"
    BOOTSTRAP_REASON="$1"
    BOOTSTRAP_STATUS="decision_required"
    bootstrap_emit
}

bootstrap_emit_install_decision() {
    BOOTSTRAP_VENV_STATE="reused"
    BOOTSTRAP_SDK="missing"
    BOOTSTRAP_REASON="$1"
    BOOTSTRAP_STATUS="decision_required"
    bootstrap_emit
}

case "$#" in
    0) : ;;
    2)
        case "$1" in
            --install-sdk) BOOTSTRAP_ACTION="install" ;;
            --upgrade-sdk) BOOTSTRAP_ACTION="upgrade" ;;
            *)
                BOOTSTRAP_REASON="invalid_arguments"
                bootstrap_emit
                exit 0
                ;;
        esac
        [ -n "$2" ] || {
            BOOTSTRAP_REASON="invalid_arguments"
            bootstrap_emit
            exit 0
        }
        BOOTSTRAP_EXPECTED_SDK_VERSION="$2"
        ;;
    *)
        BOOTSTRAP_REASON="invalid_arguments"
        bootstrap_emit
        exit 0
        ;;
esac

BOOTSTRAP_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/datalens-sdk-bootstrap.XXXXXX")" || {
    BOOTSTRAP_REASON="venv_create_failed"
    bootstrap_emit
    exit 0
}

bootstrap_find_managed_environment
case "$MANAGED_RESULT" in
    found)
        BOOTSTRAP_PYTHON_SOURCE="$MANAGED_SOURCE"
        ;;
    unavailable)
        BOOTSTRAP_PYTHON_SOURCE="$MANAGED_SOURCE"
        BOOTSTRAP_REASON="managed_environment_unavailable"
        bootstrap_emit
        exit 0
        ;;
    invalid)
        BOOTSTRAP_PYTHON_SOURCE="$MANAGED_SOURCE"
        BOOTSTRAP_REASON="managed_environment_invalid"
        bootstrap_emit
        exit 0
        ;;
esac

# Reuse a valid project environment only after checking whether the configured
# package index offers a newer stable release compatible with its interpreter.
if [ -d "$BOOTSTRAP_VENV" ]; then
    if [ -z "$BOOTSTRAP_PYTHON" ]; then
        if [ -x "${BOOTSTRAP_VENV}/bin/python" ]; then
            BOOTSTRAP_PYTHON="${BOOTSTRAP_VENV}/bin/python"
        elif [ -x "${BOOTSTRAP_VENV}/bin/python3" ]; then
            BOOTSTRAP_PYTHON="${BOOTSTRAP_VENV}/bin/python3"
        else
            BOOTSTRAP_VENV_STATE="failed"
            BOOTSTRAP_REASON="venv_invalid"
            bootstrap_emit
            exit 0
        fi
    fi
    if ! bootstrap_environment_identity "$BOOTSTRAP_PYTHON" "$BOOTSTRAP_VENV"; then
        BOOTSTRAP_VENV_STATE="failed"
        BOOTSTRAP_REASON="venv_invalid"
        bootstrap_emit
        exit 0
    fi
    if ! bootstrap_python_info "$BOOTSTRAP_PYTHON"; then
        BOOTSTRAP_VENV_STATE="failed"
        BOOTSTRAP_REASON="venv_invalid"
        bootstrap_emit
        exit 0
    fi
    BOOTSTRAP_PYTHON_VERSION="$CANDIDATE_VERSION"
    [ -n "$BOOTSTRAP_PYTHON_SOURCE" ] || BOOTSTRAP_PYTHON_SOURCE="venv"
    BOOTSTRAP_SDK_VERSION="$(bootstrap_sdk_version "$BOOTSTRAP_PYTHON")"
    if [ -n "$BOOTSTRAP_SDK_VERSION" ]; then
        BOOTSTRAP_VENV_STATE="reused"
        BOOTSTRAP_SDK="installed"
        bootstrap_note "Checking the installed datalens-sdk ${BOOTSTRAP_SDK_VERSION} for a newer compatible release..."
        bootstrap_probe "$BOOTSTRAP_PYTHON"
        bootstrap_merge_requirements "$PROBE_REQUIREMENTS"
        if [ "$PROBE_RESULT" != "compatible" ] || [ -z "$PROBE_SDK_VERSION" ]; then
            BOOTSTRAP_AVAILABLE_SDK_VERSION=""
            bootstrap_emit_version_decision "sdk_version_check_failed"
            exit 0
        fi

        BOOTSTRAP_AVAILABLE_SDK_VERSION="$PROBE_SDK_VERSION"
        if ! bootstrap_compare_versions "$BOOTSTRAP_SDK_VERSION" "$BOOTSTRAP_AVAILABLE_SDK_VERSION"; then
            bootstrap_emit_version_decision "sdk_version_check_failed"
            exit 0
        fi
        INSTALLED_AVAILABLE_RELATION="$VERSION_RELATION"

        if [ "$BOOTSTRAP_ACTION" = "install" ]; then
            BOOTSTRAP_REASON="install_requires_missing_sdk"
            bootstrap_emit
            exit 0
        fi

        if [ "$BOOTSTRAP_ACTION" = "upgrade" ]; then
            if ! bootstrap_compare_versions "$BOOTSTRAP_EXPECTED_SDK_VERSION" "$BOOTSTRAP_AVAILABLE_SDK_VERSION"; then
                bootstrap_emit_version_decision "sdk_version_check_failed"
                exit 0
            fi
            if [ "$VERSION_RELATION" != "equal" ]; then
                if [ "$INSTALLED_AVAILABLE_RELATION" = "newer" ]; then
                    bootstrap_emit_version_decision "sdk_update_available"
                else
                    bootstrap_emit_version_decision "sdk_upgrade_target_unavailable"
                fi
                exit 0
            fi
        fi

        case "$INSTALLED_AVAILABLE_RELATION" in
            equal|older)
                BOOTSTRAP_STATUS="ready"
                bootstrap_emit
                exit 0
                ;;
            newer)
                if [ "$BOOTSTRAP_ACTION" = "check" ]; then
                    bootstrap_emit_version_decision "sdk_update_available"
                    exit 0
                fi
                if bootstrap_install_project "$BOOTSTRAP_PYTHON" "$BOOTSTRAP_AVAILABLE_SDK_VERSION" \
                    && bootstrap_compare_versions "$BOOTSTRAP_AVAILABLE_SDK_VERSION" "$BOOTSTRAP_SDK_VERSION" \
                    && [ "$VERSION_RELATION" = "equal" ]; then
                    BOOTSTRAP_SDK="upgraded"
                    BOOTSTRAP_REASON=""
                    BOOTSTRAP_STATUS="ready"
                    bootstrap_emit
                    exit 0
                fi

                if [ "$BOOTSTRAP_REASON" = "venv_invalid" ]; then
                    BOOTSTRAP_VENV_STATE="failed"
                    BOOTSTRAP_SDK="missing"
                    BOOTSTRAP_STATUS="blocked"
                    bootstrap_emit
                    exit 0
                fi

                BOOTSTRAP_SDK_VERSION="$(bootstrap_sdk_version "$BOOTSTRAP_PYTHON")"
                if [ -n "$BOOTSTRAP_SDK_VERSION" ]; then
                    bootstrap_emit_version_decision "sdk_upgrade_failed"
                else
                    BOOTSTRAP_SDK="missing"
                    BOOTSTRAP_VENV_STATE="failed"
                    BOOTSTRAP_REASON="sdk_upgrade_failed"
                    BOOTSTRAP_STATUS="blocked"
                    bootstrap_emit
                fi
                exit 0
                ;;
        esac
    fi

    if [ "$BOOTSTRAP_ACTION" = "upgrade" ]; then
        BOOTSTRAP_REASON="upgrade_requires_installed_sdk"
        bootstrap_emit
        exit 0
    fi

    bootstrap_note "Probing the existing .venv interpreter for datalens-sdk compatibility..."
    bootstrap_probe "$BOOTSTRAP_PYTHON"
    bootstrap_merge_requirements "$PROBE_REQUIREMENTS"
    case "$PROBE_RESULT" in
        compatible)
            BOOTSTRAP_AVAILABLE_SDK_VERSION="$PROBE_SDK_VERSION"
            if [ -n "$MANAGED_SOURCE" ]; then
                if [ "$BOOTSTRAP_ACTION" = "upgrade" ]; then
                    BOOTSTRAP_REASON="upgrade_requires_installed_sdk"
                    bootstrap_emit
                    exit 0
                fi
                if [ "$BOOTSTRAP_ACTION" = "check" ]; then
                    bootstrap_emit_install_decision "sdk_install_required"
                    exit 0
                fi
                if ! bootstrap_compare_versions "$BOOTSTRAP_EXPECTED_SDK_VERSION" "$BOOTSTRAP_AVAILABLE_SDK_VERSION"; then
                    bootstrap_emit_install_decision "sdk_version_check_failed"
                    exit 0
                fi
                if [ "$VERSION_RELATION" != "equal" ]; then
                    bootstrap_emit_install_decision "sdk_install_target_changed"
                    exit 0
                fi
            elif [ "$BOOTSTRAP_ACTION" = "install" ]; then
                BOOTSTRAP_REASON="install_requires_managed_environment"
                bootstrap_emit
                exit 0
            fi
            if bootstrap_install_project "$BOOTSTRAP_PYTHON" "$BOOTSTRAP_AVAILABLE_SDK_VERSION"; then
                BOOTSTRAP_VENV_STATE="reused"
                BOOTSTRAP_SDK="installed_now"
                BOOTSTRAP_STATUS="ready"
            else
                if [ -n "$MANAGED_SOURCE" ]; then
                    BOOTSTRAP_VENV_STATE="reused"
                    BOOTSTRAP_SDK="missing"
                    [ -n "$BOOTSTRAP_REASON" ] || BOOTSTRAP_REASON="sdk_install_failed"
                else
                    BOOTSTRAP_VENV_STATE="failed"
                    [ -n "$BOOTSTRAP_REASON" ] || BOOTSTRAP_REASON="package_install_failed"
                fi
            fi
            bootstrap_emit
            exit 0
            ;;
        failed)
            BOOTSTRAP_VENV_STATE="failed"
            BOOTSTRAP_REASON="$PROBE_REASON"
            bootstrap_emit
            exit 0
            ;;
        incompatible)
            if [ -n "$MANAGED_SOURCE" ]; then
                BOOTSTRAP_VENV_STATE="incompatible"
                BOOTSTRAP_REASON="managed_python_incompatible"
                bootstrap_emit
                exit 0
            fi
            if bootstrap_find_compatible_alternative "$CANDIDATE_CANONICAL"; then
                BOOTSTRAP_VENV_STATE="incompatible"
                BOOTSTRAP_AVAILABLE_PYTHON="$CANDIDATE_PATH"
                BOOTSTRAP_AVAILABLE_VERSION="$CANDIDATE_VERSION"
                BOOTSTRAP_REASON="venv_python_incompatible"
            else
                BOOTSTRAP_VENV_STATE="incompatible"
                [ -n "$BOOTSTRAP_REASON" ] || BOOTSTRAP_REASON="no_compatible_python"
            fi
            bootstrap_emit
            exit 0
            ;;
    esac
fi

if [ "$BOOTSTRAP_ACTION" != "check" ]; then
    if [ "$BOOTSTRAP_ACTION" = "upgrade" ]; then
        BOOTSTRAP_REASON="upgrade_requires_installed_sdk"
    else
        BOOTSTRAP_REASON="install_requires_managed_environment"
    fi
    bootstrap_emit
    exit 0
fi

# No project venv: try the default interpreter first, then dynamically
# discovered PATH and pyenv candidates only after a Python incompatibility.
DEFAULT_PYTHON="$(command -v python3 2>/dev/null || true)"
DEFAULT_CANONICAL=""
if [ -n "$DEFAULT_PYTHON" ] && bootstrap_python_info "$DEFAULT_PYTHON"; then
    DEFAULT_CANONICAL="$CANDIDATE_CANONICAL"
    bootstrap_note "Probing default Python ${CANDIDATE_VERSION} for datalens-sdk compatibility..."
    bootstrap_probe "$DEFAULT_PYTHON"
    bootstrap_merge_requirements "$PROBE_REQUIREMENTS"
    case "$PROBE_RESULT" in
        compatible)
            CANDIDATE_PATH="$DEFAULT_CANONICAL"
            CANDIDATE_SOURCE="default"
            ;;
        failed)
            BOOTSTRAP_REASON="$PROBE_REASON"
            bootstrap_emit
            exit 0
            ;;
        incompatible)
            CANDIDATE_PATH=""
            ;;
    esac
else
    CANDIDATE_PATH=""
fi

if [ -z "$CANDIDATE_PATH" ]; then
    if ! bootstrap_find_compatible_alternative "$DEFAULT_CANONICAL"; then
        [ -n "$BOOTSTRAP_REASON" ] || BOOTSTRAP_REASON="no_compatible_python"
        bootstrap_emit
        exit 0
    fi
fi

BOOTSTRAP_PYTHON_VERSION="$CANDIDATE_VERSION"
BOOTSTRAP_PYTHON_SOURCE="$CANDIDATE_SOURCE"
BOOTSTRAP_AVAILABLE_SDK_VERSION="$PROBE_SDK_VERSION"
bootstrap_note "Creating project .venv with Python ${CANDIDATE_VERSION}..."
if ! "$CANDIDATE_PATH" -m venv "$BOOTSTRAP_VENV" >/dev/null 2>&1; then
    [ ! -d "$BOOTSTRAP_VENV" ] || rm -rf -- "$BOOTSTRAP_VENV"
    BOOTSTRAP_VENV_STATE="failed"
    BOOTSTRAP_REASON="venv_create_failed"
    bootstrap_emit
    exit 0
fi
BOOTSTRAP_PYTHON="${BOOTSTRAP_VENV}/bin/python"
[ -x "$BOOTSTRAP_PYTHON" ] || BOOTSTRAP_PYTHON="${BOOTSTRAP_VENV}/bin/python3"
PROJECT_INSTALL_REASON=""
if [ ! -x "$BOOTSTRAP_PYTHON" ]; then
    PROJECT_INSTALL_REASON="venv_invalid"
elif ! bootstrap_environment_identity "$BOOTSTRAP_PYTHON" "$BOOTSTRAP_VENV"; then
    PROJECT_INSTALL_REASON="venv_invalid"
elif ! bootstrap_install_project "$BOOTSTRAP_PYTHON" "$BOOTSTRAP_AVAILABLE_SDK_VERSION"; then
    PROJECT_INSTALL_REASON="${BOOTSTRAP_REASON:-package_install_failed}"
fi
if [ -n "$PROJECT_INSTALL_REASON" ]; then
    rm -rf -- "$BOOTSTRAP_VENV"
    BOOTSTRAP_PYTHON=""
    BOOTSTRAP_VENV_STATE="failed"
    BOOTSTRAP_REASON="$PROJECT_INSTALL_REASON"
    bootstrap_emit
    exit 0
fi

BOOTSTRAP_VENV_STATE="created"
BOOTSTRAP_SDK="installed_now"
BOOTSTRAP_STATUS="ready"
bootstrap_emit
exit 0
