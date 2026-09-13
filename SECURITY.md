# Security

fwf runs a software factory on a GitHub repository: one supervisor process
performs every write to GitHub, and the agent sessions ("seats") that do the
work hold no credentials at all. This page describes that boundary, so you can
judge what a compromised or misbehaving seat could actually do, and how to
report a problem.

## Reporting a problem

Email **security@\<domain\>** with what you found and how to reproduce it.

This is a solo-maintained project. There is no bug bounty and no payment of any
kind. Please do not open a public issue for anything that looks exploitable —
email first, and give me a reasonable window to fix it before disclosing.

Supported: the latest release. Older tags do not get backported fixes.

## Seats never hold a GitHub token

A seat is a Claude Code session in a tmux pane. It is woken with one job, it
writes one JSON verdict, and it stops. It is given no GitHub token, of any
scope.

The only git remote a seat has is a **bare mirror on the same machine**, cloned
over a `file://` URL. A seat that goes wrong — or is made to go wrong by content
it read in an issue body — can push a bad branch to that local mirror, and that
is the whole of the damage. It cannot reach GitHub to push, comment, label,
review, merge, or release.

Everything a seat "does" on GitHub is actually the supervisor reading that
seat's verdict as data and deciding whether to act on it. A malformed or
hostile verdict is a refusal, recorded in the run record; it is never a write.

## The three identities

The supervisor acts as three GitHub Apps, each holding the smallest permission
set its job needs. Tokens are minted on demand, live one hour, and never leave
the supervisor process.

| Identity | What it does | Repository permissions |
|---|---|---|
| `fwf-impl` | opens draft PRs, pushes `impl/*` branches | Contents: Read · Pull requests: Read & write · Issues: Read · Metadata: Read |
| `fwf-qa` | posts the PR review, anchored to an exact `commit_id` | Contents: Read · Pull requests: Read & write · Issues: Read · Metadata: Read |
| `fwf-ops` | labels (un-gate), check-runs (gate verdicts), fast-forward pushes to `staging`/`main`, releases | Contents: Read & write · Issues: Read & write · Pull requests: Read & write · Checks: Read & write · Commit statuses: Read & write · Metadata: Read |

What that separation buys, concretely:

- **The identity that opens a PR cannot approve it.** GitHub's own rule that an
  author cannot approve their own pull request does the enforcing, not a
  convention in a prompt.
- **Neither `fwf-impl` nor `fwf-qa` can write to a branch.** Both are
  `Contents: Read`. They cannot push to `staging` or `main`, cannot merge,
  cannot cut a release, and cannot change a label to un-gate an issue.
- **`fwf-ops` is the only identity that can merge**, and it refuses unless an
  `APPROVED` review by someone other than the author sits at the exact head
  being merged, the head matches the fence the job was built on, and the checks
  on that head have completed. Any of those missing is a recorded refusal, not
  a merge.
- **No identity has Account permissions**, and each is installed on selected
  repositories only.

## Trusting the repository's own settings

Two things are GitHub-side settings rather than code in this repo, so audit
them there if you are evaluating the model: branch protection on `main`
(fast-forward from `staging` only), and the App installations' repository
scope. `.github/branch-policy.json` is the committed source of truth for
required status checks; drift between it and live protection settings is
reported as a red on the dash.

## Untrusted input

Issue and pull-request text is untrusted input. It reaches a seat inside a
rendered prompt, and a seat acting on instructions hidden in that text is a
realistic failure mode rather than a hypothetical one. The design does not try
to prevent a seat from being persuaded; it makes being persuaded cheap, by
giving the seat nothing to act with but a local mirror and a verdict file.

If you find a way for repository content to cause a write to GitHub that the
supervisor's checks would not otherwise allow, that is the bug worth emailing
about.
