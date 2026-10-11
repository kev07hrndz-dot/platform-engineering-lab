"""Scan working-tree text for a few common security mistakes; never print values."""

import argparse
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path


IGNORED_DIRECTORIES = {
    ".git", ".venv", "venv", "__pycache__", "node_modules",
    ".pytest_cache", ".mypy_cache", ".ruff_cache",
}
TEXT_EXTENSIONS = {
    ".py", ".txt", ".md", ".yaml", ".yml", ".json", ".toml",
    ".ini", ".cfg", ".conf", ".sh", ".tf", ".tfvars",
}
TEXT_FILENAMES = {"Dockerfile", "Makefile"}
CREDENTIAL_PATTERN = re.compile(
    r"""\b(?P<name>password|passwd|api[_-]?key)["']?\s*[:=]\s*"""
    r"""(?P<value>"[^"]*"|'[^']*'|[^\s,#}\]]+)""",
    re.IGNORECASE,
)
AWS_KEY_PATTERN = re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")
DEBUG_PATTERN = re.compile(
    r"""\bdebug["']?\s*[:=]\s*["']?true\b""", re.IGNORECASE,
)


@dataclass(frozen=True, order=True)
class Finding:
    file: str
    line: int
    issue: str


@dataclass
class ScanResult:
    findings: list[Finding] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    @property
    def exit_code(self) -> int:
        if self.errors:
            return 2
        return 1 if self.findings else 0


def is_text_file(path: Path) -> bool:
    return (
        path.suffix.lower() in TEXT_EXTENSIONS
        or path.name in TEXT_FILENAMES
        or path.name == ".env"
        or path.name.startswith(".env.")
    )


def scan_text(content: str, relative_path: str) -> list[Finding]:
    findings = []
    for number, line in enumerate(content.splitlines(), start=1):
        for match in CREDENTIAL_PATTERN.finditer(line):
            value = match.group("value")
            if value in {"''", '""'}:
                continue
            # Obvious environment lookups are not embedded credential values.
            if value[0] not in {"'", '"'} and (
                "(" in value or value.startswith(("${", "os.environ["))
            ):
                continue
            name = match.group("name").lower()
            issue = "Possible password" if name in {"password", "passwd"} else "Possible API key"
            findings.append(Finding(relative_path, number, issue))
        if AWS_KEY_PATTERN.search(line):
            findings.append(Finding(relative_path, number, "Possible AWS access key"))
        if DEBUG_PATTERN.search(line):
            findings.append(Finding(relative_path, number, "Debug mode enabled"))
    return findings


def scan_repository(root: Path) -> ScanResult:
    result = ScanResult()
    try:
        root = root.expanduser().resolve(strict=True)
        if not root.is_dir():
            result.errors.append("Scan root must be a directory.")
            return result
    except (OSError, RuntimeError):
        result.errors.append("Scan root does not exist or cannot be accessed.")
        return result

    def traversal_error(error: OSError) -> None:
        path = Path(error.filename) if error.filename else root
        try:
            location = path.relative_to(root).as_posix()
        except ValueError:
            location = "."
        result.errors.append(f"{location}: cannot traverse directory ({type(error).__name__}).")

    for directory, dirs, files in os.walk(root, topdown=True, onerror=traversal_error, followlinks=False):
        current = Path(directory)
        # Prune excluded trees before entering them; never follow symlinks.
        dirs[:] = sorted(
            name for name in dirs
            if name not in IGNORED_DIRECTORIES and not (current / name).is_symlink()
        )
        for name in sorted(files):
            path = current / name
            if path.is_symlink() or not is_text_file(path):
                continue
            relative = path.relative_to(root).as_posix()
            try:
                content = path.read_text(encoding="utf-8")
            except (OSError, UnicodeError) as error:
                result.errors.append(f"{relative}: cannot read text ({type(error).__name__}).")
                continue
            result.findings.extend(scan_text(content, relative))

    result.findings.sort()
    result.errors.sort()
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", default=".", type=Path, help="Directory to scan (default: current directory)")
    result = scan_repository(parser.parse_args(argv).root)
    for finding in result.findings:
        print(f"{finding.file}:{finding.line}: {finding.issue}")
    for error in result.errors:
        print(f"ERROR: {error}", file=sys.stderr)
    print(f"RepoGuard: {len(result.findings)} finding(s), {len(result.errors)} error(s).")
    return result.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
