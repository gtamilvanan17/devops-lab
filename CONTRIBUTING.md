# Contributing

Thanks for helping improve DevOps Lab.

## Ground rules
- Be kind. See the [Code of Conduct](CODE_OF_CONDUCT.md).
- Keep `lab.sh` readable: short functions and a plain-English comment above anything non-obvious.
- Config files (`kind-config.yaml`, `*-values.yaml`, `jenkins/*`, `guestbook-app.yaml`) are **generated** by `lab.sh`. Change them inside `write_configs`, then run `./lab.sh configs`.

## Workflow
1. Fork and create a branch: `git checkout -b feat/my-change`.
2. Make your change and update [CHANGELOG.md](CHANGELOG.md) under `Unreleased`.
3. Check the script:
   ```bash
   bash -n lab.sh
   shellcheck lab.sh      # brew install shellcheck
   ```
4. If you can, test on a real run: `./lab.sh destroy && ./lab.sh up`.
5. Open a pull request and describe what you tested.

## Commit messages
Use short imperative lines, for example `feat: add local registry` or `fix: wait for ArgoCD before login`.

## Reporting bugs
Open an issue with your macOS version, Docker runtime, and the output of `lab status`.
