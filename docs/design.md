# Why fwf is built this way

## One supervisor, many stateless seats

fwf runs a software factory on a GitHub repository. The factory has two kinds of parts. There is one **supervisor** (`fwf run`), a small Rust program that reads the tracker, decides what should happen next, and performs every write to GitHub. And there are **seats**: Claude Code sessions sitting in tmux panes, each of which is idle until the supervisor wakes it with exactly one job, and idle again the moment it has answered.

That split is the whole design. Everything else follows from asking two questions about each responsibility: *does this need judgment, or does it need to be right every time?* Judgment goes to a seat. Being right every time goes to the supervisor.

Deciding whether an issue is well-grounded, whether a spec is complete, how to implement a change, whether a diff is correct: judgment, so a seat does it. Which issue is next, which branch a change must be built on, whether a review counts, whether a merge is allowed, whether a gate passed, what the meter says: those must be right every time, so the supervisor does them in code, with tests, and refuses loudly when a precondition fails.

## Seats are woken, never left running

The obvious way to build an agent factory is to give each agent a long-running loop: poll the tracker, claim work, do it, repeat. fwf 0.x worked that way and taught us why it is wrong. A looping agent spends most of its tokens on coordination it is bad at: reading state it does not need, re-deriving what it already knew, negotiating with siblings through comment protocols, deciding whether to keep waiting. It also drifts. A session that has been running for hours carries a context it did not choose, and its behaviour on hour six is not the behaviour you tested on hour one.

A woken seat has none of that. It receives one rendered prompt: the issue, the branch it must create, the commit it must build on, the deadline, and the exact JSON it must write back. It does the job, writes the verdict, and stops. It cannot poll, because it has nothing to poll with. It cannot coordinate, because nothing in its prompt asks it to. Its context is the job. When the supervisor wakes it again, it is a different job with a fresh prompt, and the seat's earlier work is just history in the same pane.

Idle seats cost nothing. A floor with four seats and one ticket in flight is spending on one seat.

![The supervisor cycle: poll the tracker, plan what happens next, wake one seat with one job, receive one JSON verdict, perform every GitHub write and append the result to the run record — then poll again.](img/design-cycle.svg)

## The prompts are the product

Once you remove coordination from the agent, what is left in the prompt is the role's judgment: what a good implementation is, what a review must check, what a spec must contain, what makes a ticket ready. Those are short documents, one per role per family, and they are the most valuable files in the repository. They encode what we have learned about getting good work from a model on a real codebase, and they are the part a new user should read first.

They are written as contracts, not conversations. Each names what the seat is given, what it may not do, and the one verdict shape it must return. The supervisor treats the verdict as data: an `implemented` verdict with a head sha becomes a pull request; a `blocked` verdict releases the claim; a QA verdict becomes a review under the QA identity. Nothing a seat writes is ever a write to GitHub by itself.

The wording carries scars. "Write the verdict with a real JSON serializer" is there because a seat once hand-typed JSON with unescaped quotes. "Your deadline is 12:24; a partial result beats a stall" is there because a seat parked itself behind a fifty-minute test loop. "Assert on attempt counts, not elapsed time" is there because a flake fix flaked under load. A prompt is where a lesson goes so that it is applied on every wake, not remembered by whoever is watching.

## Three narrow identities, and no tokens in the seats

The supervisor acts as three GitHub Apps: one that opens pull requests, one that reviews them, one that merges and labels. Each has the smallest permission set that job needs. A pull request opened by the implementer identity cannot be approved by it; a merge is only accepted from the ops identity, and only when a review by the QA identity sits at the exact head being merged. GitHub enforces the separation, not the prompt.

Seats never hold a GitHub token. Their only remote is a local mirror. A seat that goes wrong can push a bad branch to a mirror on the same machine, and that is the extent of the damage. This is the property that lets the factory run unattended overnight on a private repository.

## Typed merges and the fence

Every job carries a **fence**: the commit the work must be built on. The supervisor realigns the seat's worktree to the fence before waking it, records the fence in the pull request, and checks it again at merge time. A review is only an approval if it was made at the head that is being merged. A merge is only attempted if the checks on that head have completed. When any of this is not true the supervisor refuses, records the refusal in the run record, and moves on. Refusals are cheap; silent wrong merges are not.

Gates are the same idea applied to the branch. A commit on `staging` is gated by running the repository's own fast suite in a clean worktree and recording the result as a check-run. Promotion to `main` is a fast-forward that the supervisor only performs when the tip it is promoting has a recorded green gate for the suite the manifest names. Releases are cut from `main` by one script that refuses a dirty tree, a stale lock, or a version that already exists.

## The run record is the only truth

Everything the supervisor does or observes is appended to one file, `run.jsonl`, and every view of the factory (the dash, `status`, cost figures, the timeline of a pull request) is a fold over that file. There is no second database to drift, and there is no state that exists only in a pane. When something goes wrong at three in the morning, the record says which seat was woken for what, when it reported, what verdict it gave, what the supervisor did with it, and what it refused. The operator reads the record, not the panes.

## The meter is a brake, not a dashboard

The factory runs on a subscription with a session and a weekly ceiling. The supervisor reads the latest meter reading from a file the operator keeps fresh, and parks itself when the reading is stale or above the configured threshold. It does not try to be clever about cost; it tries to be impossible to run past the limit unattended. Cost per cycle is reported from the seat's own transcript as an upper bound, and the dash says so.

## What it deliberately does not do

There is no captain and no chat. The human's interface is the tracker and a handful of verbs: label an issue as gated or not, un-gate it when the spec is right, promote, release. A product decision that the PM and GV cannot settle stays gated with the question written in the issue; nobody guesses on the human's behalf. The factory does not open issues on its own initiative, does not rewrite a spec after implementation starts, and does not merge anything a human could not have merged with the same evidence.

It also does not pretend to be finished. When a seat's push is refused, when a gate is red, when a verdict is malformed, the supervisor says so in the record and in the dash's "needs you" line, and the tooling for the operator to finish the step by hand is the same tooling the supervisor uses. That is what made it possible to ship twelve tickets and a release in one afternoon on the day two new defects were found in the supervisor itself: the design assumes the operator is part of the system, and gives them a record, a refusal, and a verb.
