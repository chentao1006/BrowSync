# BrowSync repository instructions

These rules apply to every change in this repository.

## User-visible text and localization

- Never add a raw user-visible string to SwiftUI/AppKit UI. Use `String(localized:bundle:)` with the view's `LanguageBundle` so the in-app language setting is respected instead of only the macOS language.
- Every new or changed localization key must be present in all supported catalogs under `BrowSync/Resources`: `en`, `zh-Hans`, `de`, `es`, `fr`, `it`, `ja`, and `ko`.
- Check alerts, buttons, toggles, menu items, help text, notifications, failure messages, accessibility labels, and empty states—not just primary screen labels.
- Before handoff, search the changed UI for newly introduced string literals and verify every localization file contains each new key.
- Place a new setting inside the existing section/card for its configuration domain (for example, bookmark safety belongs under Sync Strategy). Do not insert settings at the top level merely because that is the easiest edit.
- A persisted setting control must save its value, propagate it to affected extensions/services, and invalidate stale pending state when the setting changes.

## Bookmark data-safety invariants

- Persist every browser observation as a snapshot before planning. Detect local activity by comparing a browser's newest persisted snapshot with its persisted per-target sync baseline (`sync_baseline_<source>_to_<target>`), never with an in-memory "previous/current" truth, and never treat extension callbacks as deletion authority.
- A pair baseline advances only past changes that were applied and verified in that target, or that the target provably already contained. Cancelled, unchecked, failed, unverifiable or offline-target changes must stay detectable by the next sync. Identical-content remove/add pairs are identity drift (syncIdMap remapping), not edits.
- After a verified write, the written browser's post-write tree becomes its baseline only for differences the dispatched operations explain (content-matched). Any other difference between the pre-write observation and the post-write tree is a concurrent user edit and must remain a pending local change.
- Differences between live trees that no pending change explains are recovered by evidence-based reconciliation (two-way only), never by mirroring: a URL absent from a browser that never had it is a missed addition; if the lacking browser's own snapshot history or Recently Deleted shows it had and lost it, the newer event wins (a holder's later re-add is kept, otherwise the deletion is propagated). Absence alone is never deletion evidence; skip URLs touched by pending changes or still present outside the lacking browser's selected folder.
- Manual sync only triggers immediate snapshot collection and the same session pipeline as automatic sync (baseline deltas, stable conflicts, reconciliation). It must not switch to full-tree mirroring or grant broader mutation authority.
- One sync session reads one native tree per writable target and plans every source's contribution into that target sequentially against that single input token, producing one plan and one verified write per target. Never key pending plans so that one source can replace another source's plan for the same target.
- Bookmark Sync OFF is a final write-boundary prohibition for Safari and every browser extension. No sync, restore, cleanup, maintenance, or local-edit helper may bypass it.
- Safari is written only by (a) a sync session's scoped native plan, (b) a user-approved commit from the review window, or (c) an explicitly confirmed restore. Do not add other Safari writers (global title/URL removal, full-tree re-merge, deduplication rewrites, legacy incremental payloads).
- Extensions never receive another browser's bookmark tree. A bookmark pull or (re)connect is answered with a snapshot request; missed changes stay pending against the per-pair baselines and are planned by a session. Do not reintroduce standalone removal batches or persisted removal queues.
- Safari maintenance cleanups are whole-library repairs: run them only when Safari has no selected sync folder, and always hold them for review regardless of size. With a selected folder they must be skipped, never applied outside it.
- The final Safari write boundary (`writePlist`) receives the caller's explicit-restore flag; only a user-confirmed restore may pass the one-way-source exception.
- In one-way mode, the configured source browser is read-only for synchronization, cleanup, maintenance and automatic writeback regardless of browser type. A user-confirmed Recently Deleted or history/backup restore may write to the explicitly selected source browser; this narrow exception must not authorize any automatic path.
- Enforce authorization again at the final mutation boundary; upstream filtering alone is insufficient.
- Missing or ambiguous selected folders must fail closed. Never select the first title match. Preserve the selected folder scope and do not mutate nodes outside it.
- A selected-folder binding protects only the bound folder node as structural scope; it must never exempt every descendant from deletion tombstones. A newer explicit deletion beats an unchanged stale snapshot from another browser and must not be presented as a cross-browser addition.
- A preview approval is valid only for the exact current input, settings, scope, destination, and operation signature. Stale approvals must be discarded and recomputed.
- Review UI must describe why it opened: Safe Mode reviews use neutral wording, while “large change” wording is reserved for threshold-triggered destructive changes. Display counts for every operation type, including additions and same-parent reordering, and never show/apply an all-zero plan.
- Bookmark review is browser-neutral: use one review window for the complete pending sync, list every plan together grouped by target browser (titled with that browser's icon and name; changes from all sources into that target are merged), and render only changed nodes with the paths needed for context. Never use destination switching, two full trees of unchanged content, or Safari-specific actions. Empty/all-zero plans must be discarded before presenting UI.
- Bookmark conflicts are rows in that same aggregate review window, in a conflict group above the per-target groups; each side shows the icons of the browsers holding that version. Never present one system alert per conflict. Every conflict must expose a choice per version plus keep-both/keep-all; applying the aggregate review confirms all selected operations and conflict choices together.
- A conflict is one logical bookmark with all of its versions (A↔B, B↔C and A↔C are one conflict with three versions), identified by the content of every version, so the same dispute seen from several routes is one row. Each version is shown with its holders' icons, title and URL; the user keeps exactly one version or keeps all. With one kept version every writable browser ends with exactly that version: a losing copy is rewritten in place, further losing copies (or all of them where the kept version already exists) are removed, and the kept version is created once (with each folder once per path) where it is missing. What a browser holds is decided from its live tree, not only from which browsers were detected as sides. The disputed versions are never also planned as ordinary additions.
- Review actions are “Cancel This Sync” and “Apply Selected Changes”. Every change is individually selectable and defaults to selected. Cancellation and unchecked changes apply only to the current computed sync: do not persist a rejection or suppress the same difference later. A future sync must recompute current input and show any remaining difference again.
- The only persisted suppression is the explicit per-row “Ignore” (shown on hover for changes and conflicts). It is keyed by target browser plus the exact change content (or the conflict's two versions), so any different change to the same bookmark is offered again. An ignored change is never treated as synchronized: it stays pending against the baseline and is filtered from planning, review and dispatch. The ignore list must be clearable from the Sync Strategy settings card.
- An explicit “Restore to <browser>” action in Recently Deleted is already the user's approval for that additive restore and must not open a second Safe Mode review. It still passes OFF/participation/one-way-source authorization, scope validation, current-input validation, and post-write verification. Automatic synchronization is not covered by this exception.
- A backup restore writes only into the browser the backup was taken from, inside that browser's currently selected folder, through the scoped native planner and a verified write; the confirmation must name that browser and folder (and warn when it is the one-way source). Incremental restore only creates missing items (never removes, renames or moves existing ones); Replace restore mirrors the backup inside the bound folder only, and only when the backup covers exactly that folder. A whole-library backup restored into a browser that syncs one folder contributes only that folder (the review shows everything else dimmed); a folder backup restored into a whole-library browser goes back into its own folder.
- A native tree from an extension is usable only when it is bound to exactly the requested folder (scope node present in the reported tree; no folder means no scope). Sessions, restores and legacy plans fail closed otherwise. Firefox does not report its Bookmarks Menu subtree, so a Firefox sync folder inside Bookmarks Menu fails closed; do not add that subtree without first excluding it from whole-library mirror scopes, or every Menu bookmark would be planned for removal.
- Restores match archived bookmarks by content in extension browsers (their syncIdMap belongs to other browsers' ID spaces); Safari archives may use Safari's own UUIDs. A restore's pre-write backup must not be suppressed by the 30-second burst rule. A failed or late extension restore result triggers a re-read of that browser.
- "Back Up Now" saves a manual backup of every participating browser's synced folder from a fresh observation; a browser that cannot be observed is reported, never backed up from an old snapshot. Manual backups are kept until the user deletes them; automatic backups expire after 7 days.
- Folder backups archive the folder, its contents and its ancestor folder chain to the root (ancestors only, never their other children), with browser-native roots rewritten to the portable roles 1/2/3, so the folder can be located again on restore. Backups predating this keep a unique-top-folder fallback. Other browsers follow through a normal sync session. Never broadcast a restore tree to other browsers.
- An explicit confirmation in bookmark history/backup restore is also the user's approval for that exact additive or replacement restore. It must not open a duplicate Safe Mode review, but it still obeys OFF, participation, one-way-source read-only, scope/current-input validation, and post-write verification.
- Never queue or notify an all-zero bookmark plan. Bookmark-review notifications must include additions, use a stable per-plan identifier, be removed when the plan clears, and re-check that the plan is still pending immediately before delivery; their action must open the aggregate review window rather than merely activating settings.
- Do not report success, update mappings/snapshots, or retry automatically after a failed, partial, timed-out, disconnected, stale, or unverifiable write.
- Before dispatching any detected bookmark operation, save the changed source scope; before replaying it, save every target scope. Deduplicate identical states and retain automatic bookmark backups by age for 7 days, not by a small fixed count.
- Recently Deleted shows deletion-source browsers as icon badges on each bookmark/folder, not as a prose source label. Restore actions must name the destination browser; multi-source items offer only their recorded source browsers as restore destinations.
- Tests must use synthetic bookmark trees or temporary files. Never require a developer's personal Safari bookmark library or broader filesystem permissions.

## Cross-browser extension parity

- The native app is the only bookmark planner and review authority. Browser extensions may only return a native-ID tree/scope snapshot, validate that the snapshot input is still current, execute the app's explicit approved operations, and re-read/report actual results. Do not compute merge direction, operation selection, preview impact, or approval signatures in an extension.
- Bookmark planning and safety behavior must remain equivalent in Chromium and Firefox.
- When changing either service worker, inspect and update the corresponding path in the other extension. Run `node --check` on both files.
- Treat settings received from the native app as untrusted/stale input: extensions must independently enforce OFF, participation, one-way-source read-only, scope, and approval signatures before mutation.

## Settings and compatibility

- New persisted settings require an explicit default for new installs and an explicit migration policy for existing installs. Do not silently change existing-user behavior unless the product decision says to do so.
- Include safety-relevant settings in approval fingerprints and in the native-to-extension settings payload.
- When settings, direction, participants, folders, or safe-mode state changes, invalidate pending approvals and held writes.
- The app owns the final dispatch policy for every bookmark mutation category and every browser. All send APIs must attach the current OFF/direction/participation/Safe Mode policy; OFF, a non-participant, and the one-way source fail closed before dispatch. Never implement this as a Safari-only, deletion-only, maintenance-only, or extension-version special case.

## Verification before handoff

- Run `git diff --check`.
- Run `scripts/test-bookmark-root-mapping.sh` for bookmark model or policy changes.
- Run JavaScript syntax checks for both extension service workers after extension changes.
- Run `node scripts/test-extension-bookmark-events.js` after extension changes. It exercises both real service workers against a synthetic bookmark tree; do not substitute a user's browser profile for this check.
- Run `scripts/test-daemon-security.sh` for daemon/listener changes; it needs permission to bind loopback sockets.
- Do not compile, build, install, launch, sign, or overwrite BrowSync (including build-only `test.sh`/`xcodebuild` runs) unless the user explicitly requests that action in the current conversation. Source-level checks and synthetic tests remain allowed.
- Report any requested portion that remains unimplemented; do not present a partial implementation as complete.

## Repository hygiene

- Preserve unrelated user changes and do not use destructive Git commands.
- Keep generated build output outside tracked source paths when possible.
- Do not broaden Safari permissions or request Full Disk Access to solve bookmark synchronization problems.
