#!/bin/bash

set -u

MOCK_CONFIG="${0}.config"
[ -f "$MOCK_CONFIG" ] || exit 90
. "$MOCK_CONFIG"

if [ "${1:-}" = "-c" ]; then
    MOCK_CODE="${2:-}"
    case "$MOCK_CODE" in
        *'import pip'*'pip._vendor.packaging.specifiers'*)
            case "$MOCK_PROBE_RUNTIME" in
                available) exit 0 ;;
                legacy)
                    case "$MOCK_CODE" in
                        *'pip._vendor import tomli'*) exit 1 ;;
                        *) exit 0 ;;
                    esac
                    ;;
                *) exit 1 ;;
            esac
            ;;
        *'print(os.path.realpath(sys.prefix))'*)
            MOCK_BIN_DIR="${0%/*}"
            MOCK_PREFIX="${MOCK_BIN_DIR%/*}"
            printf '%s\n' "$MOCK_PREFIX"
            exit 0
            ;;
        *'project.get("requires-python")'*)
            if [ "$MOCK_PROBE_RUNTIME" = "legacy" ]; then
                case "$MOCK_CODE" in
                    *'pip._vendor import toml as tomllib'*) : ;;
                    *) exit 1 ;;
                esac
            fi
            printf '%s|%s\n' "$MOCK_PROJECT_REQUIRES_PYTHON" "$MOCK_PROJECT_PYTHON_RESULT"
            exit 0
            ;;
        *'expected = os.path.realpath'*'is_virtualenv'*)
            case "$MOCK_ENV_IDENTITY" in
                valid) : ;;
                valid_once)
                    [ ! -e "${0}.identity-checked" ] || exit 1
                    touch "${0}.identity-checked"
                    ;;
                *) exit 1 ;;
            esac
            MOCK_BIN_DIR="${0%/*}"
            MOCK_PREFIX="${MOCK_BIN_DIR%/*}"
            [ "$MOCK_PREFIX" = "${3:-}" ]
            exit $?
            ;;
        *'sys.executable'*'sys.prefix'*)
            MOCK_BIN_DIR="${0%/*}"
            MOCK_PREFIX="${MOCK_BIN_DIR%/*}"
            printf '%s|%s\n' "$0" "$MOCK_PREFIX"
            exit 0
            ;;
        *'sys.version_info'*'os.path.realpath'*)
            OLD_IFS="$IFS"
            IFS='.'
            set -- $MOCK_VERSION
            IFS="$OLD_IFS"
            MOCK_MAJOR="${1:-0}"
            MOCK_MINOR="${2:-0}"
            MOCK_PATCH="${3:-0}"
            MOCK_SCORE=$((MOCK_MAJOR * 100000000 + MOCK_MINOR * 100000 + MOCK_PATCH))
            printf '%s|%s|%s\n' "$MOCK_VERSION" "$MOCK_SCORE" "$0"
            exit 0
            ;;
        *'pip._vendor.packaging.version'*)
            MOCK_FIRST_VERSION="${3:-}"
            MOCK_SECOND_VERSION="${4:-}"
            if [ "$MOCK_FIRST_VERSION" = "$MOCK_SECOND_VERSION" ]; then
                printf 'equal\n'
                exit 0
            fi
            case "$MOCK_VERSION_RELATION" in
                newer|older)
                    printf '%s\n' "$MOCK_VERSION_RELATION"
                    exit 0
                    ;;
                fail) exit 1 ;;
                *) exit 91 ;;
            esac
            ;;
        *'importlib.import_module'*'importlib.metadata.version'*)
            [ "${3:-}" = "$MOCK_DISTRIBUTION" ] || exit 1
            [ "${4:-}" = "$MOCK_IMPORT_MODULE" ] || exit 1
            if [ -f "${0}.sdk-installed" ]; then
                MOCK_RECORDED_VERSION="$(<"${0}.sdk-installed")"
                printf '%s\n' "${MOCK_RECORDED_VERSION:-$MOCK_INSTALLED_SDK_VERSION}"
                exit 0
            fi
            exit 1
            ;;
    esac
    exit 1
fi

if [ "${1:-}" = "-m" ] && [ "${2:-}" = "venv" ]; then
    MOCK_TARGET="${3:?}"
    mkdir -p "${MOCK_TARGET}/bin"
    if [ "$MOCK_VENV_MODE" = "fail_project" ] && [ "${MOCK_TARGET##*/}" = ".venv" ]; then
        exit 1
    fi
    cp "$0" "${MOCK_TARGET}/bin/python"
    cp "$MOCK_CONFIG" "${MOCK_TARGET}/bin/python.config"
    printf 'MOCK_PROBE_RUNTIME=%s\n' "$MOCK_VENV_PROBE_RUNTIME" \
        >>"${MOCK_TARGET}/bin/python.config"
    printf 'MOCK_IS_VIRTUALENV=yes\n' >>"${MOCK_TARGET}/bin/python.config"
    chmod +x "${MOCK_TARGET}/bin/python"
    if [ -f "${0}.sdk-installed" ]; then
        cp "${0}.sdk-installed" "${MOCK_TARGET}/bin/python.sdk-installed"
    fi
    exit 0
fi

if [ "${1:-}" = "-m" ] && [ "${2:-}" = "pip" ]; then
    printf '%s %s\n' "$0" "$*" >>"$MOCK_CALL_LOG"
    case "$MOCK_PROBE_RUNTIME" in
        available|legacy) : ;;
        *) exit 1 ;;
    esac
    if [ "${PIP_REQUIRE_VIRTUALENV:-}" = "true" ] && [ "$MOCK_IS_VIRTUALENV" != "yes" ]; then
        printf 'ERROR: Could not find an activated virtualenv (required).\n' >&2
        exit 3
    fi
    case "$*" in
        *"index versions ${MOCK_DISTRIBUTION}"*)
            if [ -n "$MOCK_REQUIRED_PIP_CONFIG" ]; then
                MOCK_BIN_DIR="${0%/*}"
                MOCK_PREFIX="${MOCK_BIN_DIR%/*}"
                grep -Fq -- "$MOCK_REQUIRED_PIP_CONFIG" "${MOCK_PREFIX}/pip.conf" 2>/dev/null || {
                    printf 'ERROR: configured package source was not preserved\n' >&2
                    exit 1
                }
            fi
            case "$MOCK_INSTALL_MODE" in
                success|fail_project_install|fail_project_break_sdk)
                    printf '%s (%s)\n' "$MOCK_DISTRIBUTION" "$MOCK_SDK_VERSION"
                    printf 'Available versions: %s\n' "$MOCK_SDK_VERSION"
                    exit 0
                    ;;
                incompatible)
                    printf 'Link requires a different Python: release Requires-Python %s\n' "$MOCK_REQUIREMENTS" >&2
                    printf 'ERROR: No matching distribution found for %s\n' "$MOCK_DISTRIBUTION" >&2
                    exit 1
                    ;;
                incompatible_silent)
                    case "$*" in
                        *'--ignore-requires-python'*)
                            printf '%s (%s)\n' "$MOCK_DISTRIBUTION" "$MOCK_SDK_VERSION"
                            printf 'Available versions: %s\n' "$MOCK_SDK_VERSION"
                            exit 0
                            ;;
                    esac
                    printf 'ERROR: No matching distribution found for %s\n' "$MOCK_DISTRIBUTION" >&2
                    exit 1
                    ;;
                incompatible_fixture)
                    cat "$MOCK_PIP_OUTPUT_FIXTURE" >&2
                    exit 1
                    ;;
                fail)
                    printf 'ERROR: package index is unavailable\n' >&2
                    exit 1
                    ;;
            esac
            ;;
        *'--upgrade pip'*)
            if [ "$MOCK_PIP_UPGRADE_MODE" = "success" ]; then
                printf 'Successfully installed pip\n'
                exit 0
            fi
            printf 'ERROR: pip upgrade failed\n' >&2
            exit 1
            ;;
        *'pip install'*"${MOCK_DISTRIBUTION}"*)
            MOCK_TARGET_SDK_VERSION="$MOCK_SDK_VERSION"
            for MOCK_ARG in "$@"; do
                case "$MOCK_ARG" in
                    "${MOCK_DISTRIBUTION}"==*) MOCK_TARGET_SDK_VERSION="${MOCK_ARG#${MOCK_DISTRIBUTION}==}" ;;
                esac
            done
            case "$MOCK_INSTALL_MODE" in
                success|fail_project_install|fail_project_break_sdk)
                    if [ "$MOCK_INSTALL_MODE" = "fail_project_install" ] || [ "$MOCK_INSTALL_MODE" = "fail_project_break_sdk" ]; then
                        case "$0" in
                            */.venv/bin/python)
                                if [ "$MOCK_INSTALL_MODE" = "fail_project_break_sdk" ]; then
                                    rm -f "${0}.sdk-installed"
                                fi
                                printf 'ERROR: project installation failed\n' >&2
                                exit 1
                                ;;
                        esac
                    fi
                    printf '%s\n' "$MOCK_TARGET_SDK_VERSION" >"${0}.sdk-installed"
                    printf 'Successfully installed %s\n' "$MOCK_DISTRIBUTION"
                    exit 0
                    ;;
                incompatible)
                    printf 'ERROR: Ignored versions that require a different python version: release Requires-Python %s\n' "$MOCK_REQUIREMENTS" >&2
                    printf 'ERROR: No matching distribution found for %s\n' "$MOCK_DISTRIBUTION" >&2
                    exit 1
                    ;;
                fail)
                    printf 'ERROR: package index is unavailable\n' >&2
                    exit 1
                    ;;
            esac
            ;;
    esac
fi

exit 1
