# dash render/golden snapshots

Plain-text goldens for the dash's `ratatui::backend::TestBackend` render tests
(`src/main.rs`, `#[cfg(test)] mod tests`, the `golden_*` and `render_level_*`
tests near the end of the file — issue #54).

Each golden is the exact character grid rendered at a fixed `Rect` from a
static, hand-built `Dashboard` fixture (`golden_fixture()` in `main.rs`) — no
timestamps, live provenance, or wall-clock data, so the same test always
produces the same golden on every run and every machine.

A golden captures **layout**: content, wrapping, and truncation. It does
**not** encode per-cell color/style — the two known styling regressions this
issue exists to guard (#50 blockquote contrast, #51 header template name) are
pinned by separate explicit style assertions in the `render_level_*` tests
that read `Cell::fg`/`Cell::symbol` straight out of the rendered buffer. That
split means a blind re-bless of a full-buffer golden can't silently
reintroduce either regression — the style assertions run independently of the
text comparison.

## Regenerating a golden

When a change intentionally alters layout/content, re-bless the affected
golden(s) and review the diff like any other change:

```sh
cd dash
UPDATE_GOLDEN=1 cargo test golden_header_shows_profile_template_and_provenance
# or, to re-bless every golden at once:
UPDATE_GOLDEN=1 cargo test golden_
git diff tests/goldens/
```

`UPDATE_GOLDEN=1` makes the test write the freshly rendered buffer to its
`.txt` file and pass, instead of comparing against the stored one. Always
inspect the resulting diff before committing — a golden that changed for a
reason you didn't expect is exactly the regression these tests exist to catch.
