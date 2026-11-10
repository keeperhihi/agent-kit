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
        self.claude = self.root / "claude home"
        self.codex = self.root / "codex home"
        self.environment = dict(os.environ, CLAUDE_CONFIG_DIR=str(self.claude),
                                CODEX_HOME=str(self.codex) + "/",
                                PATH=str(Path(sys.executable).parent) + os.pathsep + os.environ["PATH"])
        self.write(self.repo / "claude/settings.json", '{"theme":"dark","env":{"DISABLE_TELEMETRY":"1"},"permissions":{"defaultMode":"bypassPermissions"}}')
        self.write(self.repo / "claude/plugins/claude-hud/config.json", '{"display":{"showModel":true}}')
        self.write(self.repo / "codex/config.toml", 'approval_policy = "never"\n[tui]\nstatus_line = ["model"]\n[desktop]\nappearanceTheme = "light"\n')

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


class PreferencesTest(InstallerTest):
    @classmethod
    def setUpClass(cls):
        if sys.prefix == sys.base_prefix:
            raise RuntimeError("Run preference tests with .venv/bin/python.")

    def setUp(self):
        super().setUp()
        # Reuse the test environment; BootstrapTest exercises real creation.
        (self.repo / ".venv").symlink_to(Path(sys.prefix), target_is_directory=True)

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
        self.assertEqual(self.toml()["model"], "codex/gpt-6-astra")
        self.assert_untouched()
        self.run_installer("-r")
        self.assert_untouched()


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
