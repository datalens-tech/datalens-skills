#!/usr/bin/env python3
"""Offline tests for the Yandex Cloud rls_tool logic and CLI output.

No network or yc CLI calls are made. The resolver is a fake injected object. Yandex Cloud
normalization keeps emails as-is and allows spaces in group names.

Run: python3 tests/test_rls_tool.py
"""

import io
import json
import os
import sys
import tempfile
from contextlib import redirect_stderr, redirect_stdout
from types import SimpleNamespace
import unittest
from unittest import mock


sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))

import rls_tool  # noqa: E402


class FakeResolver(rls_tool.SubjectResolver):
    def __init__(self, users, groups):
        self._users = users
        self._groups = groups

    def resolve_users(self, logins):
        return {login: self._users.get(login) for login in logins}

    def resolve_group(self, spec):
        return self._groups.get(spec)


class TestNormalization(unittest.TestCase):
    def test_user_kept_as_typed(self):
        # Yandex Cloud must NOT strip the email domain; it matches subjectClaims.email.
        self.assertEqual(rls_tool.normalize_subject_name("alice@example.com"), "alice@example.com")
        self.assertEqual(rls_tool.normalize_subject_name("bob"), "bob")

    def test_group_and_specials(self):
        self.assertEqual(rls_tool.normalize_subject_name("@group:Analysts"), "@group:Analysts")
        self.assertEqual(rls_tool.normalize_subject_name("*"), "*")
        self.assertEqual(rls_tool.normalize_subject_name("userid"), "userid")
        self.assertEqual(rls_tool.normalize_subject_name("@sa:aje1"), "@sa:aje1")

    def test_split_keeps_spaces_in_names(self):
        # Comma/newline/semicolon separate; spaces do NOT (cloud group names have spaces).
        self.assertEqual(
            rls_tool.split_raw_input(["alice@example.com, Sales Team\nBob Jones; bob"]),
            ["alice@example.com", "Sales Team", "Bob Jones", "bob"],
        )


class TestLegacyParser(unittest.TestCase):
    def test_value_all_userid(self):
        config = "'Moscow': alice@example.com\n*: bob\nuserid: userid"
        self.assertEqual(
            rls_tool.parse_legacy_field_config(config),
            [
                ("value", "Moscow", ["alice@example.com"]),
                ("all", None, ["bob"]),
                ("userid", None, ["userid"]),
            ],
        )

    def test_quoted_value(self):
        self.assertEqual(
            rls_tool.parse_legacy_field_config("'O''Brien': bob"),
            [("value", "O'Brien", ["bob"])],
        )


class TestResolveNames(unittest.TestCase):
    def setUp(self):
        self.resolver = FakeResolver(
            users={"alice@example.com": "aje1alice", "bob": "aje2bob"},
            groups={"Analysts": "grp-analysts-1"},
        )

    def test_user_by_email_and_missing(self):
        _, subjects = rls_tool.resolve_names(["alice@example.com", "ghost"], self.resolver)
        self.assertEqual(
            subjects["alice@example.com"],
            {"subject_id": "aje1alice", "subject_name": "alice@example.com", "subject_type": "user"},
        )
        self.assertEqual(
            subjects["ghost"],
            {"subject_id": "", "subject_name": "!FAILED_ghost", "subject_type": "notfound"},
        )

    def test_group_by_name(self):
        _, subjects = rls_tool.resolve_names(["@group:Analysts"], self.resolver)
        self.assertEqual(
            subjects["@group:Analysts"],
            {"subject_id": "grp-analysts-1", "subject_name": "@group:Analysts", "subject_type": "group"},
        )

    def test_group_unresolved(self):
        _, subjects = rls_tool.resolve_names(["@group:Ghosts"], self.resolver)
        self.assertEqual(
            subjects["@group:Ghosts"],
            {"subject_id": "Ghosts", "subject_name": "!FAILED_@group:Ghosts", "subject_type": "notfound"},
        )


class TestConvertConfig(unittest.TestCase):
    def test_full_config(self):
        resolver = FakeResolver(users={"bob": "aje2bob"}, groups={"Analysts": "grp-1"})
        rls_config = {"field_a": "'Naperville': @group:Analysts\n*: bob"}
        rls2 = rls_tool.convert_config(rls_config, resolver)
        self.assertEqual(
            rls2,
            {
                "field_a": [
                    {
                        "subject": {
                            "subject_id": "grp-1",
                            "subject_name": "@group:Analysts",
                            "subject_type": "group",
                        },
                        "allowed_value": "Naperville",
                        "pattern_type": "value",
                    },
                    {
                        "subject": {"subject_id": "aje2bob", "subject_name": "bob", "subject_type": "user"},
                        "allowed_value": None,
                        "pattern_type": "all",
                    },
                ]
            },
        )


class TestCliOutput(unittest.TestCase):
    @mock.patch.object(rls_tool, "YandexCloudResolver")
    def test_resolve_uses_public_installation_name(self, resolver_class):
        resolver_class.return_value = FakeResolver(users={"bob": "aje2bob"}, groups={})
        output = io.StringIO()
        with redirect_stdout(output):
            rls_tool.cmd_resolve(SimpleNamespace(org_id="org1", names=["bob"]))
        self.assertEqual(json.loads(output.getvalue())["installation"], "yandex-cloud")

    @mock.patch.object(rls_tool, "YandexCloudResolver")
    def test_resolve_lists_unresolved_names_separately(self, resolver_class):
        resolver_class.return_value = FakeResolver(users={}, groups={})
        output = io.StringIO()
        with redirect_stdout(output):
            rls_tool.cmd_resolve(SimpleNamespace(org_id="org1", names=["ghost"]))
        self.assertEqual(
            json.loads(output.getvalue()),
            {"installation": "yandex-cloud", "resolved": [], "unresolved": ["ghost"]},
        )


class TestYandexCloudAdapter(unittest.TestCase):
    """Matches the real `yc ... user list` shape: OrganizationUser -> {subject_claims: {...}},
    id at subject_claims.sub, preferred_username always present, email only sometimes."""

    def _resolver_with_members(self):
        resolver = rls_tool.YandexCloudResolver("org1")
        resolver._members_cache = [
            # yandex.ru user: preferred_username email-shaped, email also present.
            {"subject_claims": {"sub": "aje-alice", "preferred_username": "alice@yandex.ru",
                                "email": "alice@yandex.ru", "sub_type": "USER_ACCOUNT"}},
            # federated user: preferred_username present, NO email (the common yc case).
            {"subject_claims": {"sub": "aje-fed", "preferred_username": "bob@corp.com",
                                "sub_type": "USER_ACCOUNT"}},
            # service account reusing alice's login: must be ignored for user matching.
            {"subject_claims": {"sub": "sa-x", "preferred_username": "alice@yandex.ru",
                                "sub_type": "SERVICE_ACCOUNT"}},
        ]
        resolver._groups_cache = [{"name": "Analysts", "id": "grp-1"}]
        return resolver

    def test_user_resolution_reads_sub_and_is_case_insensitive(self):
        resolver = self._resolver_with_members()
        self.assertEqual(
            resolver.resolve_users(["alice", "Alice@Yandex.RU", "bob@corp.com", "bob", "ghost"]),
            {
                "alice": "aje-alice",            # bare login -> @yandex.ru account
                "Alice@Yandex.RU": "aje-alice",  # case-insensitive full email
                "bob@corp.com": "aje-fed",       # federated user resolved via preferred_username (no email)
                "bob": None,                     # bare federated login does not resolve
                "ghost": None,                   # missing
            },
        )

    def test_service_accounts_are_not_matched_as_users(self):
        # The SERVICE_ACCOUNT reusing alice's login is filtered out, so alice stays unambiguous.
        resolver = self._resolver_with_members()
        self.assertEqual(resolver.resolve_users(["alice@yandex.ru"]), {"alice@yandex.ru": "aje-alice"})

    def test_ambiguous_user_is_left_unresolved(self):
        resolver = rls_tool.YandexCloudResolver("org1")
        resolver._members_cache = [
            {"subject_claims": {"sub": "id1", "preferred_username": "dup@yandex.ru", "sub_type": "USER_ACCOUNT"}},
            {"subject_claims": {"sub": "id2", "preferred_username": "dup@yandex.ru", "sub_type": "USER_ACCOUNT"}},
        ]
        with redirect_stderr(io.StringIO()):
            self.assertEqual(resolver.resolve_users(["dup@yandex.ru"]), {"dup@yandex.ru": None})

    def test_group_resolves_by_exact_name(self):
        self.assertEqual(self._resolver_with_members().resolve_group("Analysts"), "grp-1")

    def test_duplicate_group_name_is_left_unresolved(self):
        resolver = rls_tool.YandexCloudResolver("org1")
        resolver._groups_cache = [{"name": "Dups", "id": "g1"}, {"name": "Dups", "id": "g2"}]
        with redirect_stderr(io.StringIO()):
            self.assertIsNone(resolver.resolve_group("Dups"))

    @mock.patch.object(rls_tool.subprocess, "run")
    def test_user_list_passes_limit_to_defeat_truncation(self, run):
        run.return_value = SimpleNamespace(returncode=0, stdout="[]", stderr="")
        rls_tool.YandexCloudResolver("org1")._members()
        run.assert_called_once_with(
            ["yc", "organization-manager", "user", "list", "--limit", "1000000",
             "--organization-id", "org1", "--format", "json"],
            capture_output=True, text=True, check=False,
        )

    @mock.patch.object(rls_tool.subprocess, "run")
    def test_yc_group_list_uses_exact_organization_arguments(self, run):
        run.return_value = SimpleNamespace(
            returncode=0, stdout='[{"name": "Analysts", "id": "grp-1"}]', stderr="",
        )
        resolver = rls_tool.YandexCloudResolver("org1")
        self.assertEqual(resolver.resolve_group("Analysts"), "grp-1")
        run.assert_called_once_with(
            ["yc", "organization-manager", "group", "list", "--limit", "1000000",
             "--organization-id", "org1", "--format", "json"],
            capture_output=True, text=True, check=False,
        )


class TestYcErrorSurfacing(unittest.TestCase):
    def test_missing_yc_raises_ycerror(self):
        resolver = rls_tool.YandexCloudResolver("org1")
        original_path = os.environ.get("PATH", "")
        os.environ["PATH"] = ""  # ensure `yc` is not found
        try:
            with self.assertRaises(rls_tool.YcError):
                resolver.resolve_group("Analysts")
        finally:
            os.environ["PATH"] = original_path

    @mock.patch.object(rls_tool.subprocess, "run")
    def test_permission_denied_has_a_distinct_error_type(self, run):
        run.return_value = SimpleNamespace(
            returncode=1,
            stdout="",
            stderr="ERROR: rpc error: code = PermissionDenied desc = permission denied",
        )
        resolver = rls_tool.YandexCloudResolver("org1")

        with self.assertRaises(rls_tool.YcPermissionError):
            resolver.resolve_group("Analysts")

    @mock.patch.object(rls_tool, "YandexCloudResolver")
    def test_permission_denied_advises_role_instead_of_reauthentication(self, resolver_class):
        resolver_class.return_value.resolve_users.side_effect = rls_tool.YcPermissionError("PermissionDenied")

        with self.assertRaises(SystemExit) as exit_info:
            rls_tool.main(["resolve", "--org-id", "org1", "alice"])

        message = str(exit_info.exception)
        self.assertIn("organization-manager.viewer", message)
        self.assertNotIn("Re-authenticate", message)

    @mock.patch.object(rls_tool, "YandexCloudResolver")
    def test_other_yc_errors_still_advise_reauthentication(self, resolver_class):
        resolver_class.return_value.resolve_users.side_effect = rls_tool.YcError("session expired")

        with self.assertRaises(SystemExit) as exit_info:
            rls_tool.main(["resolve", "--org-id", "org1", "alice"])

        self.assertIn("Re-authenticate", str(exit_info.exception))


class TestLegacyParserErrors(unittest.TestCase):
    def _err(self, config):
        with self.assertRaises(ValueError) as ctx:
            rls_tool.parse_legacy_field_config(config)
        return str(ctx.exception)

    def test_star_star_disables_rls(self):
        self.assertIn("not allowed", self._err("*: *"))

    def test_wildcard_with_other_subjects(self):
        self.assertIn("only subject", self._err("'Moscow': alice, *"))

    def test_unquoted_value(self):
        self.assertIn("wrong format", self._err("Moscow: alice"))

    def test_unclosed_quote(self):
        self.assertIn("Unclosed", self._err("'Moscow: alice"))

    def test_missing_colon_after_star(self):
        self.assertIn("expected ':'", self._err("* alice"))


class TestMainFriendlyErrors(unittest.TestCase):
    @mock.patch.object(rls_tool, "YandexCloudResolver")
    def test_malformed_input_reports_friendly_error(self, resolver_class):
        # Non-JSON, non-parseable text: a friendly ERROR (line-numbered), never a traceback.
        resolver_class.return_value = FakeResolver(users={}, groups={})
        with mock.patch.object(rls_tool.sys, "stdin", io.StringIO("garbage line with no marker")), \
                redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as ctx:
                rls_tool.main(["convert", "--org-id", "org1"])
        self.assertTrue(str(ctx.exception).startswith("ERROR:"))

    @mock.patch.object(rls_tool, "YandexCloudResolver")
    def test_parser_error_reports_line_number(self, resolver_class):
        resolver_class.return_value = FakeResolver(users={}, groups={})
        with mock.patch.object(rls_tool.sys, "stdin", io.StringIO('{"f1": "Moscow: bob"}')):
            with self.assertRaises(SystemExit) as ctx:
                rls_tool.main(["convert", "--org-id", "org1"])
        message = str(ctx.exception)
        self.assertTrue(message.startswith("ERROR:"))
        self.assertIn("Line 1", message)


class TestConvertCli(unittest.TestCase):
    @mock.patch.object(rls_tool, "YandexCloudResolver")
    def test_convert_reads_stdin_and_emits_rls2(self, resolver_class):
        resolver_class.return_value = FakeResolver(users={"bob": "aje-bob"}, groups={})
        out = io.StringIO()
        with mock.patch.object(rls_tool.sys, "stdin", io.StringIO('{"f1": "*: bob"}')), \
                redirect_stderr(io.StringIO()), redirect_stdout(out):
            rls_tool.cmd_convert(SimpleNamespace(org_id="org1", input=None))
        self.assertEqual(json.loads(out.getvalue())["f1"][0]["subject"]["subject_id"], "aje-bob")

    @mock.patch.object(rls_tool, "YandexCloudResolver")
    def test_convert_reads_input_file(self, resolver_class):
        resolver_class.return_value = FakeResolver(users={"bob": "aje-bob"}, groups={})
        fd, path = tempfile.mkstemp(suffix=".json")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write('{"f1": "*: bob"}')
            out = io.StringIO()
            with redirect_stderr(io.StringIO()), redirect_stdout(out):
                rls_tool.cmd_convert(SimpleNamespace(org_id="org1", input=path))
            self.assertIn("aje-bob", out.getvalue())
        finally:
            os.unlink(path)

    @mock.patch.object(rls_tool, "YandexCloudResolver")
    def test_convert_accepts_single_field_raw_text(self, resolver_class):
        # No {field_guid: ...} wrapper: raw text converts under the placeholder guid.
        resolver_class.return_value = FakeResolver(users={"bob": "aje-bob"}, groups={})
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(rls_tool.sys, "stdin", io.StringIO("*: bob")), \
                redirect_stderr(err), redirect_stdout(out):
            rls_tool.cmd_convert(SimpleNamespace(org_id="org1", input=None))
        result = json.loads(out.getvalue())
        self.assertEqual(list(result), ["<field_guid>"])
        self.assertEqual(result["<field_guid>"][0]["subject"]["subject_id"], "aje-bob")
        self.assertIn("<field_guid>", err.getvalue())  # NOTE steers the caller to substitute it

    @mock.patch.object(rls_tool, "YandexCloudResolver")
    def test_convert_treats_json_string_as_raw_text(self, resolver_class):
        resolver_class.return_value = FakeResolver(users={"bob": "aje-bob"}, groups={})
        out = io.StringIO()
        with mock.patch.object(rls_tool.sys, "stdin", io.StringIO(json.dumps("*: bob"))), \
                redirect_stderr(io.StringIO()), redirect_stdout(out):
            rls_tool.cmd_convert(SimpleNamespace(org_id="org1", input=None))
        self.assertEqual(list(json.loads(out.getvalue())), ["<field_guid>"])

    @mock.patch.object(rls_tool, "YandexCloudResolver")
    def test_convert_warns_about_unresolved_on_stderr(self, resolver_class):
        resolver_class.return_value = FakeResolver(users={}, groups={})
        err = io.StringIO()
        with mock.patch.object(rls_tool.sys, "stdin", io.StringIO('{"f1": "*: ghost@yandex.ru"}')), \
                redirect_stdout(io.StringIO()), redirect_stderr(err):
            rls_tool.cmd_convert(SimpleNamespace(org_id="org1", input=None))
        self.assertIn("WARNING", err.getvalue())
        self.assertIn("unresolved", err.getvalue())


class TestAuthCheckWrapper(unittest.TestCase):
    """The auth-check subcommand must report status without ever emitting the token."""

    @mock.patch.object(rls_tool.subprocess, "run")
    def test_authenticated_never_prints_token(self, run):
        run.return_value = SimpleNamespace(returncode=0, stdout="t1.SECRET-TOKEN-VALUE", stderr="")
        out = io.StringIO()
        with redirect_stdout(out), self.assertRaises(SystemExit) as ctx:
            rls_tool.main(["auth-check"])
        self.assertEqual(ctx.exception.code, 0)
        self.assertEqual(out.getvalue().strip(), "authenticated")
        self.assertNotIn("SECRET-TOKEN-VALUE", out.getvalue())
        # Output is captured, not inherited — the token can never reach the terminal.
        _, kwargs = run.call_args
        self.assertTrue(kwargs.get("capture_output"))
        self.assertIsNotNone(kwargs.get("timeout"))

    @mock.patch.object(rls_tool.subprocess, "run")
    def test_not_authenticated_exits_1(self, run):
        run.return_value = SimpleNamespace(returncode=1, stdout="", stderr="unauthenticated")
        out = io.StringIO()
        with redirect_stdout(out), self.assertRaises(SystemExit) as ctx:
            rls_tool.main(["auth-check"])
        self.assertEqual(ctx.exception.code, 1)
        self.assertEqual(out.getvalue().strip(), "not_authenticated")

    @mock.patch.object(rls_tool.subprocess, "run")
    def test_blocked_check_reports_timeout(self, run):
        run.side_effect = rls_tool.subprocess.TimeoutExpired(cmd="yc", timeout=15)
        out = io.StringIO()
        with redirect_stdout(out), self.assertRaises(SystemExit) as ctx:
            rls_tool.main(["auth-check", "--timeout", "1"])
        self.assertEqual(ctx.exception.code, 2)
        self.assertEqual(out.getvalue().strip(), "timeout")

    @mock.patch.object(rls_tool.subprocess, "run")
    def test_missing_yc_reports_not_installed(self, run):
        run.side_effect = FileNotFoundError()
        out = io.StringIO()
        with redirect_stdout(out), self.assertRaises(SystemExit) as ctx:
            rls_tool.main(["auth-check"])
        self.assertEqual(ctx.exception.code, 3)
        self.assertEqual(out.getvalue().strip(), "not_installed")


if __name__ == "__main__":
    unittest.main(verbosity=2)
