#!/usr/bin/env bash
# Bootstrap an SDK package without encoding package or Python compatibility versions.
#
# Run from the user's project directory. The script:
#   * prefers a uv/Poetry-managed environment over a same-named ./.venv;
#   * verifies environment identity before every project-environment mutation;
#   * resolves freshness through the selected pip, uv, or Poetry source policy;
#   * asks its caller to obtain consent before installing managed dependencies;
#   * changes interpreter only after pip reports Requires-Python incompatibility;
#   * creates ./.venv only after a compatible interpreter has been proven.
#
# Machine-readable output follows the ---BOOTSTRAP--- marker. The script always
# exits zero; callers must act on STATUS. Pass --install-sdk only after the
# user approves a manager-selected install, or --upgrade-sdk VERSION only
# after the user approves the exact version reported by a prior run.
#
# Thin wrapper skills may reuse this engine by setting all three variables:
#   DATALENS_BOOTSTRAP_DISTRIBUTION  Python distribution name
#   DATALENS_BOOTSTRAP_IMPORT_MODULE import module used for the health check
#   DATALENS_BOOTSTRAP_CHANGELOG_URL optional HTTPS changelog URL (or empty)
#   DATALENS_BOOTSTRAP_POETRY_SOURCE optional project-local Poetry package source
# Invalid profiles are blocked before any project inspection or mutation.

set -uo pipefail

BOOTSTRAP_DISTRIBUTION=""
BOOTSTRAP_IMPORT_MODULE=""
BOOTSTRAP_CHANGELOG_URL=""
BOOTSTRAP_POETRY_SOURCE=""
BOOTSTRAP_DISTRIBUTION_PATTERN=""
BOOTSTRAP_TMP_PREFIX=""

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
BOOTSTRAP_REQUIRES_PYTHON=""
BOOTSTRAP_PROJECT_REQUIRES_PYTHON=""
BOOTSTRAP_CONFIGURED_PYTHON=""
BOOTSTRAP_CONFIGURED_MATCH_SEEN="no"
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
PROBE_RUNTIME_BASE=""
PROBE_RUNTIME_PYTHON=""
PROBE_RUNTIME_MODE=""
PROBE_SITE_CONFIG=""
VERSION_RELATION=""
INSTALLED_AVAILABLE_RELATION=""
MANAGED_RESULT="none"
MANAGED_SOURCE=""
MANAGED_OWNERSHIP_RESULT=""
PROJECT_PYTHON_RESULT="compatible"
PROJECT_PYTHON_REQUIREMENT=""

CANDIDATE_PATH=""
CANDIDATE_VERSION=""
CANDIDATE_SCORE=""
CANDIDATE_SOURCE=""
CANDIDATE_CANONICAL=""

bootstrap_note() {
    printf '%s\n' "$*" >&2
}

bootstrap_validate_profile() {
    local distribution_set="${DATALENS_BOOTSTRAP_DISTRIBUTION+yes}"
    local import_module_set="${DATALENS_BOOTSTRAP_IMPORT_MODULE+yes}"
    local changelog_url_set="${DATALENS_BOOTSTRAP_CHANGELOG_URL+yes}"
    local poetry_source_set="${DATALENS_BOOTSTRAP_POETRY_SOURCE+yes}"

    if [ -z "$distribution_set" ] && [ -z "$import_module_set" ] && [ -z "$changelog_url_set" ]; then
        [ -z "$poetry_source_set" ] || return 1
        BOOTSTRAP_DISTRIBUTION="datalens-sdk"
        BOOTSTRAP_IMPORT_MODULE="datalens_sdk"
        BOOTSTRAP_CHANGELOG_URL="https://github.com/datalens-tech/datalens-sdk/blob/main/CHANGELOG.md"
    elif [ -n "$distribution_set" ] && [ -n "$import_module_set" ] && [ -n "$changelog_url_set" ]; then
        BOOTSTRAP_DISTRIBUTION="$DATALENS_BOOTSTRAP_DISTRIBUTION"
        BOOTSTRAP_IMPORT_MODULE="$DATALENS_BOOTSTRAP_IMPORT_MODULE"
        BOOTSTRAP_CHANGELOG_URL="$DATALENS_BOOTSTRAP_CHANGELOG_URL"
        [ -z "$poetry_source_set" ] || BOOTSTRAP_POETRY_SOURCE="$DATALENS_BOOTSTRAP_POETRY_SOURCE"
    else
        return 1
    fi

    case "$BOOTSTRAP_DISTRIBUTION" in
        ""|*[!A-Za-z0-9._-]*|[-_.]*) return 1 ;;
    esac
    if ! printf '%s\n' "$BOOTSTRAP_IMPORT_MODULE" \
        | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$'; then
        return 1
    fi
    case "$BOOTSTRAP_CHANGELOG_URL" in
        ""|https://*) : ;;
        *) return 1 ;;
    esac
    case "$BOOTSTRAP_POETRY_SOURCE" in
        "") : ;;
        *[!A-Za-z0-9._-]*|[-_.]*) return 1 ;;
    esac
    BOOTSTRAP_DISTRIBUTION_PATTERN="$(awk -v distribution="$BOOTSTRAP_DISTRIBUTION" \
        'BEGIN { gsub(/[-_.]/, "[-_.]", distribution); print distribution }')"
    BOOTSTRAP_TMP_PREFIX="$BOOTSTRAP_DISTRIBUTION"
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
    [ -n "$BOOTSTRAP_PROJECT_REQUIRES_PYTHON" ] && echo "PROJECT_REQUIRES_PYTHON=$BOOTSTRAP_PROJECT_REQUIRES_PYTHON"
    [ -n "$BOOTSTRAP_CONFIGURED_PYTHON" ] && echo "CONFIGURED_PYTHON=$BOOTSTRAP_CONFIGURED_PYTHON"
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

bootstrap_probe_runtime_available() {
    "$1" -c '
import pip
from pip._vendor.packaging.specifiers import SpecifierSet
from pip._vendor.packaging.version import Version
' >/dev/null 2>&1
}

bootstrap_copy_site_policy() {
    local target_prefix="$1"
    [ -n "$PROBE_SITE_CONFIG" ] || return 0
    [ -f "$PROBE_SITE_CONFIG" ] || return 0
    [ "$PROBE_SITE_CONFIG" = "${target_prefix}/pip.conf" ] && return 0
    cp "$PROBE_SITE_CONFIG" "${target_prefix}/pip.conf"
}

bootstrap_select_probe_python() {
    local base_python="$1"
    local probe_mode="${2:-auto}"
    local base_prefix=""
    local probe_dir=""
    local probe_python=""

    if [ "$PROBE_RUNTIME_BASE" = "$base_python" ] \
        && [ "$PROBE_RUNTIME_MODE" = "$probe_mode" ] \
        && [ -x "$PROBE_RUNTIME_PYTHON" ]; then
        PROBE_PYTHON="$PROBE_RUNTIME_PYTHON"
        return 0
    fi

    PROBE_RUNTIME_BASE=""
    PROBE_RUNTIME_PYTHON=""
    PROBE_RUNTIME_MODE=""
    PROBE_SITE_CONFIG=""
    base_prefix="$("$base_python" -c 'import os, sys; print(os.path.realpath(sys.prefix))' 2>/dev/null)" || {
        PROBE_REASON="package_index_query_failed"
        return 1
    }
    [ -n "$base_prefix" ] || {
        PROBE_REASON="package_index_query_failed"
        return 1
    }
    [ ! -f "${base_prefix}/pip.conf" ] || PROBE_SITE_CONFIG="${base_prefix}/pip.conf"

    if [ "$probe_mode" != "isolated" ] && bootstrap_probe_runtime_available "$base_python"; then
        PROBE_RUNTIME_BASE="$base_python"
        PROBE_RUNTIME_PYTHON="$base_python"
        PROBE_RUNTIME_MODE="$probe_mode"
        PROBE_PYTHON="$base_python"
        return 0
    fi

    probe_dir="$(mktemp -d "${BOOTSTRAP_TMP_ROOT}/probe.XXXXXX")" || {
        PROBE_REASON="venv_create_failed"
        return 1
    }
    if ! "$base_python" -m venv "${probe_dir}/venv" >/dev/null 2>&1; then
        PROBE_REASON="venv_create_failed"
        return 1
    fi
    probe_python="${probe_dir}/venv/bin/python"
    [ -x "$probe_python" ] || probe_python="${probe_dir}/venv/bin/python3"
    if [ ! -x "$probe_python" ] \
        || ! bootstrap_environment_identity "$probe_python" "${probe_dir}/venv" \
        || ! bootstrap_copy_site_policy "${probe_dir}/venv" \
        || ! bootstrap_probe_runtime_available "$probe_python"; then
        PROBE_REASON="probe_venv_invalid"
        return 1
    fi

    PROBE_RUNTIME_BASE="$base_python"
    PROBE_RUNTIME_PYTHON="$probe_python"
    PROBE_RUNTIME_MODE="$probe_mode"
    PROBE_PYTHON="$probe_python"
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
    info="$(printf '%s\n' "$info" | awk '/[|]/{value=$0} END {print value}')"
    case "$info" in
        *'|'*) : ;;
        *) return 1 ;;
    esac
    BOOTSTRAP_PYTHON="${info%%|*}"
    BOOTSTRAP_VENV="${info#*|}"
    [ -x "$BOOTSTRAP_PYTHON" ] && [ -d "$BOOTSTRAP_VENV" ] || return 1
    bootstrap_environment_identity "$BOOTSTRAP_PYTHON" "$BOOTSTRAP_VENV"
}

bootstrap_has_uv_marker() {
    grep -Eq '^[[:space:]]*(\[\[tool\.uv(\.[^]]+)?\]\]|\[tool\.uv(\.[^]]+)?\])[[:space:]]*(#.*)?$' "$1"
}

bootstrap_has_poetry_marker() {
    grep -Eq '^[[:space:]]*(\[\[tool\.poetry(\.[^]]+)?\]\]|\[tool\.poetry(\.[^]]+)?\])[[:space:]]*(#.*)?$' "$1"
}

bootstrap_select_manager() {
    local has_uv_project="no"
    local has_poetry_project="no"

    MANAGED_SOURCE=""
    if [ -f "${BOOTSTRAP_CWD}/uv.lock" ] || [ -f "${BOOTSTRAP_CWD}/uv.toml" ] \
        || [ -n "${UV_PROJECT_ENVIRONMENT:-}" ] \
        || { [ -f "${BOOTSTRAP_CWD}/pyproject.toml" ] \
            && bootstrap_has_uv_marker "${BOOTSTRAP_CWD}/pyproject.toml"; }; then
        has_uv_project="yes"
    fi
    if [ -f "${BOOTSTRAP_CWD}/poetry.lock" ] \
        || { [ -f "${BOOTSTRAP_CWD}/pyproject.toml" ] \
            && bootstrap_has_poetry_marker "${BOOTSTRAP_CWD}/pyproject.toml"; }; then
        has_poetry_project="yes"
    fi

    if [ "$has_uv_project" = "yes" ]; then
        MANAGED_SOURCE="uv"
    elif [ "$has_poetry_project" = "yes" ]; then
        MANAGED_SOURCE="poetry"
    fi
}

bootstrap_find_managed_environment() {
    MANAGED_RESULT="none"
    bootstrap_select_manager
    [ -n "$MANAGED_SOURCE" ] || return 0

    if ! command -v "$MANAGED_SOURCE" >/dev/null 2>&1; then
        MANAGED_RESULT="unavailable"
        return 0
    fi
    if [ "$MANAGED_SOURCE" = "poetry" ] && [ -n "$BOOTSTRAP_POETRY_SOURCE" ]; then
        local source_log="${BOOTSTRAP_TMP_ROOT}/poetry-source.log"
        poetry source show --no-interaction --no-ansi "$BOOTSTRAP_POETRY_SOURCE" \
            >"$source_log" 2>&1 || true
        if ! awk -F: -v expected="$BOOTSTRAP_POETRY_SOURCE" '
            $1 ~ /^[[:space:]]*name[[:space:]]*$/ {
                value = $2
                sub(/^[[:space:]]*/, "", value)
                sub(/[[:space:]]*$/, "", value)
                if (value == expected) found = 1
            }
            END { exit(found ? 0 : 1) }
        ' "$source_log"; then
            MANAGED_RESULT="poetry_source_missing"
            return 0
        fi
    fi
    if bootstrap_managed_python_info "$MANAGED_SOURCE"; then
        MANAGED_RESULT="found"
    else
        MANAGED_RESULT="invalid"
    fi
}

bootstrap_load_configured_python() {
    local pin_file="${BOOTSTRAP_CWD}/.python-version"
    local request=""

    BOOTSTRAP_CONFIGURED_PYTHON=""
    [ -f "$pin_file" ] || return 0
    BOOTSTRAP_CONFIGURED_PYTHON="$(awk '
        {
            sub(/#.*/, "")
            for (i = 1; i <= NF; i++) print $i
        }
    ' "$pin_file" | paste -sd '|' -)"
    [ -n "$BOOTSTRAP_CONFIGURED_PYTHON" ] || return 1
    while IFS= read -r request; do
        printf '%s\n' "$request" | grep -Eq '^[0-9]+[.][0-9]+([.][0-9]+)?$' || return 1
    done < <(printf '%s\n' "$BOOTSTRAP_CONFIGURED_PYTHON" | tr '|' '\n')
}

bootstrap_matches_configured_python() {
    local version="$1"
    local request=""
    [ -n "$BOOTSTRAP_CONFIGURED_PYTHON" ] || return 0
    while IFS= read -r request; do
        case "$version" in
            "$request"|"$request".*) return 0 ;;
        esac
    done < <(printf '%s\n' "$BOOTSTRAP_CONFIGURED_PYTHON" | tr '|' '\n')
    return 1
}

bootstrap_project_python_compatibility() {
    local python_path="$1"
    local probe_mode="${2:-auto}"
    local info=""

    PROJECT_PYTHON_RESULT="compatible"
    PROJECT_PYTHON_REQUIREMENT=""
    [ -f "${BOOTSTRAP_CWD}/pyproject.toml" ] || return 0
    if ! bootstrap_select_probe_python "$python_path" "$probe_mode"; then
        PROJECT_PYTHON_RESULT="unreadable"
        return 0
    fi
    info="$("$PROBE_PYTHON" -c '
import pathlib
import sys

try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        try:
            from pip._vendor import tomli as tomllib
        except ImportError:
            try:
                from pip._vendor import toml as tomllib
            except ImportError:
                print("|unreadable")
                raise SystemExit

try:
    project = tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")).get("project", {})
    requirement = project.get("requires-python")
except Exception:
    print("|unreadable")
    raise SystemExit

if requirement is None:
    print("|compatible")
    raise SystemExit
if not isinstance(requirement, str):
    print("|invalid")
    raise SystemExit

try:
    from pip._vendor.packaging.specifiers import InvalidSpecifier, SpecifierSet
    from pip._vendor.packaging.version import Version
    compatible = Version(".".join(map(str, sys.version_info[:3]))) in SpecifierSet(requirement)
except (InvalidSpecifier, ValueError):
    print(f"{requirement}|invalid")
    raise SystemExit
except Exception:
    print(f"{requirement}|unreadable")
    raise SystemExit
state = "compatible" if compatible else "incompatible"
print(f"{requirement}|{state}")
' "${BOOTSTRAP_CWD}/pyproject.toml" 2>/dev/null)" || {
        PROJECT_PYTHON_RESULT="unreadable"
        return 0
    }
    case "$info" in
        *'|'*) : ;;
        *) PROJECT_PYTHON_RESULT="unreadable"; return 0 ;;
    esac
    PROJECT_PYTHON_REQUIREMENT="${info%%|*}"
    PROJECT_PYTHON_RESULT="${info#*|}"
    [ -z "$BOOTSTRAP_PROJECT_REQUIRES_PYTHON" ] && [ -n "$PROJECT_PYTHON_REQUIREMENT" ] \
        && BOOTSTRAP_PROJECT_REQUIRES_PYTHON="$PROJECT_PYTHON_REQUIREMENT"
    case "$PROJECT_PYTHON_RESULT" in
        compatible|incompatible|invalid|unreadable) : ;;
        *) PROJECT_PYTHON_RESULT="unreadable" ;;
    esac
}

bootstrap_sdk_version() {
    "$1" -c 'import importlib, importlib.metadata, sys; importlib.import_module(sys.argv[2]); print(importlib.metadata.version(sys.argv[1]))' \
        "$BOOTSTRAP_DISTRIBUTION" "$BOOTSTRAP_IMPORT_MODULE" 2>/dev/null
}

bootstrap_compare_versions() {
    # Set VERSION_RELATION to the second version's relation to the first.
    # The selected resolver interpreter's vendored packaging implementation
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
    # pip has emitted several incompatibility formats over time. Match them
    # case-insensitively and keep only PEP 440 comparison tokens; never echo
    # arbitrary pip output or URLs.
    awk '
    function emit_requirement(fragment, start) {
        start = match(fragment, /[<>=!~]/)
        if (start == 0) return
        fragment = substr(fragment, start)
        sub(/[[:space:]]+$/, "", fragment)
        gsub(/[[:space:]]*,[[:space:]]*/, ",", fragment)
        if (fragment != "") print fragment
    }
    {
        rest = $0
        lower = tolower(rest)
        while (match(lower, /requires-python[[:space:]]*:[[:space:]]*[<>=!~][<>=!~0-9a-z.*+_,[:space:]-]*/)) {
            value = substr(rest, RSTART, RLENGTH)
            emit_requirement(value)
            rest = substr(rest, RSTART + RLENGTH)
            lower = tolower(rest)
        }
        rest = $0
        lower = tolower(rest)
        while (match(lower, /requires-python[[:space:]]+[<>=!~][<>=!~0-9a-z.*+_,[:space:]-]*/)) {
            value = substr(rest, RSTART, RLENGTH)
            emit_requirement(value)
            rest = substr(rest, RSTART + RLENGTH)
            lower = tolower(rest)
        }
        rest = $0
        lower = tolower(rest)
        while (match(lower, /not in:[[:space:]]*'\''[<>=!~][<>=!~0-9a-z.*+_,[:space:]-]*/)) {
            value = substr(rest, RSTART, RLENGTH)
            emit_requirement(value)
            rest = substr(rest, RSTART + RLENGTH)
            lower = tolower(rest)
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

bootstrap_extract_index_version() {
    awk -v distribution="$BOOTSTRAP_DISTRIBUTION" '
        index($0, distribution " (") == 1 && $0 ~ /\)$/ {
            value = $0
            value = substr(value, length(distribution) + 3)
            sub(/\)$/, "", value)
            if (value ~ /^[0-9A-Za-z][0-9A-Za-z.!+_-]*$/) {
                print value
                exit
            }
        }
    ' "$1"
}

bootstrap_probe() {
    local base_python="$1"
    local probe_mode="${2:-auto}"
    local query_log=""
    local probe_virtualenv=""

    PROBE_RESULT=""
    PROBE_PYTHON=""
    PROBE_SDK_VERSION=""
    PROBE_REQUIREMENTS=""
    PROBE_REASON=""

    if ! bootstrap_select_probe_python "$base_python" "$probe_mode"; then
        PROBE_RESULT="failed"
        [ -n "$PROBE_REASON" ] || PROBE_REASON="package_index_query_failed"
        return 0
    fi
    query_log="${BOOTSTRAP_TMP_ROOT}/sdk-index.$$.log"
    if [ "$base_python" = "$BOOTSTRAP_PYTHON" ] && [ -d "$BOOTSTRAP_VENV" ]; then
        probe_virtualenv="$BOOTSTRAP_VENV"
    fi
    if VIRTUAL_ENV="$probe_virtualenv" "$PROBE_PYTHON" -m pip index versions "$BOOTSTRAP_DISTRIBUTION" \
        --disable-pip-version-check --no-input --no-color -v >"$query_log" 2>&1; then
        PROBE_SDK_VERSION="$(bootstrap_extract_index_version "$query_log")"
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
        return 0
    fi

    # Some older pip/index combinations hide every release that has an
    # incompatible Requires-Python without emitting the requirement. Retry the
    # same read-only query without Python filtering: success proves that the
    # package source is reachable and that this interpreter is the mismatch.
    if VIRTUAL_ENV="$probe_virtualenv" "$PROBE_PYTHON" -m pip index versions "$BOOTSTRAP_DISTRIBUTION" \
        --disable-pip-version-check --no-input --no-color --ignore-requires-python \
        >"$query_log" 2>&1; then
        PROBE_SDK_VERSION="$(bootstrap_extract_index_version "$query_log")"
        if [ -n "$PROBE_SDK_VERSION" ]; then
            PROBE_RESULT="incompatible"
            PROBE_REASON="python_incompatible"
            return 0
        fi
    fi

    PROBE_RESULT="failed"
    PROBE_REASON="package_index_query_failed"
}

bootstrap_extract_managed_version() {
    awk -v distribution="$BOOTSTRAP_DISTRIBUTION" '
    function normalize(value) {
        value = tolower(value)
        gsub(/[-_.]+/, "-", value)
        return value
    }
    index(normalize($0), normalize(distribution)) {
        line = $0
        gsub(/[()^~<>=,]/, " ", line)
        count = split(line, parts, /[^0-9A-Za-z.!+_-]+/)
        for (i = 1; i <= count; i++) {
            value = parts[i]
            if (value ~ /^v[0-9]/) value = substr(value, 2)
            if (value ~ /^[0-9][0-9A-Za-z.!+_-]*$/) candidate = value
        }
    }
    END {
        if (candidate != "") print candidate
    }
    ' "$1"
}

bootstrap_probe_managed_ownership() {
    local base_python="$1"
    local query_log="${BOOTSTRAP_TMP_ROOT}/${MANAGED_SOURCE}-ownership.log"
    local sdk_add="no"
    local sdk_remove="no"

    MANAGED_OWNERSHIP_RESULT="failed"
    case "$MANAGED_SOURCE" in
        uv)
            uv sync --dry-run --python "$base_python" --no-progress --color never \
                >"$query_log" 2>&1 || return 0
            grep -Eiq "^[[:space:]]*-[[:space:]]+${BOOTSTRAP_DISTRIBUTION_PATTERN}([=[:space:]]|$)" "$query_log" \
                && sdk_remove="yes"
            grep -Eiq "^[[:space:]]*[+][[:space:]]+${BOOTSTRAP_DISTRIBUTION_PATTERN}([=[:space:]]|$)" "$query_log" \
                && sdk_add="yes"
            if [ "$sdk_add" = "yes" ]; then
                MANAGED_OWNERSHIP_RESULT="drifted"
            elif [ "$sdk_remove" = "yes" ]; then
                MANAGED_OWNERSHIP_RESULT="unowned"
            else
                MANAGED_OWNERSHIP_RESULT="owned"
            fi
            ;;
        poetry)
            poetry install --sync --dry-run --no-interaction --no-ansi \
                >"$query_log" 2>&1 || return 0
            if grep -Eiq "(installing|updating|downgrading)[[:space:]]+${BOOTSTRAP_DISTRIBUTION_PATTERN}([[:space:](]|$)" \
                "$query_log"; then
                MANAGED_OWNERSHIP_RESULT="drifted"
            elif grep -Eiq "removing[[:space:]]+${BOOTSTRAP_DISTRIBUTION_PATTERN}([[:space:](]|$)" "$query_log"; then
                MANAGED_OWNERSHIP_RESULT="unowned"
            else
                MANAGED_OWNERSHIP_RESULT="owned"
            fi
            ;;
    esac
}

bootstrap_probe_managed() {
    local base_python="$1"
    local installed_version="$2"
    local query_log="${BOOTSTRAP_TMP_ROOT}/${MANAGED_SOURCE}-resolve.log"

    PROBE_RESULT=""
    PROBE_SDK_VERSION=""
    PROBE_REQUIREMENTS=""
    PROBE_REASON=""

    if ! bootstrap_select_probe_python "$base_python"; then
        PROBE_RESULT="failed"
        [ -n "$PROBE_REASON" ] || PROBE_REASON="package_index_query_failed"
        return 0
    fi

    case "$MANAGED_SOURCE" in
        uv)
            uv lock --dry-run --upgrade-package "$BOOTSTRAP_DISTRIBUTION" --python "$base_python" \
                --no-progress --color never >"$query_log" 2>&1 || {
                    PROBE_RESULT="failed"
                    PROBE_REASON="package_index_query_failed"
                    return 0
                }
            ;;
        poetry)
            if [ -n "$BOOTSTRAP_POETRY_SOURCE" ]; then
                poetry add --dry-run --no-interaction --no-ansi \
                    "${BOOTSTRAP_DISTRIBUTION}@latest" --source "$BOOTSTRAP_POETRY_SOURCE" \
                    >"$query_log" 2>&1
            else
                poetry add --dry-run --no-interaction --no-ansi \
                    "${BOOTSTRAP_DISTRIBUTION}@latest" >"$query_log" 2>&1
            fi || {
                    PROBE_RESULT="failed"
                    PROBE_REASON="package_index_query_failed"
                    return 0
                }
            ;;
        *)
            PROBE_RESULT="failed"
            PROBE_REASON="package_index_query_failed"
            return 0
            ;;
    esac

    PROBE_SDK_VERSION="$(bootstrap_extract_managed_version "$query_log")"
    [ -n "$PROBE_SDK_VERSION" ] || PROBE_SDK_VERSION="$installed_version"
    if [ -n "$PROBE_SDK_VERSION" ]; then
        PROBE_RESULT="compatible"
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
    if ! bootstrap_matches_configured_python "$CANDIDATE_VERSION"; then
        return 0
    fi
    [ -n "$BOOTSTRAP_CONFIGURED_PYTHON" ] && BOOTSTRAP_CONFIGURED_MATCH_SEEN="yes"
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
        bootstrap_project_python_compatibility "$path" isolated
        case "$PROJECT_PYTHON_RESULT" in
            compatible) : ;;
            incompatible) continue ;;
            invalid)
                BOOTSTRAP_REASON="project_python_constraint_invalid"
                return 2
                ;;
            unreadable)
                BOOTSTRAP_REASON="project_metadata_unreadable"
                return 2
                ;;
        esac
        bootstrap_note "Probing Python ${version} from ${source} for ${BOOTSTRAP_DISTRIBUTION} compatibility..."
        bootstrap_probe "$path" isolated
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
    if [ -n "$BOOTSTRAP_CONFIGURED_PYTHON" ]; then
        if [ "$BOOTSTRAP_CONFIGURED_MATCH_SEEN" = "yes" ]; then
            BOOTSTRAP_REASON="configured_python_incompatible"
        else
            BOOTSTRAP_REASON="configured_python_unavailable"
        fi
    fi
    return 1
}

bootstrap_install_project() {
    local project_python="$1"
    local target_version="${2:-}"
    local install_log="${BOOTSTRAP_TMP_ROOT}/project-install.log"
    local plan_log="${BOOTSTRAP_TMP_ROOT}/poetry-install-plan.log"
    local requirement="$BOOTSTRAP_DISTRIBUTION"
    local action="Installing"
    [ "$BOOTSTRAP_ACTION" = "upgrade" ] && action="Upgrading"
    [ -n "$target_version" ] && requirement="${BOOTSTRAP_DISTRIBUTION}==${target_version}"
    [ -n "$target_version" ] || [ -n "$MANAGED_SOURCE" ] || return 1
    if ! bootstrap_environment_identity "$project_python" "$BOOTSTRAP_VENV"; then
        BOOTSTRAP_REASON="venv_invalid"
        return 2
    fi
    bootstrap_note "${action} ${BOOTSTRAP_DISTRIBUTION} into ${BOOTSTRAP_VENV}..."
    case "$MANAGED_SOURCE" in
        uv)
            if [ -z "$target_version" ] && [ "$MANAGED_OWNERSHIP_RESULT" = "drifted" ]; then
                uv sync --python "$project_python" --no-progress --color never \
                    >"$install_log" 2>&1 || return 1
            else
                uv add "$requirement" >"$install_log" 2>&1 || return 1
            fi
            bootstrap_managed_python_info uv || return 1
            project_python="$BOOTSTRAP_PYTHON"
            ;;
        poetry)
            if [ -z "$target_version" ] && [ "$MANAGED_OWNERSHIP_RESULT" = "drifted" ]; then
                poetry install --no-root --no-interaction --no-ansi >"$install_log" 2>&1 || return 1
            elif [ -z "$target_version" ]; then
                if ! poetry install --dry-run --no-root --no-interaction --no-ansi \
                    >"$plan_log" 2>&1; then
                    return 1
                fi
                if grep -Eiq "(installing|updating|downgrading)[[:space:]]+${BOOTSTRAP_DISTRIBUTION_PATTERN}([[:space:](]|$)" \
                    "$plan_log"; then
                    poetry install --no-root --no-interaction --no-ansi >"$install_log" 2>&1 || return 1
                else
                    if [ -n "$BOOTSTRAP_POETRY_SOURCE" ]; then
                        poetry add "$requirement" --source "$BOOTSTRAP_POETRY_SOURCE" \
                            >"$install_log" 2>&1 || return 1
                    else
                        poetry add "$requirement" >"$install_log" 2>&1 || return 1
                    fi
                fi
            else
                if [ -n "$BOOTSTRAP_POETRY_SOURCE" ]; then
                    poetry add "$requirement" --source "$BOOTSTRAP_POETRY_SOURCE" \
                        >"$install_log" 2>&1 || return 1
                else
                    poetry add "$requirement" >"$install_log" 2>&1 || return 1
                fi
            fi
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
    if [ -n "$target_version" ]; then
        [ "$BOOTSTRAP_SDK_VERSION" = "$target_version" ] && return 0
    elif [ -n "$BOOTSTRAP_SDK_VERSION" ]; then
        return 0
    fi
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
    1)
        case "$1" in
            --install-sdk) BOOTSTRAP_ACTION="install" ;;
            *)
                BOOTSTRAP_REASON="invalid_arguments"
                bootstrap_emit
                exit 0
                ;;
        esac
        ;;
    2)
        case "$1" in
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

if ! bootstrap_validate_profile; then
    BOOTSTRAP_REASON="invalid_profile"
    bootstrap_emit
    exit 0
fi

BOOTSTRAP_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/${BOOTSTRAP_TMP_PREFIX}-bootstrap.XXXXXX")" || {
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
    poetry_source_missing)
        BOOTSTRAP_PYTHON_SOURCE="$MANAGED_SOURCE"
        BOOTSTRAP_REASON="poetry_source_configuration_required"
        bootstrap_emit
        exit 0
        ;;
esac

if [ "$MANAGED_RESULT" = "none" ] && ! bootstrap_load_configured_python; then
    BOOTSTRAP_REASON="configured_python_unavailable"
    bootstrap_emit
    exit 0
fi

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
    if bootstrap_matches_configured_python "$BOOTSTRAP_PYTHON_VERSION"; then
        [ -n "$BOOTSTRAP_CONFIGURED_PYTHON" ] && BOOTSTRAP_CONFIGURED_MATCH_SEEN="yes"
        bootstrap_project_python_compatibility "$BOOTSTRAP_PYTHON"
    else
        PROJECT_PYTHON_RESULT="incompatible"
    fi
    case "$PROJECT_PYTHON_RESULT" in
        invalid)
            BOOTSTRAP_VENV_STATE="incompatible"
            BOOTSTRAP_REASON="project_python_constraint_invalid"
            bootstrap_emit
            exit 0
            ;;
        unreadable)
            BOOTSTRAP_VENV_STATE="incompatible"
            BOOTSTRAP_REASON="project_metadata_unreadable"
            bootstrap_emit
            exit 0
            ;;
        incompatible)
            BOOTSTRAP_VENV_STATE="incompatible"
            if [ -n "$MANAGED_SOURCE" ]; then
                BOOTSTRAP_REASON="managed_python_incompatible"
            elif bootstrap_find_compatible_alternative "$CANDIDATE_CANONICAL"; then
                BOOTSTRAP_AVAILABLE_PYTHON="$CANDIDATE_PATH"
                BOOTSTRAP_AVAILABLE_VERSION="$CANDIDATE_VERSION"
                BOOTSTRAP_REASON="venv_python_incompatible"
            else
                [ -n "$BOOTSTRAP_REASON" ] || BOOTSTRAP_REASON="no_compatible_python"
            fi
            bootstrap_emit
            exit 0
            ;;
    esac
    BOOTSTRAP_SDK_VERSION="$(bootstrap_sdk_version "$BOOTSTRAP_PYTHON")"
    if [ -n "$BOOTSTRAP_SDK_VERSION" ] && [ -n "$MANAGED_SOURCE" ]; then
        bootstrap_probe_managed_ownership "$BOOTSTRAP_PYTHON"
        case "$MANAGED_OWNERSHIP_RESULT" in
            owned) : ;;
            unowned|drifted)
                bootstrap_note "The installed ${BOOTSTRAP_DISTRIBUTION} does not exactly match ${MANAGED_SOURCE} synchronization; manager reconciliation is required."
                BOOTSTRAP_SDK_VERSION=""
                BOOTSTRAP_AVAILABLE_SDK_VERSION=""
                ;;
            *)
                BOOTSTRAP_VENV_STATE="reused"
                BOOTSTRAP_SDK="installed"
                bootstrap_emit_version_decision "sdk_version_check_failed"
                exit 0
                ;;
        esac
    fi
    if [ -n "$BOOTSTRAP_SDK_VERSION" ]; then
        BOOTSTRAP_VENV_STATE="reused"
        BOOTSTRAP_SDK="installed"
        bootstrap_note "Checking the installed ${BOOTSTRAP_DISTRIBUTION} ${BOOTSTRAP_SDK_VERSION} for a newer compatible release..."
        if [ -n "$MANAGED_SOURCE" ]; then
            bootstrap_probe_managed "$BOOTSTRAP_PYTHON" "$BOOTSTRAP_SDK_VERSION"
        else
            bootstrap_probe "$BOOTSTRAP_PYTHON"
        fi
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

    if [ -n "$MANAGED_SOURCE" ]; then
        if [ "$BOOTSTRAP_ACTION" = "check" ]; then
            bootstrap_emit_install_decision "sdk_install_required"
            exit 0
        fi
        if bootstrap_install_project "$BOOTSTRAP_PYTHON"; then
            BOOTSTRAP_VENV_STATE="reused"
            BOOTSTRAP_SDK="installed_now"
            BOOTSTRAP_STATUS="ready"
        else
            BOOTSTRAP_VENV_STATE="reused"
            BOOTSTRAP_SDK="missing"
            [ -n "$BOOTSTRAP_REASON" ] || BOOTSTRAP_REASON="sdk_install_failed"
        fi
        bootstrap_emit
        exit 0
    fi

    bootstrap_note "Probing the existing .venv interpreter for ${BOOTSTRAP_DISTRIBUTION} compatibility..."
    bootstrap_probe "$BOOTSTRAP_PYTHON"
    bootstrap_merge_requirements "$PROBE_REQUIREMENTS"
    case "$PROBE_RESULT" in
        compatible)
            BOOTSTRAP_AVAILABLE_SDK_VERSION="$PROBE_SDK_VERSION"
            if [ "$BOOTSTRAP_ACTION" = "install" ]; then
                BOOTSTRAP_REASON="install_requires_managed_environment"
                bootstrap_emit
                exit 0
            fi
            if bootstrap_install_project "$BOOTSTRAP_PYTHON" "$BOOTSTRAP_AVAILABLE_SDK_VERSION"; then
                BOOTSTRAP_VENV_STATE="reused"
                BOOTSTRAP_SDK="installed_now"
                BOOTSTRAP_STATUS="ready"
            else
                BOOTSTRAP_VENV_STATE="failed"
                [ -n "$BOOTSTRAP_REASON" ] || BOOTSTRAP_REASON="package_install_failed"
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
    if ! bootstrap_matches_configured_python "$CANDIDATE_VERSION"; then
        CANDIDATE_PATH=""
    else
        [ -n "$BOOTSTRAP_CONFIGURED_PYTHON" ] && BOOTSTRAP_CONFIGURED_MATCH_SEEN="yes"
        bootstrap_project_python_compatibility "$DEFAULT_PYTHON" isolated
        case "$PROJECT_PYTHON_RESULT" in
            invalid)
                BOOTSTRAP_REASON="project_python_constraint_invalid"
                bootstrap_emit
                exit 0
                ;;
            unreadable)
                BOOTSTRAP_REASON="project_metadata_unreadable"
                bootstrap_emit
                exit 0
                ;;
            incompatible)
                CANDIDATE_PATH=""
                ;;
            compatible)
                bootstrap_note "Probing default Python ${CANDIDATE_VERSION} for ${BOOTSTRAP_DISTRIBUTION} compatibility..."
                bootstrap_probe "$DEFAULT_PYTHON" isolated
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
                ;;
        esac
    fi
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
elif ! bootstrap_copy_site_policy "$BOOTSTRAP_VENV"; then
    PROJECT_INSTALL_REASON="venv_create_failed"
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
