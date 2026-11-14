# Registering the three GitHub Apps

fwf 1.0 acts on GitHub as three App identities so that authorship, review and
authority are attributable and GitHub's own rule "an author cannot approve
their own PR" does the work prose markers used to do. Apps can be registered
on a personal account or an organization; no paid plan is needed. Registering
all three takes about ten minutes.

Do this three times, at https://github.com/settings/apps/new
(Settings → Developer settings → GitHub Apps → New GitHub App; for an
organization, the same path under the organization's settings). App names are
global on GitHub, so if `fwf-impl` is taken, choose any name; fwf finds each App
by its id, not its name.

| App name | Purpose | Repository permissions |
|---|---|---|
| `fwf-impl` | opens draft PRs, pushes `impl/*` branches (via the supervisor) | Contents: Read & write · Pull requests: Read & write · Issues: Read · Metadata: Read · Workflows: Read & write |
| `fwf-qa` | posts the PR review anchored to `commit_id` | Contents: Read · Pull requests: Read & write · Issues: Read · Metadata: Read |
| `fwf-ops` | labels (un-gate), check-runs (gate verdicts), fast-forward pushes to `staging`/`main`, releases | Contents: Read & write · Issues: Read & write · Pull requests: Read & write · Checks: Read & write · Commit statuses: Read & write · Metadata: Read · Workflows: Read & write (see below) |

For each:
1. **GitHub App name**: as above. **Homepage URL**: any URL, e.g. your repository's.
2. **Webhook**: untick *Active*. The supervisor polls with ETags and needs no public endpoint.
3. **Permissions**: set the repository permissions from the table. Leave Account permissions empty.
4. **Where can this GitHub App be installed?**: *Only on this account*.
5. Click **Create GitHub App**. Note the **App ID** shown at the top of the app page.
6. Scroll to **Private keys → Generate a private key**. A `.pem` downloads. Move it:
   ```
   mkdir -p ~/.fwf/keys && chmod 700 ~/.fwf/keys
   mv ~/Downloads/fwf-impl.*.private-key.pem ~/.fwf/keys/fwf-impl.pem && chmod 600 ~/.fwf/keys/fwf-impl.pem
   ```
   (same for `fwf-qa`, `fwf-ops`).
7. In the left menu click **Install App** → *Install* next to your account → **Only select repositories** → pick the repository the floor will work (add more later, one per floor). The URL after installing ends in `/installations/<id>`; note that **installation id**.

Then write `~/.fwf/apps.toml` (or the path in `FWF_APPS_TOML`). `fwf doctor` mints a test token per App from it:

```toml
[impl]
app_id = 123456
installation_id = 78901234
key = "~/.fwf/keys/fwf-impl.pem"

[qa]
app_id = 123457
installation_id = 78901235
key = "~/.fwf/keys/fwf-qa.pem"

[ops]
app_id = 123458
installation_id = 78901236
key = "~/.fwf/keys/fwf-ops.pem"
```

Notes
- **Workflows: Read & write** belongs on `impl`, which writes every seat branch upstream (the slice and the rework both mint that push token from `impl`, never from `ops` — #636), and on `ops`, which fast-forwards `staging`/`main`. Grant it on any repo whose tickets may touch `.github/workflows/`; without it GitHub refuses the write itself, after the seat has already done the work:
  ```
  ! [remote rejected] impl1/issue-583-thin-slice -> impl1/issue-583-thin-slice
    (refusing to allow a GitHub App to create or update workflow .github/workflows/ci.yml without `workflows` permission)
  ```
  That is a permission to grant, not a verdict on the code: the supervisor keeps the claim and the branch, records the write as still owed, retries it every tick and never re-runs the cycle (#602). `fwf status` carries it under **needs you** until it lands. Grant it in the App's settings on GitHub, then **re-accept it on the installation** — GitHub asks the account owner to review the new permission, and an installation keeps the permissions it was accepted with. `fwf doctor` probes `impl` and `ops` for it and prints a `WARNING no workflows: write` line when it is missing; a repo with no workflows of its own can ignore that warning.
- Installation tokens live one hour; the supervisor mints them on demand. Seats never receive a GitHub token of any kind; they push only to the local mirror, and the supervisor makes every GitHub write.
- On a private repository on the Free plan the Apps work the same. Only branch protection and required checks are unavailable there, which is one reason promotion is a supervisor step (`fwf promote`) rather than a GitHub rule.
- To see what an App can reach, `fwf probe impl /repos/OWNER/NAME` GETs any API path with that App's token and prints the status.
