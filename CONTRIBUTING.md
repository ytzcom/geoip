# Contributing

Thanks for your interest in improving the GeoIP Database Updater! This project is
a self-hostable pipeline — anyone can run it with their own MaxMind, IP2Location
and AWS credentials. Contributions of all kinds are welcome: bug fixes, new CLI
features, deployment recipes, and documentation.

## Ways to contribute

- **Report a bug or request a feature** — open a [GitHub issue](https://github.com/ytzcom/geoip/issues) with steps to reproduce or a clear description.
- **Improve the docs** — the root `README.md` is generated from a template inside
  [`github-actions/update-readme.sh`](github-actions/update-readme.sh); edit the
  template (not just `README.md`) or the weekly job will overwrite your change.
- **Send a pull request** — see the workflow below.

For where everything lives, see the **Repository structure** table in the
[README](README.md).

## Development setup

You don't need provider accounts to work on most of the code — only to run the
full download pipeline. To validate local database files, no API key is required:

```bash
# Validate existing .mmdb / .BIN files
./cli/geoip-update.sh --validate-only --directory /path/to/geoip --verbose
```

To exercise the download/upload scripts you'll need the relevant credentials
(`MAXMIND_ACCOUNT_ID`, `MAXMIND_LICENSE_KEY`, `IP2LOCATION_TOKEN`, AWS keys and
`S3_BUCKET`). See the [README](README.md) and
[`.github/workflows/README.md`](.github/workflows/README.md) for details.

## Pull request workflow

1. **Fork** the repository and create a topic branch off `main`:
   `fix/…`, `feat/…`, `docs/…`, `ci/…`.
2. Keep the change **focused** — one logical change per PR. Match the existing
   code style; don't reformat unrelated code.
3. Write commit messages using [Conventional Commits](https://www.conventionalcommits.org/):
   `type(scope): summary` — e.g. `fix(cli): resume interrupted downloads`,
   `docs(readme): clarify setup`. Common types: `feat`, `fix`, `docs`, `ci`,
   `refactor`, `security`.
4. If you change CLI behavior or scripts, validate locally (see above) and update
   the relevant README.
5. Open a PR describing **what** changed and **why**. Make sure the CI checks pass.
6. PRs are squash-merged with the PR number appended to the subject.

## Security

**Do not** report security vulnerabilities in public issues or pull requests.
Follow the process in [`docs/SECURITY.md`](docs/SECURITY.md). Never commit real
credentials — secrets belong in GitHub repository secrets/variables, and `.env`,
`*.tfvars` and database files are gitignored.

## License

By contributing, you agree that your contributions are licensed under the
project's [MIT License](LICENSE). Note the GeoIP databases themselves are covered
by their providers' separate licenses, not by this repository's license.
