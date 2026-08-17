#!/usr/bin/env bash

set -eu

TEST_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BOOTSTRAP_SCRIPT="${TEST_ROOT}/skills/datalens-sdk/scripts/bootstrap.sh"
PROFILE_WRAPPER="${DATALENS_BOOTSTRAP_PROFILE_WRAPPER:-}"
TEST_DISTRIBUTION="${DATALENS_BOOTSTRAP_TEST_DISTRIBUTION:-example-private-sdk}"
TEST_MODULE="${DATALENS_BOOTSTRAP_TEST_IMPORT_MODULE:-example_private_sdk}"
TEST_DEPENDENCY="${DATALENS_BOOTSTRAP_TEST_DEPENDENCY:-example-public-sdk}"
TEST_DEPENDENCY_MODULE="${DATALENS_BOOTSTRAP_TEST_DEPENDENCY_MODULE:-example_public_sdk}"
TEST_POETRY_SOURCE="${DATALENS_BOOTSTRAP_TEST_POETRY_SOURCE:-example-private}"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/datalens-poetry-bootstrap-tests.XXXXXX")"
SERVER_PID=""
export POETRY_CACHE_DIR="$TEST_TMP/poetry-cache"
export POETRY_VIRTUALENVS_PATH="$TEST_TMP/poetry-venvs"

cleanup() {
    [ -z "$SERVER_PID" ] || kill "$SERVER_PID" >/dev/null 2>&1 || true
    if [ "${DATALENS_BOOTSTRAP_KEEP_TEST_TMP:-no}" = "yes" ]; then
        printf 'Preserved test directory: %s\n' "$TEST_TMP" >&2
        return
    fi
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

command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v poetry >/dev/null 2>&1 || fail "Poetry is required"
[ -f "$BOOTSTRAP_SCRIPT" ] || fail "public bootstrap not found"
if [ -n "$PROFILE_WRAPPER" ]; then
    case "$PROFILE_WRAPPER" in
        /*) : ;;
        *) fail "DATALENS_BOOTSTRAP_PROFILE_WRAPPER must be absolute" ;;
    esac
    [ -f "$PROFILE_WRAPPER" ] || fail "profile wrapper not found"
fi

INDEX_ROOT="$TEST_TMP/indexes"
mkdir -p "$INDEX_ROOT/internal/simple" "$INDEX_ROOT/public/simple" "$INDEX_ROOT/packages"

python3 - "$INDEX_ROOT" "$TEST_DISTRIBUTION" "$TEST_MODULE" "$TEST_DEPENDENCY" \
    "$TEST_DEPENDENCY_MODULE" <<'PY'
import base64
import csv
import hashlib
import io
import pathlib
import sys
import zipfile

root = pathlib.Path(sys.argv[1])
private_distribution, private_module, public_distribution, public_module = sys.argv[2:]


def build_wheel(distribution, module, version, requires=()):
    normalized = distribution.replace("-", "_")
    filename = f"{normalized}-{version}-py3-none-any.whl"
    dist_info = f"{normalized}-{version}.dist-info"
    files = {
        f"{module}/__init__.py": f'__version__ = "{version}"\n'.encode(),
        f"{dist_info}/METADATA": (
            "Metadata-Version: 2.1\n"
            f"Name: {distribution}\n"
            f"Version: {version}\n"
            "Requires-Python: >=3.10\n"
            + "".join(f"Requires-Dist: {requirement}\n" for requirement in requires)
            + "\n"
        ).encode(),
        f"{dist_info}/WHEEL": (
            "Wheel-Version: 1.0\n"
            "Generator: datalens-bootstrap-test\n"
            "Root-Is-Purelib: true\n"
            "Tag: py3-none-any\n"
        ).encode(),
    }
    records = []
    for path, content in files.items():
        digest = base64.urlsafe_b64encode(hashlib.sha256(content).digest()).rstrip(b"=").decode()
        records.append((path, f"sha256={digest}", str(len(content))))
    record_path = f"{dist_info}/RECORD"
    records.append((record_path, "", ""))
    output = io.StringIO()
    csv.writer(output, lineterminator="\n").writerows(records)
    files[record_path] = output.getvalue().encode()

    wheel_path = root / "packages" / filename
    with zipfile.ZipFile(wheel_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path, content in files.items():
            info = zipfile.ZipInfo(path, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, content)
    return filename, hashlib.sha256(wheel_path.read_bytes()).hexdigest()


public_wheel, public_hash = build_wheel(public_distribution, public_module, "0.6.0")
private_wheel, private_hash = build_wheel(
    private_distribution,
    private_module,
    "0.3.0",
    (f"{public_distribution} (==0.6.0)",),
)

(root / "internal/simple/index.html").write_text(
    f'<a href="{private_distribution}/">{private_distribution}</a>\n', encoding="utf-8"
)
(root / "internal/simple" / private_distribution).mkdir(parents=True, exist_ok=True)
(root / "internal/simple" / private_distribution / "index.html").write_text(
    f'<a href="../../../packages/{private_wheel}#sha256={private_hash}">{private_wheel}</a>\n',
    encoding="utf-8",
)
(root / "public/simple/index.html").write_text(
    f'<a href="{public_distribution}/">{public_distribution}</a>\n', encoding="utf-8"
)
(root / "public/simple" / public_distribution).mkdir(parents=True, exist_ok=True)
(root / "public/simple" / public_distribution / "index.html").write_text(
    f'<a href="../../../packages/{public_wheel}#sha256={public_hash}">{public_wheel}</a>\n',
    encoding="utf-8",
)
PY

PORT_FILE="$TEST_TMP/server-port"
SERVER_LOG="$TEST_TMP/server.log"
python3 - "$INDEX_ROOT" "$PORT_FILE" >"$SERVER_LOG" 2>&1 <<'PY' &
import functools
import http.server
import pathlib
import sys

root = sys.argv[1]
port_file = pathlib.Path(sys.argv[2])
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=root)
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
port_file.write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
PY
SERVER_PID=$!

attempt=0
while [ ! -s "$PORT_FILE" ]; do
    kill -0 "$SERVER_PID" >/dev/null 2>&1 || fail "local package server failed to start"
    attempt=$((attempt + 1))
    [ "$attempt" -lt 100 ] || fail "timed out waiting for local package server"
    sleep 0.05
done
PORT="$(cat "$PORT_FILE")"

run_bootstrap() {
    local project="$1"
    shift
    if [ -n "$PROFILE_WRAPPER" ]; then
        (cd "$project" && /bin/bash "$PROFILE_WRAPPER" --engine "$BOOTSTRAP_SCRIPT" "$@")
    else
        (
            cd "$project"
            DATALENS_BOOTSTRAP_DISTRIBUTION="$TEST_DISTRIBUTION" \
            DATALENS_BOOTSTRAP_IMPORT_MODULE="$TEST_MODULE" \
            DATALENS_BOOTSTRAP_CHANGELOG_URL="" \
            DATALENS_BOOTSTRAP_POETRY_SOURCE="$TEST_POETRY_SOURCE" \
                /bin/bash "$BOOTSTRAP_SCRIPT" "$@"
        )
    fi
}

MISSING_PROJECT="$TEST_TMP/missing-source"
mkdir -p "$MISSING_PROJECT"
printf '%s\n' \
    '[tool.poetry]' \
    'name = "missing-source"' \
    'version = "0.1.0"' \
    'description = ""' \
    'authors = []' \
    '' \
    '[tool.poetry.dependencies]' \
    'python = ">=3.10,<4"' \
    >"$MISSING_PROJECT/pyproject.toml"
MISSING_BEFORE="$(python3 -c 'import hashlib, pathlib, sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' "$MISSING_PROJECT/pyproject.toml")"
output="$(run_bootstrap "$MISSING_PROJECT")"
assert_contains "$output" "PYTHON_SOURCE=poetry"
assert_contains "$output" "REASON=poetry_source_configuration_required"
assert_contains "$output" "STATUS=blocked"
[ ! -e "$MISSING_PROJECT/poetry.lock" ] || fail "missing source created a lockfile"
[ ! -e "$MISSING_PROJECT/.venv" ] || fail "missing source created an environment"
MISSING_AFTER="$(python3 -c 'import hashlib, pathlib, sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' "$MISSING_PROJECT/pyproject.toml")"
[ "$MISSING_BEFORE" = "$MISSING_AFTER" ] || fail "missing source changed pyproject.toml"
[ ! -s "$SERVER_LOG" ] || fail "missing source reached a package index"

CONFIGURED_PROJECT="$TEST_TMP/configured-source"
mkdir -p "$CONFIGURED_PROJECT"
printf '%s\n' \
    '[tool.poetry]' \
    'name = "configured-source"' \
    'version = "0.1.0"' \
    'description = ""' \
    'authors = []' \
    '' \
    '[tool.poetry.dependencies]' \
    'python = ">=3.10,<4"' \
    "$TEST_DEPENDENCY = { version = \"*\", source = \"example-public\" }" \
    '' \
    '[[tool.poetry.source]]' \
    "name = \"$TEST_POETRY_SOURCE\"" \
    "url = \"http://127.0.0.1:${PORT}/internal/simple/\"" \
    'priority = "primary"' \
    '' \
    '[[tool.poetry.source]]' \
    'name = "example-public"' \
    "url = \"http://127.0.0.1:${PORT}/public/simple/\"" \
    'priority = "explicit"' \
    >"$CONFIGURED_PROJECT/pyproject.toml"

output="$(run_bootstrap "$CONFIGURED_PROJECT")"
assert_contains "$output" "PYTHON_SOURCE=poetry"
assert_contains "$output" "REASON=sdk_install_required"
assert_contains "$output" "STATUS=decision_required"

output="$(run_bootstrap "$CONFIGURED_PROJECT" --install-sdk)"
assert_contains "$output" "PYTHON_SOURCE=poetry"
assert_contains "$output" "SDK_VERSION=0.3.0"
assert_contains "$output" "STATUS=ready"

PROJECT_PYTHON="$(cd "$CONFIGURED_PROJECT" && poetry run python -c 'import sys; print(sys.executable)')"
installed="$($PROJECT_PYTHON -c 'from importlib.metadata import version; import importlib, sys; importlib.import_module(sys.argv[2]); importlib.import_module(sys.argv[4]); print(version(sys.argv[1])); print(version(sys.argv[3]))' "$TEST_DEPENDENCY" "$TEST_DEPENDENCY_MODULE" "$TEST_DISTRIBUTION" "$TEST_MODULE")"
assert_contains "$installed" "0.6.0"
assert_contains "$installed" "0.3.0"
project_config="$(cat "$CONFIGURED_PROJECT/pyproject.toml")"
assert_contains "$project_config" "$TEST_DISTRIBUTION = {version = \"^0.3.0\", source = \"$TEST_POETRY_SOURCE\"}"

requests="$(cat "$SERVER_LOG")"
assert_contains "$requests" "/internal/simple/$TEST_DISTRIBUTION/"
assert_contains "$requests" "/public/simple/$TEST_DEPENDENCY/"
assert_not_contains "$requests" "/internal/simple/$TEST_DEPENDENCY/"
assert_not_contains "$requests" "/public/simple/$TEST_DISTRIBUTION/"

printf '2 Poetry source integration tests passed with %s\n' "$(poetry --version)"
