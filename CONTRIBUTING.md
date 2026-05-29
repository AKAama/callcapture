# Contributing to CallCapture

Thanks for your interest in improving CallCapture! Contributions of all kinds are welcome — bug reports, fixes, features, and docs.

## Getting started

1. Read [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) for architecture, build, and test instructions.
2. Fork the repo and create a branch off `main`.
3. Make your change with tests.
4. Open a pull request.

## Development setup

```bash
# Python worker
cd python-worker
python3 -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
pytest

# macOS app
cd macos-app
swift build && swift test

# Run the whole thing in dev mode (from repo root)
./run-dev.sh
```

## Pull request guidelines

- **Tests first.** New features and bug fixes should come with tests. The
  project uses pytest (Python) and XCTest (Swift). Aim to keep the suite green.
- **Small, focused PRs.** One logical change per PR is easier to review.
- **Conventional Commits.** Use `feat:`, `fix:`, `docs:`, `refactor:`, `test:`,
  `chore:`, `perf:`, `ci:` prefixes.
- **Keep it readable.** Match the surrounding style; prefer small, focused files
  and immutable data where practical.
- **No secrets.** Never commit API keys or recordings — keys live in the macOS
  Keychain; recordings and the session DB are git-ignored.

## Reporting bugs / requesting features

Use the issue templates under **Issues → New issue**. For questions and ideas,
open a **Discussion**.

## Code of Conduct

By participating you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md).

## License

By contributing, you agree that your contributions are licensed under the
project's [AGPL-3.0](LICENSE) license.
