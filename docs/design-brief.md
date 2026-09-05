# social-brain — macOS desktop app spec

Design brief for Claude Design. This is the visual/interaction spec, not an engineering plan.

**Status:** The codebase already exists (`catehstn/social-brain-app`, Swift/SwiftUI, macOS 14+, SQLite/GRDB, Keychain, Swift Charts). This spec is for a **design-forward restart** — polished visual mockups of the existing screens, plus a rethink where the current shape isn't landing. The tech is not the constraint; the design is.

## What it is

A single-user macOS app for one person's weekly social-media analytics loop. Ground-up Swift rewrite of an earlier Python CLI. It (a) pulls data from ~13 platforms on a schedule, (b) surfaces what matters via a Feed of typed cards, (c) charts trends per-platform, per-time-range, (d) assembles a Claude-shaped prompt the user pastes into claude.ai for the weekly report. **The app does not call the Claude API** — it prepares the prompt and hands off.

One user, one machine, offline-first, SQLite is the source of truth.

## Who uses it

Me (Cate). Weekly cadence, usually Saturday or Sunday morning with coffee. Also: mid-week ad-hoc checks ("did that post do anything?"). Sometimes a spike or a mention wakes me up mid-week.

## Tone / aesthetic

- **macOS-native**: SF Pro / SF Mono, standard toolbar, `NavigationSplitView` sidebar, quiet chrome. Not Electron-looking, not web-styled.
- **Data-dense but calm.** Weekly-newspaper vibe, not a real-time trading terminal. Big numbers, small annotations, room to breathe.
- **Warm neutral with one accent.** Not corporate. Small typography for metadata, larger for the story of the week.
- **Dark mode first**, light mode complete.
- No animation for its own sake. Progress bars during collect are fine. Card expand/collapse can be smooth.

## The primitives to model

- **Platform** — one of the sources below. Each has: authType (API key / OAuth / file export / no auth), configured-or-not, per-instance credentials, last-collected-at, freshness.
- **Instance** — a platform can have multiple accounts (e.g. two Mastodon handles). Default instance is named `default`; extras are user-labelled.
- **Snapshot** — one platform-instance's decoded metrics at a point in time. Compared against previous snapshots to detect spikes and high-reach signals.
- **Collection run** — a run over selected platforms with a `since` window.
- **Feed card** — a typed summary surfaced to the user. Types: `recentPost`, `metricHighlight`, `upcomingEvent`, `staleReminder`, `spikeAlert`, `highReach`. Each has a 280-char snippet + an expand action + a tap-navigation target.
- **Analytics goal** — the user's stated priority (chosen during onboarding). Displayed as a badge in the sidebar. Colours the prompt.
- **Prompt** — a Claude-shaped text blob assembled from the latest run.

**Platforms (13):**
- **API key:** Buttondown · GoatCounter · Calendly · Amazon KDP · Google Search Console · Buffer
- **OAuth / token:** Mastodon · Bluesky · Jetpack (WordPress.com)
- **File export (drag-drop):** LinkedIn (XLSX) · O'Reilly (email) · Substack (CSV)
- **No auth:** Hacker News
- **Also collects:** Mentions synthesis (aggregates HN / GSC / mastodon / bluesky mention data)

## Sidebar (top-level navigation)

Fixed order — this is what the sidebar shows:

1. **Run** — the collect action screen
2. **Feed** — a stream of typed cards summarising the latest run
3. **Dashboard** — charts, per-instance, per-time-range
4. **History** — past collection runs, drill-in
5. **Platforms** — configure sources

Below the sidebar, pinned: a small **Goal badge** showing the user's chosen analytics goal.

Settings lives in the macOS Preferences window (not the sidebar). Onboarding is a first-run modal.

## Screens

### Run *(default landing)*
The collect action screen.
- Header: title + one-line explanation ("Fetch data from all configured platforms").
- Right of header: a **since** menu (Last 7 / 30 / 90 days / All time) + a big **Run** button.
- Body: live per-platform progress during a run (row per platform, ✓/✗/⋯, error text on hover). When idle, shows a summary of the last run (when, how long, which platforms succeeded/failed).
- After a successful run: a "**Prompt ready**" affordance opens a sheet with the assembled prompt, Copy button, Open-claude.ai button.

### Feed
The reason to open the app most days.
- Vertical `LazyVStack` of expandable cards. Each card:
  - Platform icon + name + instance label (if not default)
  - Card type badge (Recent Post / Metric Highlight / Spike Alert / High Reach / Upcoming Event / Stale Reminder)
  - 280-char snippet (word-boundary truncated); tap expands to full content
  - Tap-through navigates to the relevant Dashboard filter
- Empty state: "Nothing yet — run a collection to populate your feed."
- Refresh action in toolbar; also pulls automatically after a Run finishes.

Feed cards are **generated**, not hand-written — the app runs `SpikeDetector` (≥20% change between last two snapshots) and `HighReachDetector` (absolute thresholds + ≥30% relative lift) over each new snapshot. The Feed is the *"what's new that matters"* view; Dashboard is *"show me the trend."*

### Dashboard
- Toolbar: instance picker (dropdown) + time-range segmented control (Week / Month / 3 Months / All Time) + refresh button.
- Body: adaptive grid of `MetricChartView`s using Swift Charts — one card per metric series (followers, page views, engagements, etc.).
- Empty state: "No data for this range — run a collection first."

This is the chart-heavy screen. Not the home briefing.

### History
- List of past `CollectionRun`s, most-recent first: timestamp, duration, per-platform ✓/✗ counts.
- Click a run → detail: exact per-platform outcomes, retry-just-this-one, view the snapshot JSON, view the prompt that was assembled from it.
- Empty state: "No runs yet — run a collection to see history here."

### Platforms
- **Adaptive grid of cards** (mid-redesign — see `trycycle-plan.md` in the repo). Each card:
  - SF Symbol icon (accent-coloured)
  - Platform display name
  - Status: "Not set up" (secondary) or "N accounts" (with green ✓)
- Click card → **PlatformDetailView** pushed onto the nav stack:
  - Lists configured instances
  - "Set Up" (first instance) or "+ Add another *[Platform]*" (subsequent)
  - Per-instance "Edit" button → opens `PlatformCredentialSheet` modal
  - "Hide *[Platform]*" affordance (removes from grid; eye-icon toolbar reveals hidden)
- Credential sheet includes: auth-type-appropriate fields, per-platform setup URL (opens in browser), test-connection, and for file-export platforms a **drag-and-drop zone**.

### Onboarding *(first-run modal)*
4-step wizard, 560×480 window:
1. **Welcome** — what Social Brain does, one paragraph.
2. **Goal** — pick an analytics goal (predefined options + custom text). Sets the badge; feeds the prompt.
3. **Connect** — a quick tour of the three platform groups (API / OAuth / File export). Doesn't force any connections — the user goes to Platforms afterward.
4. **Ready** — confirmation, "Go to Platforms" primary action.

### Settings *(macOS Prefs window)*
- Data location (default `~/Library/Application Support/SocialBrain/`).
- Auto-refresh: on/off + time-of-day picker (uses `BGTaskScheduler`).
- Notifications: stale-export reminders (uses `UserNotifications`).
- Analytics goal (also editable here).
- Theme (System / Light / Dark).
- Reset / export data.

## Flows to design

1. **First launch → Onboarding → Platforms → connect the first source → Run → Feed populates.**
2. **Weekly Run:** one click, live per-platform progress, prompt-ready sheet, copy → open claude.ai. On return: Feed shows the new signals, Dashboard shows the extended trend.
3. **Mid-week spike:** notification fires → open app → Feed has a `spikeAlert` card at the top → tap → Dashboard filtered to that platform + short window.
4. **Platform fails during Run:** row goes red inline; hover for error; retry-just-this-one button; the rest of the run still completes.
5. **Manual drop refresh:** in Platforms → LinkedIn → drag XLSX onto the drop zone → validation → green tick with "5 posts new since last week."
6. **Hide a platform I don't use:** in Platforms → detail → "Hide" → card leaves the grid; eye-icon in toolbar to restore.

## Non-goals (skip these)

- No multi-user, no cloud sync, no login screen.
- No live streaming / real-time metrics — data updates on run, not push.
- No publishing/posting — this is read-only analytics.
- No AI chat inside the app. The Claude analysis happens on claude.ai; this app is the on-ramp and the archive.
- No mobile companion.

## What to design

Polished redesigns of the five sidebar screens (Run · Feed · Dashboard · History · Platforms) plus the Onboarding wizard. Not the Prefs window.

**Prioritise:**
- **Feed** — the marquee "reason to open this daily" screen. Cards need to feel like a real editorial surface, not a notification tray. Card-type differentiation is important without becoming cluttered.
- **Run** — the primary weekly action. Progress feedback needs to be legible at-a-glance and reassuring during the ~30-second collect. The prompt hand-off is a small screen but frequent — make it feel like a single satisfying action.
- **Platforms grid** — the setup surface. This is what the user sees on first launch after Onboarding. Card grid, SF Symbols, adaptive to window size.

**Beauty shot:**
- **Dashboard** with real-looking chart data — this is the screenshot for the app store / blog post.

Please produce artboards at **1440×900** (standard MBP screen) with `NavigationSplitView` sidebar + main-pane layout consistent across all screens. Provide light + dark mode for at least the Feed and Dashboard.

## Constraints already fixed in code (don't redesign these)

- Native macOS 14+, SwiftUI, `NavigationSplitView` topology.
- SF Symbol icons per platform (mapped in `Platform.swift`).
- Keychain for all credential storage.
- SQLite/GRDB for the analytics store.
- Swift Charts for all charting.
- `ASWebAuthenticationSession` for OAuth.
- `BGTaskScheduler` for auto-refresh, `UserNotifications` for reminders.
