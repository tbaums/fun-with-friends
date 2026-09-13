# Citing code in a spec: anchor on a token, not a bare line number (issue #370)

When a ticket, PR, or comment cites source ("`lib.sh:344`"), the citation
rots the moment the line drifts — and on this floor, lines drift fast.
Two conventions keep a citation useful after that happens.

## Anchor on a token; quote prose only where no token exists

A citation should point at something greppable near the line number: a
function/variable name, a `case` arm, a config key — or, only when no
token exists, a short phrase quoted **exactly** from the source (same
case, no ellipsis, no reflowing for readability). Verify the phrase with
a real `grep` before committing the citation, against `staging`/
`integration` — not only whatever's checked out locally.

Token anchors and prose anchors are not equally reliable. Measured
across several gated specs on this floor: three separate prose
citations broke because the quoted phrase had been wrapped across a
line break, elided with `…`, or re-cased to read better in prose — the
act of writing a *good* quotation is what breaks it as an anchor. Zero
token anchors failed the same way, because there is nothing about a
token to smooth over. A token is usually available nearby even when the
first draft of a citation didn't use one — a comment block often sits
directly above the function it documents.

This governs *new* citations. It is not a mandate to rewrite existing
correct ones — a historical quotation inside a correction-of-record
documents what a file *used to say* and must not be "fixed" into a
token, and a verified, exactly-quoted comment with no nearby token is
exactly the case prose anchors exist for.

## Verify a captured fixture against its source once, at capture time

A test whose fixture is text captured from a live issue/PR/comment
(rather than a live read of that artifact, which can change out from
under the test) must have that capture verified against its source
**at the moment of capture** — and note that it was. That moment is the
only real opportunity: after it, the source is free to move, which is
the entire reason for capturing a static fixture in the first place.
