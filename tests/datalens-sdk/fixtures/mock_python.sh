#!/bin/bash

set -u

MOCK_CONFIG="${0}.config"
[ -f "$MOCK_CONFIG" ] || exit 90
. "$MOCK_CONFIG"

if [ "${1:-}" = "-c" ]; then
    MOCK_CODE="${2:-}"
    case "$MOCK_CODE" in
        *'project.get("requires-python")'*)
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
        *'importlib.metadata'*'datalens_sdk'*)
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
    chmod +x "${MOCK_TARGET}/bin/python"
    if [ -f "${0}.sdk-installed" ]; then
        cp "${0}.sdk-installed" "${MOCK_TARGET}/bin/python.sdk-installed"
    fi
    exit 0
fi

if [ "${1:-}" = "-m" ] && [ "${2:-}" = "pip" ]; then
    printf '%s %s\n' "$0" "$*" >>"$MOCK_CALL_LOG"
    case "$*" in
        *'index versions datalens-sdk'*)
            case "$MOCK_INSTALL_MODE" in
                success|fail_project_install|fail_project_break_sdk)
                    printf 'datalens-sdk (%s)\n' "$MOCK_SDK_VERSION"
                    printf 'Available versions: %s\n' "$MOCK_SDK_VERSION"
                    exit 0
                    ;;
                incompatible)
                    printf 'Link requires a different Python: release Requires-Python %s\n' "$MOCK_REQUIREMENTS" >&2
                    printf 'ERROR: No matching distribution found for datalens-sdk\n' >&2
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
        *'pip install'*'datalens-sdk'*)
            MOCK_TARGET_SDK_VERSION="$MOCK_SDK_VERSION"
            for MOCK_ARG in "$@"; do
                case "$MOCK_ARG" in
                    datalens-sdk==*) MOCK_TARGET_SDK_VERSION="${MOCK_ARG#datalens-sdk==}" ;;
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
                    printf 'Successfully installed datalens-sdk\n'
                    exit 0
                    ;;
                incompatible)
                    printf 'ERROR: Ignored versions that require a different python version: release Requires-Python %s\n' "$MOCK_REQUIREMENTS" >&2
                    printf 'ERROR: No matching distribution found for datalens-sdk\n' >&2
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
