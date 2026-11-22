# CopilotLedger PR Receipt

Posts a branch's AI spend receipt on its pull request as one comment, and updates that comment on later pushes. The receipt comes from [gh-ledger](https://github.com/swigerb/gh-ledger), which records GitHub Copilot usage on your own machine, so the action needs no cloud service and no secrets.

## How it works

1. On your machine, check out the pull request's branch and run `gh ledger export-pr`. It writes the branch's receipt to `.github/copilot-ledger/receipts/<branch>-<hash>.md`.
2. Commit that file and push.
3. On each push, the action finds the receipt among the pull request's changed files, checks it, and posts it as one comment. Later pushes update that comment instead of adding new ones.

The receipt shows GitHub AI Credits by model, Foundry BYOK spend, local-model tokens with the cloud spend they avoided, circuit-breaker trips, and the most expensive prompt, with its data as JSON. Its totals equal the branch's row in `gh ledger branch --since all --json`. Receipts stay in the repository after the pull request merges, as a record of what each branch spent.

## Usage

Add `.github/workflows/copilot-ledger-receipt.yml` to your repository:

```yaml
name: CopilotLedger receipt

on:
  pull_request:
    types: [opened, synchronize, reopened]

permissions:
  contents: read
  pull-requests: write

concurrency:
  group: copilot-ledger-receipt-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  receipt:
    runs-on: ubuntu-latest
    steps:
      - uses: swigerb/copilot-ledger-action@v1
```

The workflow's `GITHUB_TOKEN` reads the receipt with `contents: read` and comments with `pull-requests: write`, and needs nothing else. The `concurrency` group keeps two runs for the same pull request from both adding a comment.

## Inputs

| Input | Default | Meaning |
|---|---|---|
| `github-token` | `${{ github.token }}` | Token that reads the pull request and writes the comment |
| `receipts-directory` | `.github/copilot-ledger/receipts` | Where receipts are committed; change it only if you move them |
| `comment-author` | `github-actions[bot]` | The login that owns the receipt comment; change it only when `github-token` belongs to another account |

## Outputs

| Output | Meaning |
|---|---|
| `result` | `created`, `updated`, `unchanged`, `no-receipt`, or `skipped` |
| `comment-url` | The receipt comment's URL; empty for `no-receipt` and `skipped` |

## What the action checks

- It runs only for `pull_request` events. Pull requests from forks get a read-only token, so the action skips them with a notice. Other events, including `pull_request_target`, fail.
- A receipt must be among the pull request's changed files, under `receipts-directory`, and end in `.md`. With none, the action leaves a notice and succeeds.
- A receipt must start with `<!-- copilot-ledger-receipt -->` (with no byte order mark before it), be at most 65,536 bytes of UTF-8, and hold a JSON block with `"schemaVersion": 1` and a `branch` exactly equal to the pull request's branch. gh-ledger 0.4.0 and later write such receipts. Otherwise the action fails with an error that names the file or, when no receipt is for the pull request's branch, lists the branches of the receipts it found.
- It updates the oldest comment by `comment-author` (compared case-insensitively, as GitHub logins are) that starts with `<!-- copilot-ledger-receipt -->`. It never edits anyone else's comment.

## Versions

`@v1` follows the latest v1.x release. To pin an exact release, use its full commit SHA with the version as a comment, for example `uses: swigerb/copilot-ledger-action@<commit SHA> # v1.0.0`.

## Development

The action is a composite action: `action.yml` runs `receipt.ps1` with PowerShell 7, which GitHub-hosted runners include. The tests replay the GitHub REST API offline:

```shell
pwsh -NoProfile -File tests/receipt.Tests.ps1
```

## Releasing

1. Merge the change to `main` with CI passing.
2. Create the release, for example `gh release create v1.0.1 --repo swigerb/copilot-ledger-action --target main --title v1.0.1 --generate-notes`.
3. In the browser, edit the release, select **Publish this Action to the GitHub Marketplace**, choose a category, and select **Update release**. Publishing needs two-factor authentication, and the first time, accepting the GitHub Marketplace Developer Agreement.
4. Move the major tag to the release: `git fetch --tags origin`, then `git tag -f v1 v1.0.1` and `git push -f origin v1`.

## License

MIT. See [LICENSE](LICENSE).
