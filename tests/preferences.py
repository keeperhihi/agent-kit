import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import tomlkit

SOURCE = Path(__file__).resolve().parents[1]


class InstallerTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="agent-kit test ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.repo = self.root / "repo with spaces"
        self.repo.mkdir()
        for name in ["install.sh", "install.ps1", "preferences.py", "requirements.txt"]:
            shutil.copy2(SOURCE / name, self.repo / name)
        shutil.copytree(SOURCE / "gateways", self.repo / "gateways")
        self.claude = self.root / "claude home"
        self.codex = self.root / "codex home"
        self.environment = dict(os.environ, CLAUDE_CONFIG_DIR=str(self.claude),
                                CODEX_HOME=str(self.codex) + "/",
                                PATH=str(Path(sys.executable).parent) + os.pathsep + os.environ["PATH"])
        self.environment.pop("CODEXMANAGER_API_KEY", None)
        self.write(self.repo / "claude/settings.json", '{"theme":"dark","idleCompaction":false,"env":{"DISABLE_TELEMETRY":"1"},"permissions":{"defaultMode":"bypassPermissions"}}')
        self.write(self.repo / "claude/plugins/claude-hud/config.json", '{"display":{"showModel":true}}')
        self.write(self.repo / "codex/config.toml", 'approval_policy = "never"\n[tui]\nstatus_line = ["model"]\n[desktop]\nappearanceTheme = "light"\n')
        self.write(self.repo / "instructions.md", "# Shared instructions\n")
        self.write(self.repo / "skills/example/SKILL.md", "# Example\n")
        self.write(self.repo / "skills/example/scripts/check.sh", "echo example\n")
        self.write(self.repo / "vendor/skills/vendor-example/SKILL.md", "# Vendor example\n")

    def write(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value, encoding="utf-8")

    def run_installer(self, *args, success=True):
        result = subprocess.run(["/bin/bash", str(self.repo / "install.sh"), *args],
                                env=self.environment, capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def json(self, path):
        return json.loads(path.read_text())

    def toml(self):
        return tomlkit.parse((self.codex / "config.toml").read_text())


class ReadyInstallerTest(InstallerTest):
    @classmethod
    def setUpClass(cls):
        if sys.prefix == sys.base_prefix:
            raise RuntimeError("Run preference tests with .venv/bin/python.")

    def setUp(self):
        super().setUp()
        # Reuse the test environment; BootstrapTest exercises real creation.
        (self.repo / ".venv").symlink_to(Path(sys.prefix), target_is_directory=True)


class GatewayPreferencesTest(ReadyInstallerTest):
    def run_installer(self, *args, success=True):
        return super().run_installer("--gateway", "magpie", *args, success=success)

    def existing(self):
        self.write(self.claude / "settings.json", json.dumps({
            "theme": "light", "model": "deepseek/deepseek-flash[1m]", "effortLevel": "max",
            "env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:3425", "ANTHROPIC_AUTH_TOKEN": "magpie-claude"},
            "permissions": {"allow": ["Read"], "defaultMode": "default"}, "hooks": {"Stop": []}}))
        self.write(self.codex / "config.toml", '''# Gateway owned by Magpie
model = "codex/gpt-6-astra"
openai_base_url = "http://127.0.0.1:3425/backend-api/codex"
approval_policy = "on-request" # personal preference
[model_providers.magpie]
base_url = "http://127.0.0.1:3425/v1"
[mcp_servers.docs]
url = "https://example.com/mcp"
[desktop]
appearanceTheme = "dark"
foreign_option = true
[projects."/a/project"]
trust_level = "trusted"
''')
        self.untouched = {}
        for directory, relative, text in [
            (self.codex, "auth.json", '{"auth_mode":"chatgpt","tokens":{"access_token":"test-token"}}'),
            (self.codex, "AGENTS.md", "# User instructions\n"),
            (self.claude, "CLAUDE.md", "# Other instructions\n"),
            (self.codex, "skills/example/SKILL.md", "# Existing skill\n"),
            (self.claude, ".credentials.json", '{"token":"test-credential"}'),
            (self.codex, "sessions/existing.jsonl", '{"session":"existing"}\n'),
        ]:
            path = directory / relative
            self.write(path, text)
            self.untouched[path] = path.read_bytes()

    def assert_untouched(self):
        for path, content in self.untouched.items():
            self.assertEqual(path.read_bytes(), content, str(path))

    def test_apply_reapply_and_restore_preserve_magpie(self):
        self.existing()
        self.run_installer()
        cc = self.json(self.claude / "settings.json")
        self.assertEqual(cc["theme"], "dark")
        self.assertEqual(cc["env"]["ANTHROPIC_AUTH_TOKEN"], "magpie-claude")
        self.assertEqual(cc["permissions"]["allow"], ["Read"])
        self.assertEqual(self.toml()["model"], "codex/gpt-6-astra")
        self.assertEqual(self.toml()["mcp_servers"]["docs"]["url"], "https://example.com/mcp")
        self.assertEqual(self.toml()["desktop"]["foreign_option"], True)
        self.assertIn("# Gateway owned by Magpie", (self.codex / "config.toml").read_text())
        self.assertIn("# personal preference", (self.codex / "config.toml").read_text())
        before = (self.codex / "config.toml").read_bytes()
        self.run_installer()
        self.assertEqual((self.codex / "config.toml").read_bytes(), before)
        # Magpie changes its route while the personal preference installer is in use.
        text = (self.codex / "config.toml").read_text().replace('codex/gpt-6-astra', 'deepseek/deepseek-flash')
        self.write(self.codex / "config.toml", text)
        self.run_installer()
        self.assertEqual(self.toml()["model"], "deepseek/deepseek-flash")
        self.assert_untouched()
        self.run_installer("-r")
        self.assertEqual(self.toml()["model"], "deepseek/deepseek-flash")
        self.assertEqual(self.toml()["approval_policy"], "on-request")
        self.assertEqual(self.toml()["desktop"]["appearanceTheme"], "dark")
        self.assertEqual(self.json(self.claude / "settings.json")["theme"], "light")
        self.assert_untouched()
        self.assertFalse((self.codex / ".agent-kit/preferences.json").exists())

    def test_fresh_install_creates_only_preferences(self):
        self.run_installer()
        for directory in [self.claude, self.codex]:
            for relative in ["AGENTS.md", "CLAUDE.md", "skills", "auth.json"]:
                self.assertFalse((directory / relative).exists())
        self.run_installer("-r")
        self.assertFalse((self.claude / "settings.json").exists())
        self.assertFalse((self.codex / "config.toml").exists())
        self.run_installer("-r", success=False)

    def test_restore_keeps_later_edits_and_new_siblings(self):
        self.run_installer()
        cc = self.json(self.claude / "settings.json")
        cc["theme"] = "system"
        cc["env"]["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:3425"
        self.write(self.claude / "settings.json", json.dumps(cc))
        self.run_installer("-r")
        self.assertEqual(self.json(self.claude / "settings.json"), {
            "theme": "system", "env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:3425"}})

    def test_removed_preference_releases_only_that_field(self):
        self.existing()
        self.run_installer()
        patch = self.json(self.repo / "claude/settings.json")
        del patch["theme"]
        self.write(self.repo / "claude/settings.json", json.dumps(patch))
        self.run_installer()
        self.assertEqual(self.json(self.claude / "settings.json")["theme"], "light")
        self.assertEqual(self.toml()["model"], "codex/gpt-6-astra")
        self.assert_untouched()

    def test_removed_patch_restores_preferences_without_routing(self):
        self.existing()
        self.run_installer()
        (self.repo / "codex/config.toml").unlink()
        self.run_installer()
        self.assertEqual(self.toml()["approval_policy"], "on-request")
        self.assertEqual(self.toml()["model"], "codex/gpt-6-astra")
        self.assert_untouched()

    @unittest.skipIf(os.geteuid() == 0, "requires ordinary user filesystem permissions")
    def test_failed_reinstall_can_restore_original_preferences(self):
        self.existing()
        self.run_installer()
        # Reapply a changed preference and release another; fail after the
        # record is written but before the live TOML can be replaced.
        self.write(self.repo / "codex/config.toml", 'approval_policy = "untrusted"\n')
        self.codex.chmod(0o500)
        try:
            self.run_installer("codex", success=False)
        finally:
            self.codex.chmod(0o700)
        self.run_installer("-r")
        self.assertEqual(self.toml()["approval_policy"], "on-request")
        self.assertEqual(self.toml()["desktop"]["appearanceTheme"], "dark")
        self.assert_untouched()

    def test_invalid_live_config_prevents_all_selected_writes(self):
        self.existing()
        before = (self.claude / "settings.json").read_bytes()
        self.write(self.codex / "config.toml", 'model = "test-secret\n')
        result = self.run_installer(success=False)
        self.assertNotIn("test-secret", result.stderr)
        self.assertEqual((self.claude / "settings.json").read_bytes(), before)
        self.assertFalse((self.claude / ".agent-kit").exists())

    def test_existing_parent_type_is_not_discarded(self):
        self.write(self.claude / "settings.json", '{"env":"keep-this"}')
        before = (self.claude / "settings.json").read_bytes()
        self.run_installer(success=False)
        self.assertEqual((self.claude / "settings.json").read_bytes(), before)
        self.assertFalse(self.codex.exists())

    def test_old_state_and_dangling_instruction_links_are_left_for_handoff(self):
        self.existing()
        old = self.codex / ".agent-kit/original/config.toml"
        self.write(old, 'model_provider = "cm"')
        self.write(self.codex / ".agent-kit/managed", "config.toml\nauth.json\nAGENTS.md\n")
        (self.codex / "AGENTS.md").unlink()
        (self.codex / "AGENTS.md").symlink_to(self.repo / "codex/AGENTS.md")
        self.run_installer()
        self.run_installer("-r")
        self.assertEqual(old.read_text(), 'model_provider = "cm"')
        self.assertEqual(self.toml()["model"], "codex/gpt-6-astra")
        self.assertTrue((self.codex / "AGENTS.md").is_symlink())
        self.run_installer("-r", success=False)

    def test_selected_client_and_removed_options(self):
        self.run_installer("codex")
        self.assertFalse(self.claude.exists())
        for args in [("--cm-key", "unused"), ("--with-vendor",), ("unknown",)]:
            self.run_installer(*args, success=False)

    def test_symlink_config_is_not_followed_or_detached(self):
        self.codex.mkdir()
        outside = self.root / "outside.toml"
        self.write(outside, 'model = "outside"')
        (self.codex / "config.toml").symlink_to(outside)
        self.run_installer("codex", success=False)
        self.assertTrue((self.codex / "config.toml").is_symlink())
        self.assertEqual(outside.read_text(), 'model = "outside"')

    def test_real_preferences_exclude_routing_and_auth(self):
        for name in ["claude", "codex"]:
            shutil.rmtree(self.repo / name)
            shutil.copytree(SOURCE / name, self.repo / name)
        self.existing()
        self.run_installer()
        cc = self.json(self.claude / "settings.json")
        self.assertEqual(cc["model"], "deepseek/deepseek-flash[1m]")
        self.assertEqual(cc["effortLevel"], "max")
        self.assertIs(cc["idleCompaction"], False)
        self.assertEqual(self.toml()["model"], "codex/gpt-6-astra")
        self.assert_untouched()
        self.run_installer("-r")
        self.assert_untouched()

    def test_default_install_refuses_existing_external_resources(self):
        self.existing()
        original = (self.claude / "settings.json").read_bytes()
        super().run_installer(success=False)
        self.assertEqual((self.claude / "settings.json").read_bytes(), original)
        self.assertFalse((self.claude / ".agent-kit").exists())
        self.assert_untouched()

    def test_single_dash_gateway_option_is_accepted(self):
        super().run_installer("-gateway", "magpie", "claude")
        self.assertEqual(self.json(self.claude / "settings.json")["theme"], "dark")
        self.assertFalse((self.claude / "CLAUDE.md").exists())
        self.assertFalse((self.claude / "skills").exists())


class ResourcesTest(ReadyInstallerTest):
    def existing_copies(self):
        self.claude.mkdir(exist_ok=True)
        shutil.copy2(self.repo / "instructions.md", self.claude / "CLAUDE.md")
        shutil.copytree(self.repo / "skills", self.claude / "skills")
        shutil.copytree(self.repo / "vendor/skills/vendor-example", self.claude / "skills/vendor-example")

    def test_native_login_and_existing_copies_survive_install_and_restore(self):
        self.existing_copies()
        self.write(self.claude / "settings.json", '{"model":"fable[1m]","idleCompaction":true}')
        self.write(self.claude / ".credentials.json", '{"claudeAiOauth":{"accessToken":"test-token"}}')
        self.write(self.claude / ".agent-kit/managed", "CLAUDE.md\nskills/example\n")
        self.run_installer("claude")
        settings = self.json(self.claude / "settings.json")
        self.assertEqual(settings["model"], "fable[1m]")
        self.assertIs(settings["idleCompaction"], False)
        self.assertNotIn("ANTHROPIC_BASE_URL", settings["env"])
        self.assertNotIn("ANTHROPIC_AUTH_TOKEN", settings["env"])
        self.assertFalse(self.codex.exists())
        for target, source in [("CLAUDE.md", "instructions.md"), ("skills/example", "skills/example"),
                               ("skills/vendor-example", "vendor/skills/vendor-example")]:
            self.assertTrue((self.claude / target).is_symlink())
            self.assertEqual((self.claude / target).resolve(), self.repo / source)
        # Repository edits reach the clients without a copy or another install.
        self.write(self.repo / "instructions.md", "# Updated instructions\n")
        self.write(self.repo / "skills/example/scripts/check.sh", "echo updated\n")
        self.assertEqual((self.claude / "CLAUDE.md").read_text(), "# Updated instructions\n")
        self.assertEqual((self.claude / "skills/example/scripts/check.sh").read_text(), "echo updated\n")
        self.run_installer("claude")
        self.run_installer("-r", "claude")
        self.assertFalse((self.claude / "CLAUDE.md").is_symlink())
        self.assertFalse((self.claude / "skills/example").is_symlink())
        self.assertEqual((self.claude / "CLAUDE.md").read_text(), "# Shared instructions\n")
        self.assertEqual((self.claude / "skills/example/scripts/check.sh").read_text(), "echo example\n")
        self.assertEqual(self.json(self.claude / "settings.json"), {"model": "fable[1m]", "idleCompaction": True})
        self.assertEqual((self.claude / ".credentials.json").read_text(), '{"claudeAiOauth":{"accessToken":"test-token"}}')
        self.assertEqual((self.claude / ".agent-kit/managed").read_text(), "CLAUDE.md\nskills/example\n")
        self.assertFalse((self.claude / ".agent-kit/resource-backups").exists())

    def test_new_resources_and_removed_skills_with_separate_preference_restore(self):
        self.write(self.codex / "skills/other/SKILL.md", "# Unmanaged skill\n")
        self.run_installer()
        self.assertEqual((self.codex / "AGENTS.md").resolve(), self.repo / "instructions.md")
        shutil.rmtree(self.repo / "vendor/skills/vendor-example")
        self.run_installer()
        for client in [self.claude, self.codex]:
            self.assertFalse((client / "skills/vendor-example").is_symlink())
        self.run_installer("-r", "--gateway", "magpie")
        self.assertTrue((self.codex / "AGENTS.md").is_symlink())
        self.run_installer("-r")
        for client, name in [(self.claude, "CLAUDE.md"), (self.codex, "AGENTS.md")]:
            self.assertFalse((client / name).is_symlink())
            self.assertFalse((client / "skills/example").is_symlink())
            self.assertFalse((client / ".agent-kit/resources.json").exists())
        self.assertEqual((self.codex / "skills/other/SKILL.md").read_text(), "# Unmanaged skill\n")

    def test_resource_conflicts_stop_before_preferences_are_written(self):
        for conflict in ["instructions", "support-file", "foreign-link", "linked-parent"]:
            with self.subTest(conflict=conflict):
                if self.claude.exists():
                    shutil.rmtree(self.claude)
                self.write(self.claude / "settings.json", '{"theme":"light"}')
                if conflict == "instructions":
                    self.write(self.claude / "CLAUDE.md", "<!-- magpie:begin -->\n# Shared instructions\n")
                elif conflict == "support-file":
                    shutil.copytree(self.repo / "skills", self.claude / "skills")
                    self.write(self.claude / "skills/example/scripts/check.sh", "echo local-edit\n")
                elif conflict == "foreign-link":
                    self.write(self.root / "magpie/example/SKILL.md", "# Example\n")
                    (self.claude / "skills").mkdir()
                    (self.claude / "skills/example").symlink_to(self.root / "magpie/example", target_is_directory=True)
                else:
                    (self.claude / "skills").symlink_to(self.repo / "skills", target_is_directory=True)
                self.run_installer(success=False)
                self.assertEqual((self.claude / "settings.json").read_text(), '{"theme":"light"}')
                self.assertFalse((self.claude / ".agent-kit").exists())
                self.assertFalse(self.codex.exists())

    def test_rollback_preserves_a_manually_replaced_resource(self):
        self.existing_copies()
        self.run_installer("claude")
        (self.claude / "CLAUDE.md").unlink()
        self.write(self.claude / "CLAUDE.md", "# My later instructions\n")
        self.run_installer("claude", success=False)
        self.run_installer("-r", "claude")
        self.assertEqual((self.claude / "CLAUDE.md").read_text(), "# My later instructions\n")
        self.assertFalse((self.claude / ".agent-kit/resources.json").exists())

    def test_reinstall_after_moving_the_repository_relinks_resources(self):
        self.run_installer("claude")
        destination = self.root / "moved repo"
        self.repo.rename(destination)
        self.repo = destination
        self.run_installer("claude")
        self.assertEqual((self.claude / "CLAUDE.md").resolve(), self.repo / "instructions.md")
        self.assertEqual((self.claude / "skills/example").resolve(), self.repo / "skills/example")
        self.run_installer("-r", "claude")
        self.assertFalse((self.claude / "CLAUDE.md").is_symlink())

    @unittest.skipIf(os.geteuid() == 0, "requires ordinary user filesystem permissions")
    def test_failed_relink_can_restore_original_copies(self):
        self.existing_copies()
        self.run_installer("claude")
        destination = self.root / "moved repo"
        self.repo.rename(destination)
        self.repo = destination
        (self.claude / "skills").chmod(0o500)
        try:
            self.run_installer("claude", success=False)
        finally:
            (self.claude / "skills").chmod(0o700)
        self.run_installer("-r", "claude")
        self.assertFalse((self.claude / "CLAUDE.md").is_symlink())
        self.assertFalse((self.claude / "skills/example").is_symlink())
        self.assertEqual((self.claude / "skills/example/scripts/check.sh").read_text(), "echo example\n")

    def test_duplicate_skill_names_are_rejected_before_writing(self):
        self.write(self.repo / "vendor/skills/example/SKILL.md", "# Other example\n")
        self.run_installer(success=False)
        self.assertFalse(self.claude.exists())
        self.assertFalse(self.codex.exists())

    def test_gateway_handoff_requires_releasing_native_resources(self):
        self.run_installer("claude")
        self.write(self.claude / "settings.json", '{"theme":"light"}')
        self.run_installer("claude", "--gateway", "magpie", success=False)
        self.assertEqual((self.claude / "settings.json").read_text(), '{"theme":"light"}')
        self.assertTrue((self.claude / "CLAUDE.md").is_symlink())
        self.run_installer("-r", "claude")
        self.run_installer("claude", "--gateway", "magpie")
        self.assertFalse((self.claude / "CLAUDE.md").exists())
        self.assertFalse((self.claude / ".agent-kit/resources.json").exists())

    def test_unsupported_gateway_is_rejected_before_writing(self):
        self.run_installer("--gateway", "ccswitch", success=False)
        self.assertFalse(self.claude.exists())
        self.assertFalse(self.codex.exists())

    def test_default_install_updates_real_preferences_and_preserves_native_logins(self):
        for client in ["claude", "codex"]:
            shutil.rmtree(self.repo / client)
            shutil.copytree(SOURCE / client, self.repo / client)
        self.existing_copies()
        self.write(self.claude / "settings.json", '{"model":"opus","theme":"light",'
                   '"idleCompaction":true,"permissions":{"defaultMode":"default"}}')
        self.write(self.claude / "plugins/claude-hud/config.json", '{}')
        self.write(self.codex / "config.toml", 'model_provider = "openai"\nmodel_context_window = 1000000\n'
                   'cli_auth_credentials_store = "file"\napproval_policy = "on-request"\n')
        logins = {
            self.claude / ".credentials.json": '{"claudeAiOauth":{"accessToken":"claude-login"}}',
            self.codex / "auth.json": '{"auth_mode":"chatgpt","tokens":{"access_token":"codex-login"}}',
        }
        for path, text in logins.items():
            self.write(path, text)
        self.environment["CODEXMANAGER_API_KEY"] = "not-selected"
        self.run_installer()
        settings = self.json(self.claude / "settings.json")
        patch = self.json(self.repo / "claude/settings.json")
        for key in ["theme", "idleCompaction", "permissions"]:
            self.assertEqual(settings[key], patch[key])
        self.assertEqual(settings["model"], "opus")
        self.assertNotIn("ANTHROPIC_BASE_URL", settings["env"])
        self.assertNotIn("ANTHROPIC_AUTH_TOKEN", settings["env"])
        self.assertEqual(self.json(self.claude / "plugins/claude-hud/config.json"),
                         self.json(self.repo / "claude/plugins/claude-hud/config.json"))
        self.assertEqual(self.toml()["approval_policy"], "never")
        self.assertEqual(self.toml()["model_provider"], "openai")
        self.assertEqual(self.toml()["model_context_window"], 1000000)
        self.assertEqual(self.toml()["cli_auth_credentials_store"], "file")
        for path, text in logins.items():
            self.assertEqual(path.read_bytes(), text.encode())
        for client, name in [(self.claude, "CLAUDE.md"), (self.codex, "AGENTS.md")]:
            self.assertTrue((client / name).is_symlink())
            self.assertTrue((client / "skills/example").is_symlink())


class CodexManagerTest(ReadyInstallerTest):
    def run_cm(self, *args, success=True):
        return self.run_installer("codex", "--gateway", "codexmanager", *args, success=success)

    def native_login(self):
        self.write(self.codex / "config.toml", 'model = "gpt-6-astra"\nmodel_context_window = 872000\n')
        text = '{ "auth_mode": "chatgpt", "tokens": { "access_token": "original-login" } }\r\n'
        path = self.codex / "auth.json"
        path.write_bytes(text.encode())
        path.chmod(0o640)
        return path.read_bytes()

    def test_install_rotation_and_restore_keep_first_native_login(self):
        original = self.native_login()
        self.run_cm("--cm-key", "first-key")
        config = self.toml()
        self.assertEqual(config["model"], "gpt-6-astra")
        self.assertEqual(config["model_context_window"], 872000)
        self.assertEqual(config["model_provider"], "cm")
        self.assertEqual(config["cli_auth_credentials_store"], "file")
        self.assertEqual(config["model_providers"]["cm"], {
            "name": "cm", "base_url": "http://localhost:48760/v1",
            "wire_api": "responses", "requires_openai_auth": True})
        self.assertEqual(self.json(self.codex / "auth.json"), {
            "auth_mode": "apikey", "OPENAI_API_KEY": "first-key"})
        self.assertEqual((self.codex / "auth.json").stat().st_mode & 0o777, 0o600)
        state = self.codex / ".agent-kit/gateways/codexmanager.json"
        self.assertEqual(state.stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.codex / "AGENTS.md").resolve(), self.repo / "instructions.md")
        self.assertTrue((self.codex / "skills/vendor-example").is_symlink())
        self.assertFalse(self.claude.exists())
        self.run_cm("--cm-key", "second-key")
        self.run_cm()  # Reuses the selected CM provider's key.
        self.assertEqual(self.json(self.codex / "auth.json")["OPENAI_API_KEY"], "second-key")
        self.run_cm("-r")
        self.assertEqual((self.codex / "auth.json").read_bytes(), original)
        self.assertEqual((self.codex / "auth.json").stat().st_mode & 0o777, 0o640)
        self.assertNotIn("model_provider", self.toml())
        self.assertEqual(self.toml()["model_context_window"], 872000)
        self.assertFalse(state.exists())
        self.assertFalse((self.codex / "AGENTS.md").is_symlink())

    def test_environment_key_and_fresh_install_restore(self):
        self.environment["CODEXMANAGER_API_KEY"] = "environment-key"
        self.run_cm()
        self.assertEqual(self.json(self.codex / "auth.json")["OPENAI_API_KEY"], "environment-key")
        del self.environment["CODEXMANAGER_API_KEY"]
        self.run_cm("-r")
        self.assertFalse((self.codex / "auth.json").exists())
        self.assertFalse((self.codex / "config.toml").exists())

    def test_missing_key_does_not_replace_a_native_or_official_api_login(self):
        original = self.native_login()
        for auth in [original, b'{"auth_mode":"apikey","OPENAI_API_KEY":"official-api-key"}']:
            (self.codex / "auth.json").write_bytes(auth)
            self.run_cm(success=False)
            self.assertEqual((self.codex / "auth.json").read_bytes(), auth)
            self.assertNotIn("model_provider", self.toml())
            self.assertFalse((self.codex / ".agent-kit").exists())

    def test_active_profile_and_conflicting_gateway_settings_are_restored(self):
        original_auth = self.native_login()
        self.write(self.codex / "config.toml", '''model = "gpt-6-astra"
model_provider = "magpie"
profile = "work"
openai_base_url = "http://127.0.0.1:3425/backend-api/codex"
model_catalog_json = "/catalog/top.json"
[model_providers.cm]
name = "previous cm"
env_key = "PREVIOUS_KEY"
[model_providers.other]
base_url = "https://example.com/v1"
[profiles.work]
model_provider = "magpie"
cli_auth_credentials_store = "keyring"
model_catalog_json = "/catalog/work.json"
[profiles.other]
model_provider = "other"
''')
        original_config = self.toml().unwrap()
        self.run_cm("--cm-key", "profile-key")
        config = self.toml()
        self.assertEqual(config["profiles"]["work"]["model_provider"], "cm")
        self.assertEqual(config["cli_auth_credentials_store"], "file")
        self.assertNotIn("cli_auth_credentials_store", config["profiles"]["work"])
        self.assertNotIn("model_catalog_json", config["profiles"]["work"])
        self.assertNotIn("model_catalog_json", config)
        self.assertNotIn("openai_base_url", config)
        self.assertNotIn("env_key", config["model_providers"]["cm"])
        self.assertEqual(config["profiles"]["other"]["model_provider"], "other")
        self.run_cm("-r")
        self.assertEqual(self.toml().unwrap(), original_config)
        self.assertEqual((self.codex / "auth.json").read_bytes(), original_auth)

    def test_later_login_is_kept_during_restore(self):
        self.native_login()
        self.run_cm("--cm-key", "cm-key")
        replacement = '{"auth_mode":"chatgpt","tokens":{"access_token":"new-login"}}'
        self.write(self.codex / "auth.json", replacement)
        self.run_cm("-r")
        self.assertEqual((self.codex / "auth.json").read_text(), replacement)
        self.assertFalse((self.codex / ".agent-kit/gateways/codexmanager.json").exists())

    def test_reuse_requires_the_cm_endpoint_and_file_authentication(self):
        self.write(self.codex / "auth.json", '{"auth_mode":"apikey","OPENAI_API_KEY":"unrelated-key"}')
        for endpoint, extra in [("https://example.com/v1", ""),
                                ("http://localhost:48760/v1", 'env_key = "OTHER_KEY"\n')]:
            self.write(self.codex / "config.toml", 'model_provider = "cm"\ncli_auth_credentials_store = "file"\n'
                       '[model_providers.cm]\nrequires_openai_auth = true\nbase_url = "' + endpoint + '"\n' + extra)
            self.run_cm(success=False)
            self.assertEqual(self.json(self.codex / "auth.json")["OPENAI_API_KEY"], "unrelated-key")
            self.assertFalse((self.codex / ".agent-kit").exists())

    def test_another_mode_requires_restoring_codexmanager_first(self):
        self.run_cm("--cm-key", "cm-key")
        auth = (self.codex / "auth.json").read_bytes()
        for args in [("codex",), ("codex", "--gateway", "magpie"), ("-r", "codex")]:
            self.run_installer(*args, success=False)
            self.assertEqual((self.codex / "auth.json").read_bytes(), auth)
            self.assertEqual(self.toml()["model_provider"], "cm")
        self.run_cm("-r")
        self.run_installer("codex")
        self.assertFalse((self.codex / "auth.json").exists())

    def test_conflicts_and_wrong_client_do_not_write_credentials(self):
        self.native_login()
        self.write(self.codex / "AGENTS.md", "# Local instructions\n")
        original = (self.codex / "auth.json").read_bytes()
        result = self.run_cm("--cm-key", "do-not-print-this-key", success=False)
        self.assertNotIn("do-not-print-this-key", result.stdout + result.stderr)
        self.assertEqual((self.codex / "auth.json").read_bytes(), original)
        self.assertFalse((self.codex / ".agent-kit").exists())
        result = self.run_installer("claude", "--gateway", "codexmanager",
                                    "--cm-key", "do-not-print-this-key", success=False)
        self.assertFalse(self.claude.exists())
        self.assertNotIn("do-not-print-this-key", result.stdout + result.stderr)
        result = self.run_installer("--gateway", "magpie", "--cm-key", "do-not-print-this-key", success=False)
        self.assertNotIn("do-not-print-this-key", result.stdout + result.stderr)

    @unittest.skipIf(os.geteuid() == 0, "requires ordinary user filesystem permissions")
    def test_failed_key_rotation_can_restore_original_login(self):
        original = self.native_login()
        self.run_cm("--cm-key", "first-key")
        self.codex.chmod(0o500)
        try:
            self.run_cm("--cm-key", "next-key", success=False)
        finally:
            self.codex.chmod(0o700)
        self.assertEqual(self.json(self.codex / "auth.json")["OPENAI_API_KEY"], "first-key")
        self.run_cm("-r")
        self.assertEqual((self.codex / "auth.json").read_bytes(), original)


class BootstrapTest(InstallerTest):
    @classmethod
    def setUpClass(cls):
        cls.wheels = tempfile.TemporaryDirectory(prefix="agent-kit wheels ")
        cls.addClassCleanup(cls.wheels.cleanup)
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith("PIP_")}
        environment["PIP_CONFIG_FILE"] = os.devnull
        result = subprocess.run([
            sys.executable, "-m", "pip", "download", "--disable-pip-version-check",
            "--no-cache-dir", "--no-deps", "--only-binary=:all:",
            "--index-url", "https://pypi.org/simple",
            "--dest", cls.wheels.name, "-r", str(SOURCE / "requirements.txt"),
        ], env=environment, capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise RuntimeError("Could not prepare dependency wheel:\n" + result.stdout + result.stderr)

    def setUp(self):
        super().setUp()
        self.environment = {key: value for key, value in self.environment.items()
                            if not key.startswith("PIP_")}
        self.environment.update(PIP_CONFIG_FILE=os.devnull, PIP_NO_INDEX="1",
                                PIP_NO_CACHE_DIR="1",
                                PIP_FIND_LINKS=Path(self.wheels.name).resolve().as_uri())
        self.python = self.repo / ".venv/bin/python"

    def create_environment(self):
        subprocess.run([sys.executable, "-m", "venv", str(self.repo / ".venv")],
                       check=True, capture_output=True, text=True)

    def test_first_run_creates_environment_and_ready_environment_is_reused(self):
        self.run_installer("codex")
        self.assertTrue(self.python.is_file())
        self.assertEqual(self.toml()["approval_policy"], "never")
        metadata = self.repo / ".venv/pyvenv.cfg"
        created = metadata.stat().st_mtime_ns
        # A complete environment must work even without pip or a wheel source.
        for package in (self.repo / ".venv/lib").glob("python*/site-packages/pip"):
            shutil.rmtree(package)
        del self.environment["PIP_FIND_LINKS"]
        self.run_installer("codex")
        self.assertEqual(metadata.stat().st_mtime_ns, created)
        self.assertEqual(self.toml()["approval_policy"], "never")

    def test_existing_environment_gets_missing_dependency(self):
        self.create_environment()
        metadata = self.repo / ".venv/pyvenv.cfg"
        created = metadata.stat().st_mtime_ns
        self.run_installer("codex")
        self.assertEqual(metadata.stat().st_mtime_ns, created)
        self.assertEqual(self.toml()["approval_policy"], "never")

    def test_download_failure_leaves_client_config_untouched(self):
        self.write(self.codex / "config.toml", 'model = "magpie/test"\n')
        original = (self.codex / "config.toml").read_bytes()
        del self.environment["PIP_FIND_LINKS"]
        self.run_installer(success=False)
        self.assertEqual((self.codex / "config.toml").read_bytes(), original)
        self.assertFalse((self.codex / ".agent-kit").exists())
        self.assertFalse(self.claude.exists())

    def test_changed_requirement_must_be_satisfied_before_applying(self):
        self.run_installer("codex")
        self.write(self.codex / "config.toml", 'model = "magpie/new"\n')
        original = (self.codex / "config.toml").read_bytes()
        self.write(self.repo / "requirements.txt", "tomlkit==0.0.0\n")
        self.run_installer("codex", success=False)
        self.assertEqual((self.codex / "config.toml").read_bytes(), original)


if __name__ == "__main__":
    unittest.main(verbosity=2)
