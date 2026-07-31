#!/usr/bin/env python3
"""Resolve DataLens RLS subjects and convert legacy RLS configs to RLSv2 — Yandex Cloud.

For cloud DataLens (datalens.yandex.cloud); subjects come from Cloud Organization / IAM.
Turns human-readable subject names (logins, emails, group names) into the exact
``subject_id`` values DataLens RLSv2 (the ``rls2`` field) stores.

Two modes:

* ``resolve`` - names -> RLSv2 ``subject`` objects.
* ``convert`` - a legacy ``rls`` text config ({field_guid: "text"}) -> the full RLSv2
  config ({field_guid: [rule, ...]}), resolving every subject.

Standard library only. Identity lookups go through the ``yc`` CLI (Cloud Organization
Manager) using its own IAM-token session — this tool never handles or prints a token.
The caller (the skill) is responsible for ensuring ``yc`` is authenticated first.

The subject-id semantics mirror the DataLens backend (dl_rls): ``subject_id`` is
authoritative (users → cloud subject id; groups → org group id); ``subject_name`` is
display-only; unresolved subjects become ``notfound`` with a ``!FAILED_`` name prefix.
"""

import argparse
import json
import subprocess
import sys


FAILED_PREFIX = "!FAILED_"
GROUP_PREFIX = "@group:"
SA_PREFIX = "@sa:"
ALL_NAME = "*"
USERID_NAME = "userid"


class YcError(RuntimeError):
    """Raised when the `yc` CLI is missing or a call fails (often expired auth)."""


class YcPermissionError(YcError):
    """Raised when `yc` is authenticated but lacks target-organization access."""


# --------------------------------------------------------------------------------------
# Ported pure logic (from dl_rls; kept in sync by hand — this skill is standalone).
# --------------------------------------------------------------------------------------


def is_slug(group_id, group_name):
    """A group is still a slug (unresolved) when its id equals its name minus ``@group:``."""
    return group_id == group_name.strip().removeprefix(GROUP_PREFIX)


def split_by_quoted_quote(value, quote="'"):
    """Parse a leading CSV-style quoted value (quotes doubled). From dl_rls.utils.

    >>> split_by_quoted_quote("'ab''c'''de")
    ("ab'c'", 'de')
    """
    ql = len(quote)
    if not value.startswith(quote):
        raise ValueError("Value does not start with quote")
    value = value[ql:]
    result = []
    while True:
        try:
            next_quote = value.index(quote)
        except ValueError as exc_value:
            raise ValueError("Unclosed quote") from exc_value
        result.append(value[:next_quote])
        value = value[next_quote + ql :]
        if value.startswith(quote):
            result.append(quote)
            value = value[ql:]
        else:
            break
    return "".join(result), value


def quote_by_quote(value, quote="'"):
    """Inverse of split_by_quoted_quote. From dl_rls.utils."""
    return f"{quote}{value.replace(quote, quote + quote)}{quote}"


def parse_legacy_field_config(config):
    """Parse one field's legacy RLS text config into (pattern_type, allowed_value, names).

    Grammar mirrors dl_rls FieldRLSSerializer:
      'value': s1, s2   -> ("value", <value>, [s1, s2])
      *: s1, s2         -> ("all",   None,    [s1, s2])
      userid: userid    -> ("userid", None,   ["userid"])
    Returns a list of tuples, one per line (blank config -> []).
    """
    if not config:
        return []
    parsed = []
    for idx, raw_line in enumerate(config.strip().split("\n")):
        stripped = raw_line.strip()
        if not stripped:
            continue
        pattern_type, value, subjects_line = _parse_single_line(raw_line, idx)
        subject_names = [name.strip() for name in subjects_line.split(",")]
        _validate_wildcard(subject_names, pattern_type, idx)
        parsed.append((pattern_type, value, subject_names))
    return parsed


def _parse_single_line(line, idx):
    stripped = line.strip()
    if stripped.startswith(ALL_NAME):
        rest = stripped[len(ALL_NAME) :].lstrip()
        if not rest.startswith(":"):
            raise ValueError(f"Line {idx + 1}: expected ':' after '*'")
        return "all", None, rest[1:].strip()
    if stripped.replace(" ", "") == "userid:userid":
        return "userid", None, USERID_NAME
    if not stripped.startswith("'"):
        raise ValueError(f"Line {idx + 1}: wrong format")
    value, rest = split_by_quoted_quote(stripped)
    rest = rest.strip()
    if not rest.startswith(":"):
        raise ValueError(f"Line {idx + 1}: expected ':' after quoted value")
    return "value", value, rest[1:].strip()


def _validate_wildcard(subject_names, pattern_type, idx):
    if ALL_NAME in subject_names:
        if pattern_type == "all":
            raise ValueError(f"Line {idx + 1}: '*: *' is not allowed (would disable RLS)")
        if len(subject_names) != 1:
            raise ValueError(f"Line {idx + 1}: wildcard '*' must be the only subject on the line")


def normalize_subject_name(name):
    """Normalize a raw input token to a canonical subject name.

    In cloud, users are matched by login OR email exactly as typed (no domain stripping),
    and groups are referenced by name via ``@group:<name>``. Specials/SA pass through.
    """
    name = name.strip()
    if name in (ALL_NAME, USERID_NAME):
        return name
    if name.startswith(SA_PREFIX):
        return name
    if name.startswith(GROUP_PREFIX):
        return name
    return name


def split_raw_input(raw):
    """Split a blob (or list) of subject names on comma/newline/semicolon; dedupe.

    Note: spaces are NOT separators — cloud group names can contain spaces.
    """
    if isinstance(raw, str):
        raw = [raw]
    tokens = []
    for chunk in raw:
        for line in chunk.replace(";", "\n").replace(",", "\n").splitlines():
            token = line.strip()
            if token:
                tokens.append(token)
    seen = set()
    ordered = []
    for token in tokens:
        if token not in seen:
            seen.add(token)
            ordered.append(token)
    return ordered


def classify(name):
    """Return one of: 'all', 'userid', 'sa', 'group', 'user'."""
    if name == ALL_NAME:
        return "all"
    if name == USERID_NAME:
        return "userid"
    if name.startswith(SA_PREFIX):
        return "sa"
    if name.startswith(GROUP_PREFIX):
        return "group"
    return "user"


def make_subject(subject_id, subject_name, subject_type):
    return {"subject_id": subject_id, "subject_name": subject_name, "subject_type": subject_type}


def notfound_subject(original_name, keep_id=""):
    return make_subject(keep_id, FAILED_PREFIX + original_name, "notfound")


# --------------------------------------------------------------------------------------
# Orchestration (network is injected via a resolver object).
# --------------------------------------------------------------------------------------


class SubjectResolver:
    """Interface: a resolver batches user lookups and resolves group names to org ids."""

    def resolve_users(self, logins):
        """logins/emails -> {name: subject_id or None}."""
        raise NotImplementedError

    def resolve_group(self, spec):
        """A group spec (without the @group: prefix, e.g. 'Analysts') -> org group id or None."""
        raise NotImplementedError


def resolve_names(names, resolver):
    """Resolve a list of canonical subject names to RLSv2 subject dicts."""
    canonical = [normalize_subject_name(n) for n in names]
    user_logins = sorted({n for n in canonical if classify(n) == "user"})
    user_ids = resolver.resolve_users(user_logins) if user_logins else {}

    subjects = {}
    for name in canonical:
        kind = classify(name)
        if kind == "all":
            subjects[name] = make_subject(ALL_NAME, ALL_NAME, "all")
        elif kind == "userid":
            subjects[name] = make_subject("", USERID_NAME, "userid")
        elif kind == "sa":
            sa_id = name.removeprefix(SA_PREFIX)
            subjects[name] = make_subject(sa_id, name, "user")
        elif kind == "group":
            spec = name.removeprefix(GROUP_PREFIX)
            real_id = resolver.resolve_group(spec)
            if real_id is not None:
                subjects[name] = make_subject(real_id, name, "group")
            else:
                subjects[name] = notfound_subject(name, keep_id=spec)
        else:  # user
            uid = user_ids.get(name)
            if uid:
                subjects[name] = make_subject(uid, name, "user")
            else:
                subjects[name] = notfound_subject(name)
    return canonical, subjects


def convert_config(rls_config, resolver):
    """Convert a legacy rls config ({field_guid: text}) to a full rls2 config."""
    per_field = {}
    all_names = set()
    for field_guid, text in rls_config.items():
        lines = parse_legacy_field_config(text)
        per_field[field_guid] = lines
        for _pattern, _value, names in lines:
            for name in names:
                all_names.add(normalize_subject_name(name))

    _, subjects = resolve_names(sorted(all_names), resolver)

    rls2 = {}
    for field_guid, lines in per_field.items():
        rules = []
        for pattern_type, value, names in lines:
            for name in names:
                canonical = normalize_subject_name(name)
                subject = subjects[canonical]
                rules.append(
                    {
                        "subject": dict(subject),
                        "allowed_value": value if pattern_type == "value" else None,
                        "pattern_type": pattern_type,
                    }
                )
        rls2[field_guid] = rules
    return rls2


# --------------------------------------------------------------------------------------
# Yandex Cloud resolver — yc CLI (Cloud Organization Manager), IAM-token session.
# --------------------------------------------------------------------------------------


def _claim(claims, *keys):
    for key in keys:
        if claims.get(key):
            return claims[key]
    return None


class YandexCloudResolver(SubjectResolver):
    def __init__(self, org_id):
        self._org_id = org_id
        self._members_cache = None
        self._groups_cache = None

    def _yc(self, *args):
        try:
            proc = subprocess.run(
                ["yc", *args, "--organization-id", self._org_id, "--format", "json"],
                capture_output=True,
                text=True,
                check=False,
            )
        except FileNotFoundError as exc_value:
            raise YcError("`yc` CLI not found on PATH. Install the Yandex Cloud CLI.") from exc_value
        if proc.returncode != 0:
            # Surface yc's own message (typically an auth/permission error) without secrets.
            error_text = proc.stderr.strip()
            compact_error = "".join(error_text.lower().split())
            error_class = YcPermissionError if "permissiondenied" in compact_error else YcError
            raise error_class(f"`yc {' '.join(args)}` failed: {error_text}")
        return json.loads(proc.stdout or "[]")

    def _members(self):
        if self._members_cache is None:
            self._members_cache = self._yc("organization-manager", "user", "list")
        return self._members_cache

    def _groups(self):
        if self._groups_cache is None:
            self._groups_cache = self._yc("organization-manager", "group", "list")
        return self._groups_cache

    @staticmethod
    def _subject_id(member):
        return member.get("subjectId") or member.get("subject_id") or member.get("id")

    @staticmethod
    def _claims(member):
        return member.get("subjectClaims") or member.get("subject_claims") or {}

    def resolve_users(self, logins):
        # No server-side login/email filter on user list; match client-side on claims.
        members = self._members()
        by_login = {}
        by_email = {}
        for member in members:
            claims = self._claims(member)
            subject_id = self._subject_id(member)
            login = _claim(claims, "preferredUsername", "preferred_username", "name")
            email = _claim(claims, "email")
            if login:
                by_login[login] = subject_id
            if email:
                by_email[email] = subject_id
        return {login: by_login.get(login) or by_email.get(login) for login in logins}

    def resolve_group(self, spec):
        # In cloud, a group is referenced by its name.
        for group in self._groups():
            if group.get("name") == spec:
                return group.get("id")
        return None


# --------------------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------------------


def _read_names(args):
    if args.names:
        return args.names
    return [sys.stdin.read()]


def cmd_resolve(args):
    resolver = YandexCloudResolver(args.org_id)
    names = split_raw_input(_read_names(args))
    canonical, subjects = resolve_names(names, resolver)
    resolved = []
    seen = set()
    unresolved = []
    for name in canonical:
        subject = subjects[name]
        if subject["subject_type"] == "notfound":
            unresolved.append(subject["subject_name"].removeprefix(FAILED_PREFIX))
            continue
        key = json.dumps(subject, sort_keys=True)
        if key not in seen:
            seen.add(key)
            resolved.append(subject)
    output = {"installation": "yandex-cloud", "resolved": resolved, "unresolved": sorted(set(unresolved))}
    print(json.dumps(output, ensure_ascii=False, indent=2))


def cmd_convert(args):
    resolver = YandexCloudResolver(args.org_id)
    raw = open(args.input, encoding="utf-8").read() if args.input else sys.stdin.read()
    rls_config = json.loads(raw)
    if not isinstance(rls_config, dict):
        sys.exit("convert expects a JSON object {field_guid: \"text config\"}.")
    rls2 = convert_config(rls_config, resolver)
    print(json.dumps(rls2, ensure_ascii=False, indent=2))
    failed = [
        rule["subject"]["subject_name"]
        for rules in rls2.values()
        for rule in rules
        if rule["subject"]["subject_type"] == "notfound"
    ]
    if failed:
        print(f"WARNING: {len(failed)} unresolved subject(s): {sorted(set(failed))}", file=sys.stderr)


def build_parser():
    parser = argparse.ArgumentParser(
        description="Resolve DataLens RLS subjects / convert legacy rls to rls2 (Yandex Cloud)."
    )
    sub = parser.add_subparsers(dest="command", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--org-id", required=True, help="Cloud organization id.")

    resolve_parser = sub.add_parser("resolve", parents=[common], help="Resolve subject names to rls2 subjects.")
    resolve_parser.add_argument("names", nargs="*", help="Subject names (or pass via stdin).")
    resolve_parser.set_defaults(func=cmd_resolve)

    convert_parser = sub.add_parser("convert", parents=[common], help="Convert a legacy rls config to rls2.")
    convert_parser.add_argument("--input", help="Path to a JSON file {field_guid: text} (default: stdin).")
    convert_parser.set_defaults(func=cmd_convert)

    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        args.func(args)
    except YcPermissionError as exc_value:
        sys.exit(
            f"ERROR: {exc_value}\n"
            "Ask an organization admin to grant at least organization-manager.viewer on the "
            "target organization, then retry."
        )
    except YcError as exc_value:
        sys.exit(f"ERROR: {exc_value}\nRe-authenticate the yc CLI (see the skill's yc-auth step) and retry.")


if __name__ == "__main__":
    main()
