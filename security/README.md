# RepoGuard

RepoGuard is a small Python standard-library scanner that makes a few security
checks easy to understand and run locally or in CI.

```sh
python security/repo_guard.py .
```

It reports relative file paths, line numbers and issue names. Matched credential
values are never included in output.

| Check | Coverage |
| --- | --- |
| Possible embedded credentials | Nonempty password, passwd and API-key assignments using an equals sign or colon, including quoted and unquoted values |
| AWS key identifiers | Common long-lived and temporary access-key identifier formats |
| Enabled debug settings | Case-insensitive boolean true assignments |

The scanner reads supported text files: Python, Markdown, plain text, YAML, JSON,
TOML, INI/config, shell and Terraform files; Dockerfile and Makefile; `.env` and
every `.env.*` file. Tests and documentation are scanned too. Empty quoted
credential values and obvious environment lookups are skipped.

It prunes `.git`, `.venv`, `venv`, `__pycache__`, `node_modules`, `.pytest_cache`,
`.mypy_cache` and `.ruff_cache` before traversal. Symlink files and directories
are skipped so the scan does not follow links outside the selected root.

| Exit code | Meaning |
| --- | --- |
| `0` | No findings in the scanned scope |
| `1` | At least one finding; fix it before merging |
| `2` | Invalid root, directory traversal failure or unreadable supported text; the scan is incomplete |

Read errors take precedence over findings. Text is decoded as UTF-8; malformed
supported text fails the scan instead of silently disappearing.

## Limits

These are transparent regex checks, not a complete secret detector. Comments,
examples, placeholders and variable assignments can produce false positives.
Encoded or differently named credentials, multiline values, binary files,
unsupported formats, symlink targets and Git history are outside this scope.
Files can also change during a scan; this is designed for a trusted, stable
working tree in local development and CI. Passing does not prove the repository
is secure.

Review each finding rather than adding broad directory exclusions. An exposed
credential must be revoked or rotated; removing it from the current file does
not remove it from Git history. Dependency and container-image checks belong to
separate tools in CI.

The scanner's behavior is covered by temporary-file tests, including error paths,
symlinks and CLI exit codes:

```sh
python -m unittest discover -s tests -p 'test_repo_guard.py' -v
```
