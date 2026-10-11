"""Exercise scanner behavior using synthetic, temporary files."""

import contextlib
import io
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from security.repo_guard import main, scan_repository


SCANNER = Path(__file__).resolve().parents[1] / "security" / "repo_guard.py"


class RepoGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def write(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return path

    def run_cli(self, root=None):
        return subprocess.run(
            [sys.executable, str(SCANNER), str(root if root is not None else self.root)],
            capture_output=True, text=True, check=False,
        )

    def test_clean_repository_and_empty_quoted_values(self):
        self.write("app.py", "print('healthy')\n")
        self.write(".env.example", "pass" + "word=''\napi_" + 'key=""\n')
        result = scan_repository(self.root)
        self.assertEqual(result.exit_code, 0)
        self.assertEqual(result.findings, [])
        self.assertEqual(result.errors, [])
        self.assertEqual(self.run_cli().returncode, 0)

    def test_quoted_unquoted_and_yaml_json_assignments(self):
        cases = [
            ("pass" + "word", ' = "synthetic-value"'),
            ("PASS" + "WORD", "=synthetic-value"),
            ("pass" + "wd", ": 'synthetic-value'"),
            ("api_" + "key", ": synthetic-value"),
            ("api-" + "key", ' = "synthetic-value"'),
            ("api" + "key", '": "synthetic-value"}'),
        ]
        for index, (name, assignment) in enumerate(cases):
            with self.subTest(name=name):
                path = self.write(f"case-{index}.yaml", name + assignment + "\n")
                result = scan_repository(path.parent)
                self.assertTrue(any(f.file == path.name and f.line == 1 for f in result.findings))
        self.assertEqual(len(scan_repository(self.root).findings), len(cases))

    def test_dotenv_names_are_scanned(self):
        for name in (".env", ".env.local", ".env.production", ".env.example"):
            self.write(name, "api_" + "key=synthetic-value\n")
        result = scan_repository(self.root)
        self.assertEqual({f.file for f in result.findings}, {
            ".env", ".env.local", ".env.production", ".env.example",
        })

    def test_aws_and_debug_rules_and_line_numbers(self):
        fake_key = "AK" + "IA" + "A" * 16
        temporary_key = "AS" + "IA" + "B" * 16
        self.write("settings.yml", "# config\nDE" + "BUG: true\n" + fake_key + "\n" + temporary_key + "\n")
        result = scan_repository(self.root)
        self.assertEqual([(f.line, f.issue) for f in result.findings], [
            (2, "Debug mode enabled"), (3, "Possible AWS access key"),
            (4, "Possible AWS access key"),
        ])

    def test_boundary_checks_do_not_match_similar_names(self):
        self.write("settings.py", "notpass" + "word='value'\nDE" + "BUG=False\nDE" + "BUG=trueish\n")
        self.assertEqual(scan_repository(self.root).exit_code, 0)

    def test_obvious_environment_reads_are_not_embedded_values(self):
        self.write("settings.py", "pass" + "word=os.getenv('APP_SECRET')\napi_" + "key=os.environ['APP_SECRET']\n")
        self.write("config.yaml", "pass" + "word: ${APP_SECRET}\n")
        self.assertEqual(scan_repository(self.root).exit_code, 0)

    def test_supported_configuration_types_and_special_filenames(self):
        names = ["settings.tf", "settings.tfvars", "settings.toml", "settings.JSON", "Dockerfile", "Makefile"]
        for name in names:
            self.write(name, "DE" + "BUG=true\n")
        self.write("asset.png", "DE" + "BUG=true\n")
        self.assertEqual({f.file for f in scan_repository(self.root).findings}, set(names))

    def test_ignored_trees_are_pruned_but_tests_and_docs_are_scanned(self):
        ignored = (".git", ".venv", "venv", "__pycache__", "node_modules", ".pytest_cache", ".mypy_cache", ".ruff_cache")
        for directory in ignored:
            self.write(f"{directory}/nested/settings.py", "DE" + "BUG=true\n")
        self.write("tests/example.py", "DE" + "BUG=true\n")
        self.write("docs/example.md", "DE" + "BUG=true\n")
        real_walk = os.walk
        visited = []

        def recording_walk(*args, **kwargs):
            for entry in real_walk(*args, **kwargs):
                visited.append(Path(entry[0]))
                yield entry

        with patch("security.repo_guard.os.walk", side_effect=recording_walk):
            result = scan_repository(self.root)
        self.assertEqual({f.file for f in result.findings}, {"tests/example.py", "docs/example.md"})
        self.assertFalse(any(path.relative_to(self.root).parts[0] in ignored for path in visited if path != self.root))

    def test_symlink_files_directories_and_cycles_are_skipped(self):
        with tempfile.TemporaryDirectory() as outside:
            external = Path(outside)
            (external / "secret.env").write_text("DE" + "BUG=true\n", encoding="utf-8")
            (self.root / "external").symlink_to(external, target_is_directory=True)
            (self.root / ".env").symlink_to(external / "secret.env")
            (self.root / "loop").symlink_to(self.root, target_is_directory=True)
            (self.root / "broken.py").symlink_to(external / "missing.py")
            self.assertEqual(scan_repository(self.root).exit_code, 0)

    def test_invalid_roots_fail_with_exit_two(self):
        file_root = self.write("file.txt", "hello\n")
        for root in (self.root / "missing", file_root):
            with self.subTest(root=root):
                self.assertEqual(scan_repository(root).exit_code, 2)
                process = self.run_cli(root)
                self.assertEqual(process.returncode, 2)
                self.assertIn("ERROR:", process.stderr)

    def test_invalid_utf8_fails_even_when_findings_exist(self):
        (self.root / "bad.py").write_bytes(b"\xff")
        self.write("settings.py", "DE" + "BUG=true\n")
        result = scan_repository(self.root)
        self.assertEqual(result.exit_code, 2)
        self.assertEqual(len(result.findings), 1)
        self.assertIn("bad.py", result.errors[0])
        self.assertEqual(self.run_cli().returncode, 2)

    def test_read_permission_failure_is_reported(self):
        path = self.write("settings.py", "print('healthy')\n")
        with patch.object(Path, "read_text", side_effect=PermissionError("denied")):
            result = scan_repository(self.root)
        self.assertEqual(result.exit_code, 2)
        self.assertIn(path.name, result.errors[0])
        self.assertIn("PermissionError", result.errors[0])

    def test_traversal_failure_is_reported(self):
        blocked = self.root / "blocked"
        blocked.mkdir()

        def failed_walk(root, *, topdown, onerror, followlinks):
            onerror(PermissionError(13, "denied", str(blocked)))
            return iter(())

        with patch("security.repo_guard.os.walk", side_effect=failed_walk):
            result = scan_repository(self.root)
        self.assertEqual(result.exit_code, 2)
        self.assertIn("blocked", result.errors[0])

    def test_cli_redacts_values_and_uses_sorted_relative_paths(self):
        synthetic_value = "synthetic-private-value"
        self.write("z/config.py", "pass" + "word='" + synthetic_value + "'\n")
        self.write("a.py", "api_" + "key=" + synthetic_value + "\n")
        process = self.run_cli()
        self.assertEqual(process.returncode, 1)
        self.assertEqual(process.stdout.splitlines()[:2], [
            "a.py:1: Possible API key", "z/config.py:1: Possible password",
        ])
        self.assertNotIn(synthetic_value, process.stdout + process.stderr)
        self.assertNotIn(str(self.root), process.stdout)

    def test_default_root_is_current_directory(self):
        self.write("settings.py", "DE" + "BUG=true\n")
        with contextlib.chdir(self.root), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(main([]), 1)


if __name__ == "__main__":
    unittest.main()
