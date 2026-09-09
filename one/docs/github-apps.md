# Registering the three GitHub Apps (T-02) — Jamie's ten minutes

fwf 1.0 acts on GitHub as three App identities so that authorship, review and
authority are attributable and GitHub's own rule "an author cannot approve
their own PR" does the work prose markers used to do. Apps register on a
personal account; no organization or paid plan is needed.

Do this three times, at https://github.com/settings/apps/new
(Settings → Developer settings → GitHub Apps → New GitHub App):

| App name | Purpose | Repository permissions |
|---|---|---|
| `fwf-impl` | opens draft PRs, pushes `impl/*` branches (via the supervisor) | Contents: Read · Pull requests: Read & write · Issues: Read · Metadata: Read |
| `fwf-qa` | posts the PR review anchored to `commit_id` | Contents: Read · Pull requests: Read & write · Issues: Read · Metadata: Read |
| `fwf-ops` | labels (un-gate), check-runs (gate verdicts), fast-forward pushes to `staging`/`main`, releases | Contents: Read & write · Issues: Read & write · Pull requests: Read & write · Checks: Read & write · Commit statuses: Read & write · Metadata: Read |

For each:
1. **GitHub App name**: as above. **Homepage URL**: `https://github.com/tbaums/fun-with-friends`.
2. **Webhook**: untick *Active* (the supervisor polls with ETags; no public endpoint exists on the Mac).
3. **Permissions**: set the repository permissions from the table. Leave Account permissions empty.
4. **Where can this GitHub App be installed?**: *Only on this account*.
5. Click **Create GitHub App**. Note the **App ID** shown at the top of the app page.
6. Scroll to **Private keys → Generate a private key**. A `.pem` downloads. Move it:
   ```
   mkdir -p ~/.fwf/keys && chmod 700 ~/.fwf/keys
   mv ~/Downloads/fwf-impl.*.private-key.pem ~/.fwf/keys/fwf-impl.pem && chmod 600 ~/.fwf/keys/fwf-impl.pem
   ```
   (same for `fwf-qa`, `fwf-ops`).
7. In the left menu click **Install App** → *Install* next to your account → **Only select repositories** → pick `fun-with-friends` (add `transom` and `baton` later, per repo). The URL after installing ends in `/installations/<id>`; note that **installation id**.

Then write `~/.fwf/apps.toml` (the supervisor's `fwf doctor` will mint a test token per App from it):

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
- Installation tokens live one hour; the supervisor mints them on demand. Seats never see the `ops` token, and in 1.0 they receive only read-scoped tokens (Contents: Read) and push to the local mirror.
- On `transom` (private, Free plan) the Apps work the same; only branch protection / required checks are unavailable there, which is why promotion stays a supervisor step.
- Week-0 test 1 (can an App be an assignee?) runs the moment `fwf-impl` is installed:
  `gh api repos/tbaums/fun-with-friends/assignees/fwf-impl%5Bbot%5D -i | head -1` → `204` means yes, `404` means the `claim/<n>` ref fallback.
