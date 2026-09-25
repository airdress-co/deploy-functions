# Deploy Airdress functions

A GitHub Action that deploys the Airdress functions a push changed: it
publishes each changed function's source, signed by a key this repository's
CI holds, promotes it to serving on your operator, waits until it loads, and
commits the new version back into the function's manifest.

Every decision is made by the [airdress CLI](https://airdress.co)
(`airdress fn deploy --ci`). The Action installs a pinned, digest-checked
release of it, hands it the secrets as private files, runs it, commits what
it wrote back, and writes a job summary. It contains no deploy logic of its
own, so anything it does you can do by hand with the same CLI.

- [What CI can and cannot do](#what-ci-can-and-cannot-do)
- [One-time setup](#one-time-setup)
- [The workflow](#the-workflow)
- [Inputs and outputs](#inputs-and-outputs)
- [Write-back](#write-back)
- [Outcomes](#outcomes)
- [When a run fails with `source_base_stale`](#when-a-run-fails-with-source_base_stale)
- [Full redeploy and rollback](#full-redeploy-and-rollback)
- [The repository layout](#the-repository-layout)
- [Safety](#safety)
- [The CLI this Action runs](#the-cli-this-action-runs)

## What CI can and cannot do

CI **can**:

- publish a new version of a function that already exists, signed by its
  own machine key, and promote it to serving;
- deploy only the functions whose `function.json` or `src/` changed since
  the previous push, or every function (`all: true`);
- deploy one source directory to several operators, each with its own
  manifest;
- roll back, by `git revert`.

CI **cannot**, by design:

- **create a function.** The owner creates it once, from a workstation. A
  run for a function the operator does not have stops with
  `function_missing`.
- **change a grant, the configuration or the signer set.** A promote
  changes `spec.source.version` and nothing else. Editing `capabilities`,
  `config` or `signers` in `function.yaml` and pushing deploys nothing:
  a change to the manifest alone is not a deploy. Those changes are the
  owner's to apply.
- **override a newer deploy.** If the function was promoted by someone
  else since the version the manifest names, the run stops with
  `source_base_stale` and is never retried
  ([below](#when-a-run-fails-with-source_base_stale)).
- **deploy anything a person has not merged.** The documented workflow runs
  on `push` to your deploying branch only ([Safety](#safety)).

## One-time setup

You need the `airdress` CLI on your workstation, signed in as the owner of
the airdress, and a shell on the operator's host for the
`airdress-operator` commands. Do this once per repository, and step 5 once
per function.

### 1. Make a source-signing key for CI

```sh
airdress fn keygen --out ci-signing.key
```

It writes a `0600` file holding the seed (64 hex characters) and prints
`pubkey=<hex>` and `fingerprint=SHA256:…`. The seed becomes the
`AIRDRESS_FUNCTION_SIGNING_KEY` secret.

### 2. Enroll a machine for CI, and approve it by fingerprint

On any machine with the operator binary:

```sh
airdress-operator machine enroll \
    --operator https://<your operator's FQDN> \
    --key ci-machine.key \
    --name "github: <owner>/<repo>"
```

It prints a user code and the key's fingerprint, and waits. On the
operator's host, the owner compares the fingerprint and approves:

```sh
airdress-operator machines approve <USER-CODE> --fingerprint SHA256:<as printed>
```

The enroll command then writes `ci-machine.key` (the machine key) and
`ci-machine.key.json` (its enrollment record, holding the machine's id as
`machine_id`). They become the `AIRDRESS_MACHINE_KEY` and
`AIRDRESS_MACHINE_ENROLLMENT` secrets.

An approval lasts a limited time (180 days unless the operator is
configured otherwise). The CLI warns in every run's log from 14 days
before, and after it lapses every run stops with
`machine_authorization_expired`. Renew it with
`airdress-operator machine reauth --key ci-machine.key` and a new approval
by the owner; the machine keeps its id, key and grants.

### 3. Register the signing key as the machine's source key

On the operator's host, with the public key and fingerprint from step 1:

```sh
airdress-operator machines source-key add <machine-id> \
    --key <pubkey hex> --fingerprint SHA256:<from keygen>
```

From now on, source signed with that key counts as signed by the machine.

### 4. Create each function, from your workstation

CI never creates a function. Deploy it once as the owner, from the
directory in your repository:

```sh
airdress fn deploy functions/relay
```

This shows the manifest it will apply, asks once, and writes it into the
directory as `function.yaml`: the grant, the configuration, the signer set
(your workstation key) and `spec.source.version`, the version now serving.

### 5. Grant the machine, narrowly, and add it to the signer set

For **each** function CI deploys, on the operator's host:

```sh
airdress-operator grants create --principal <machine-id> \
    --kind Function --resource relay --actions Publish,Promote,ReadStatus
```

Grant exactly these three actions on the named function. Never grant
`Apply`: it could rewrite the function's grant and its signer set, which
is the one thing that keeps a compromised CI from widening what the
function may do. Never grant on `*` when you mean one function.

Then, from your workstation, add the machine to the function's signer set:

```sh
airdress fn signers add relay --machine <machine-id>
```

That is its own owner apply, shown before it is sent. Your workstation key
stays a member, so the function can still be deployed from your editor.

Now make the committed `function.yaml` say the same, because CI reads the
signer set from the manifest in git and checks it is a member before it
sends anything:

```yaml
spec:
  source:
    version: "sha256:…"
    signers:
      - key: "<your workstation key>"
      - machine: "<machine-id>"
```

### 6. Commit, add the workflow, store the secrets

Commit each function directory with its `function.yaml`, and the workflow
below. In the repository's settings, add three **secrets** (better: in an
environment, see [Safety](#safety)):

| Secret | Contents |
| --- | --- |
| `AIRDRESS_MACHINE_KEY` | the whole of `ci-machine.key` |
| `AIRDRESS_MACHINE_ENROLLMENT` | the whole of `ci-machine.key.json` |
| `AIRDRESS_FUNCTION_SIGNING_KEY` | the whole of `ci-signing.key` |

and optionally one **variable**, `AIRDRESS_SIGNER_MACHINE`, the machine id.
Then delete your local copies of the key files.

## The workflow

```yaml
name: deploy functions

on:
  push:
    branches: [main]
    paths: ["functions/**", "airdress.functions.yaml"]
  workflow_dispatch:
    inputs:
      all: { type: boolean, default: false }

concurrency:
  group: airdress-functions-${{ github.ref }}
  cancel-in-progress: false

permissions:
  contents: write

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: functions
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0
      - uses: airdress-co/deploy-functions@<full commit SHA>
        with:
          operator: https://<your operator's FQDN>
          machine-key: ${{ secrets.AIRDRESS_MACHINE_KEY }}
          machine-enrollment: ${{ secrets.AIRDRESS_MACHINE_ENROLLMENT }}
          signing-key: ${{ secrets.AIRDRESS_FUNCTION_SIGNING_KEY }}
          signer-machine: ${{ vars.AIRDRESS_SIGNER_MACHINE }}
          all: ${{ inputs.all || false }}
```

- `fetch-depth: 0` is required: the CLI compares the push's previous head
  with this one to find what changed, and fetches the branch head before
  publishing.
- `concurrency` with `cancel-in-progress: false` runs deploys one after
  another and never stops one halfway. When two pushes race anyway, the
  older run sees the newer commit touching the same function and yields
  with `superseded`.
- `contents: write` lets the Action push the write-back commit.

Complete, working layouts are in [`examples/`](examples/): one function,
and a monorepo deploying one directory to two operators.

## Inputs and outputs

| Input | Required | Default | Meaning |
| --- | --- | --- | --- |
| `operator` | no | | The operator, `https://<fqdn>` or the FQDN. Optional when the map file names one for every function. |
| `map` | no | `airdress.functions.yaml` | The map file. Without one, function directories are discovered. |
| `machine-key` | **yes** | | The machine key. Pass a secret. |
| `machine-enrollment` | **yes** | | The machine's enrollment record. Pass a secret. |
| `signing-key` | **yes** | | The source-signing seed. Pass a secret. |
| `signer-machine` | no | the enrolled machine | The machine id the manifests list as `{ machine: <id> }`. |
| `write-back` | no | `commit` | `commit`, `pull-request` or `off` ([Write-back](#write-back)). |
| `base` | no | the push's previous head | Deploy only functions changed since this commit. With no base (a manual run), every function is deployed. |
| `all` | no | `false` | Deploy every function, changed or not. |
| `plan` | no | `false` | Check and dry-run only: nothing is published, promoted or written. |
| `branch` | no | the triggering branch | The branch whose head decides each base version, and that write-back commits to. |
| `working-directory` | no | `.` | The checkout, when it is not the workspace root. |
| `token` | no | `github.token` | Opens the pull request in `pull-request` mode. |
| `cli-version` | no | pinned per release | The CLI release to run. It must be listed in [`cli-digests.txt`](cli-digests.txt). |

| Output | Meaning |
| --- | --- |
| `deployed` | JSON: `[{function, operator, previous, version, outcome}]`, one object per function, in the CLI's order. |

The job summary has one row per function: function, operator, previous
version, new version, outcome, and the time it took to load; below it,
what the CLI said about any function that did not deploy.

A run fails when any function did not deploy, after the functions that
did have been written back, so one broken function does not leave the
others' manifests behind.

## Write-back

After a promote, the CLI rewrites one line of the function's manifest,
`spec.source.version`, keeping every other byte (comments, order, quoting).
That line is the next deploy's base, so it has to reach the branch.

- **`commit`** (default): one commit per function,
  `functions: serve <version> for <name>`, as `github-actions[bot]`, pushed
  to the branch. If the push is rejected because the branch moved, the
  Action runs `git pull --rebase` and tries once more. A second failure
  fails the run with `write_back_failed`, printing the file, the version
  now serving, and the line to commit by hand.
- **`pull-request`**: the same commits on a new branch, and a pull request
  to the deploying branch. Use it when the branch is protected. Merge it
  before the next deploy of those functions: until it is merged, the next
  run reads the old version as its base and is refused as stale. The
  repository must allow GitHub Actions to create pull requests
  (Settings → Actions → General) and the job needs
  `pull-requests: write`. A pull request opened with the workflow's
  token starts no workflow run of its own, so your checks will not run on
  it.
- **`off`**: the lines are printed and nothing is committed. The next
  deploy is refused as stale until someone commits them.

**It does not loop.** A push made with the workflow's `GITHUB_TOKEN`
starts no new workflow run. If you check out with a personal access token
or an app token instead, the write-back push *does* start a run; that run
finds only a manifest changed and deploys nothing, but it is a wasted run.
Keep the default token.

**A protected branch** that the workflow's token may not push to makes
`commit` fail with `write_back_failed`. Use `pull-request`, or allow the
push.

## Outcomes

Each function ends with one outcome, in the summary and in the `deployed`
output.

| Outcome | Meaning | The run |
| --- | --- | --- |
| `deployed` | Published, promoted, and loaded. | passes |
| `unchanged` | This exact tree already serves, for instance because an earlier run's promote landed and its write-back was lost. The manifest is written back if it lagged. | passes |
| `skipped` | Nothing under its `function.json` or `src/` changed. | passes |
| `superseded` | A newer commit on the branch changes this function; that commit's run deploys it. | passes |
| `planned` | `plan: true`: what a deploy would do. | passes |
| `source_base_stale` | Someone else promoted a version git does not know. [See below.](#when-a-run-fails-with-source_base_stale) | fails |
| `signer_not_this_client` | This machine is not in the function's signer set. The message lists the members. Repeat [step 5](#5-grant-the-machine-narrowly-and-add-it-to-the-signer-set). | fails |
| `function_missing` | The operator has no such function, and CI never creates one. Do [step 4](#4-create-each-function-from-your-workstation). | fails |
| `machine_authorization_expired` | The machine's approval lapsed. Run `airdress-operator machine reauth` and have the owner approve again. | fails |
| `layout_invalid` | The map file or a manifest is malformed; the message names the file and line. Nothing was sent. | fails |
| `check_failed` | The operator's check refused the source; each problem is listed with its file, line and column. Refusals from the operator can also appear under their own codes. | fails |
| `not_loaded_in_time`, `load_failed` | Promoted, but the new version did not load. It is written back, because it is what the function now names. | fails |
| `write_back_failed` | Serving, but the manifest line could not be written or pushed. The line to commit is printed. | fails |

Other stop codes the CLI can give are listed, with the action for each, in
its log output. A refusal from the operator is passed through with its own
code and message.

## When a run fails with `source_base_stale`

The manifest in git says the function serves version A, but the operator
serves B: someone promoted B from somewhere else, usually the owner
deploying from their editor. The CLI says who deployed B and when, and
the run stops. **It is never retried**, because deploying A's successor on
top of B would silently undo B.

The fix is a person's: bring that change into git. Commit the tree that
was deployed as B, and set `spec.source.version` in `function.yaml` to B.
The next run publishes that same tree, gets B back, and has nothing to
promote. Deploying from an editor that works inside this repository's
checkout keeps the two aligned on its own, because it writes the manifest
line back too.

## Full redeploy and rollback

- **Full redeploy.** Run the workflow by hand with `all` set
  (`workflow_dispatch`). Every function is checked; the ones already
  serving their tree end `unchanged`, and any manifest that lagged behind
  its operator is written back. This is the recovery after a lost
  write-back or a restored operator.
- **Rollback.** `git revert` the change and push. The reverted tree
  publishes to the version the operator already holds, and the promote
  moves the function back to it.

## The repository layout

A function directory:

```text
functions/relay/
  function.json    the author's request: signed and published
  src/…            the code: signed and published
  function.yaml    the owner's manifest: never signed, never published
  README.md, tsconfig.json, …   ignored
```

Only `function.json` and the regular files under `src/` are published.
A symbolic link under `src/` is refused.

**Without a map file**, every directory holding a `function.json` whose
`runtime` is `js-source/v1` together with a `function.yaml` is a function
(`.git` and `node_modules` are skipped); a directory with no
`function.yaml` is skipped with a note. The operator then comes from the
`operator` input.

**With a map file**, `airdress.functions.yaml` at the repository root:

```yaml
layout: 1                           # required; the format's version
operator: https://prod.operator.example   # default for entries naming none
functions:
  - path: functions/relay           # required; relative to the root
  - path: functions/digest
    manifest: deploy/prod/digest.yaml     # default: function.yaml in path
    operator: https://prod.operator.example
  - path: functions/digest
    manifest: deploy/staging/digest.yaml
    operator: https://staging.operator.example
```

- `layout` must be `1`. `functions` lists at least one entry.
- `path` is the function directory. `manifest` is the Function manifest,
  relative to the root, defaulting to `function.yaml` in the directory.
  `operator` is an FQDN or an `https://` URL.
- One directory may appear several times, with a different manifest and
  operator each; each (manifest, operator) pair appears once.
- Function names come from each manifest's `metadata.name`.
- A malformed map file stops the run before anything is sent, naming the
  line. `airdress fn layout-schema` prints its JSON Schema, for your editor.

## Safety

- **Never use `pull_request_target`.** It runs with your secrets on code
  from a fork. With this Action that means anyone can sign and deploy a
  function as your CI.
- **Do not deploy from `pull_request`.** Deploy what has been merged,
  from `push` to the deploying branch. Use `plan: true` if you want a
  pull request to show what would change, and give that job no secrets it
  could deploy with.
- **Use an environment for a human gate.** Put the three secrets in a
  GitHub environment with required reviewers, and name it in the job
  (`environment: functions`). Then every deploy waits for a person, and no
  other job can read the keys.
- **Grant narrowly.** `Publish`, `Promote` and `ReadStatus`, on each named
  function, and nothing else. A leaked CI key can then deploy new code to
  those functions within the grant and signer set the owner applied, and
  cannot widen either.
- **Pin this Action by commit SHA**, as in the workflow above, and read a
  release before you move to it.
- The secrets are written to `0600` files in a private directory under
  the runner's temporary directory, masked in the log, passed to the CLI
  as file paths (never as arguments), and removed at the end of the job.

## The CLI this Action runs

The Action downloads the CLI from
`https://downloads.airdress.co/airdress-cli/<version>/` and checks it
against the SHA-256 in this repository's
[`cli-digests.txt`](cli-digests.txt), never against anything served beside
the binary. A digest mismatch, or a version or platform with no line
there, stops the run before the binary is executed. Each release of this
Action pins a CLI release as the `cli-version` default. Linux (x64 and
arm64) and macOS runners are supported; this repository's CI runs on
Linux x64.

To reproduce a run locally, from the repository root, with the same files:

```sh
airdress fn deploy --ci --since <previous head> --output json \
    --machine-key ci-machine.key --signing-key ci-signing.key \
    --operator-url https://<your operator's FQDN>
```

## License

[MIT](LICENSE)
