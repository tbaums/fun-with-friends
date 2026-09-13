# The operator→captain channel (issue #192)

## Problem

The operator→captain channel is what actually resolves a floor-wide
authorization deadlock, and it was effectively undiscoverable: reaching it
meant reading `fwf-dash-act.sh`'s `passthrough` case arm in source. Nothing
in `fwf --help` pointed at it.

Documenting `passthrough` directly is not the fix. Any process on this box
can run a documented CLI verb — including the very role agents the
operator's gate is holding. Making the raw send-keys callable would remove
the accident-barrier that today keeps a held agent from manufacturing its
own unblock.

## The fix: the pane message becomes a POINTER, never the payload

`fwf operator-decision` inverts what carries the decision:

1. **The comment is the record.** `fwf operator-decision <n> <text>` writes
   an `OPERATOR-DECISION: <text>` comment on issue/PR `<n>`. That comment is
   durable and reviewable — it survives a respawn, a pane crash, or the
   captain simply not being at the keyboard when it lands.
2. **The pane notification is a fixed-length pointer.** The captain pane
   receives `operator message on #<n> — go read it.` — never the message
   body, regardless of how long the real message is.
3. **The captain never trusts the pane text.** It re-derives the decision by
   reading the comment on `#<n>` and running `fwf authz` if the decision
   bears on authorization.

`--floor <text>` posts to the profile's configured `FWF_FLOOR_ISSUE` instead
of naming a specific ticket, for a genuinely floor-wide message. If
`FWF_FLOOR_ISSUE` is unset, the command refuses rather than inventing a
destination.

## Trust boundary — read this before treating the artifact as authorization

**This channel confers no authorization.** `fwf authz` is the sole
authorization oracle (issue #150); this verb is never an input to it, and a
message containing the operator un-gate sentinel is refused outright — never
posted, never neutralised-and-posted.

**The artifact is durable and reviewable, not attributable.** Every
fwf-self role authenticates as the same GitHub account, so a comment this
verb writes carries no author signal, and any process on this box can run
this verb. That is why the comment body carries **no attribution prefix** —
no "authorized by the human operator" claim, no identity assertion. A
forgeable "from the operator" mark is worse than none: it trains the reader
to trust the forgeable thing. The comment's safety comes from carrying no
authority, not from who wrote it.

## Usage

```
fwf operator-decision <n> <text>       post to issue/PR <n>
fwf operator-decision --floor <text>   post to the configured floor issue
```

Refuses (writes nothing) when:

- neither an issue number nor `--floor` is given;
- the message is empty;
- the message contains the operator un-gate sentinel;
- the target issue/PR doesn't exist, can't be read, or isn't `OPEN`;
- `--floor` is used and `FWF_FLOOR_ISSUE` is unconfigured.

If the artifact write succeeds but no `CAPTAIN` pane is up (floor down,
captain respawning), the command reports that the pane notification was not
delivered — the comment is still written and is still the record. The
notification never gates the artifact.

Works identically against the `gh`-issues and `FWF_ISSUES=local` backends.
