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
from contextlib import redirect_stdout
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
    def test_resolves_member_claims_and_group_id(self):
        resolver = rls_tool.YandexCloudResolver("org1")
        resolver._members_cache = [
            {
                "subjectId": "aje-alice",
                "subjectClaims": {"preferredUsername": "alice", "email": "alice@example.com"},
            }
        ]
        resolver._groups_cache = [{"name": "Analysts", "id": "grp-1"}]

        self.assertEqual(
            resolver.resolve_users(["alice", "alice@example.com", "ghost"]),
            {"alice": "aje-alice", "alice@example.com": "aje-alice", "ghost": None},
        )
        self.assertEqual(resolver.resolve_group("Analysts"), "grp-1")

    @mock.patch.object(rls_tool.subprocess, "run")
    def test_yc_group_list_uses_exact_organization_arguments(self, run):
        run.return_value = SimpleNamespace(
            returncode=0,
            stdout='[{"name": "Analysts", "id": "grp-1"}]',
            stderr="",
        )
        resolver = rls_tool.YandexCloudResolver("org1")

        self.assertEqual(resolver.resolve_group("Analysts"), "grp-1")
        run.assert_called_once_with(
            [
                "yc",
                "organization-manager",
                "group",
                "list",
                "--organization-id",
                "org1",
                "--format",
                "json",
            ],
            capture_output=True,
            text=True,
            check=False,
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
