# Test fixtures

## `LinkedInAggregateAnalytics-redacted.xlsx`

A real LinkedIn **Aggregate Analytics** export, redacted.

Captured from `linkedin.com/analytics/creator/content → Export`, then redacted by
**allowlist**: a string survives only if the parser reads it (`Impressions`,
`Members reached`, `Date`, `Engagements`, `New followers`, the
`Total followers on …` header) or is a date. Numbers become synthetic ones.
Everything else — including `docProps` — becomes `redacted`.

An allowlist because the first attempt was a denylist, replacing digits, dates
and the literal account name. It let **49 LinkedIn post URLs** through, with
slugs naming the posts, plus the audience-location rows and the account name in
`docProps/core.xml`. Redacting what you expect to be present is not the same as
keeping only what you need.

Structure is untouched: sheet names, sheet order, cell types, styles and the
`<si>` layout are byte-for-byte as LinkedIn wrote them.

That distinction is the point. The bug in #53/#55 was not about values — it was
that **every cell in a real export is `t="s"`, a shared string, including the
numbers**. A fixture written by hand from reading the parser would never have
that shape, which is why the parser shipped unable to read any real file while
its tests passed.

Dates are deliberately *not* redacted. They are structure here, not identity:
the `M/d/yyyy` spelling is what `LinkedInXLSXParser.linkedInDate` has to parse — deliberately not `ExportDates`, which every file importer shares, and it was confirmed
against the export's own filename range (`2026-08-22_2026-09-04` against rows
`8/22/2026 … 9/4/2026`).
