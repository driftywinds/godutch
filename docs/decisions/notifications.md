# New activity is checked for in the background

Written 2026-11-12, asked for directly ("I want to implement a poll based notification, otherwise what is the benefit of having an app").

## The problem

Spliit Cloud offers this client no push: there is no device token to register, no webhook to subscribe to. Without one, the app could only ever tell the user about a change while it was open, in front of them — which is the case an app on a phone is least needed for.

The one feed the server does offer is each group's activity log (`groups.activities.list`, read by `SpliitClient.fetchActivities`): what changed, when, who did it, and the expense's title. Every screen already uses it for the Activities tab.

## Decisions

1. **The activity log is the feed.** Every poll reads one page (20 entries, newest first) of each group's log and compares it with where it last got to. Nothing else is asked of the server: no expense lists, no group list, no writes.
2. **A high-water mark per group**, stored on the group's row (schema 25): the newest entry read, and its time. Two things move it:
   - a poll, after posting, to the newest entry it read (notified or not — a kind that's switched off is still read past, so it can't come back later);
   - opening the group (`markGroupSeen`), which records "seen up to now" by time alone, so what the user is looking at isn't notified about afterwards.

   A group never polled starts from its newest entry, silently: turning notifications on would otherwise ring for every group's last day at once.
3. **Android's WorkManager runs the poll**, as one periodic task (`godutch-notifications`), registered whenever notifications are on and cancelled when they're off or the account signs out. Every 15 (default), 30 or 60 minutes — 15 is WorkManager's floor — with a network-connected constraint so it doesn't wake to find none. iOS uses BGAppRefresh behind the same call: opportunistic, often only when charging. The `BGTaskSchedulerPermittedIdentifiers` and `UIBackgroundModes` entries are in `ios/Runner/Info.plist`; iOS delivery is untested.
4. **Four channels**, each its own switch and its own line in Android's notification settings: `expenses` (added, changed, deleted), `comments`, `settlements` (a payment), `members` (someone accepted an invitation). Ids are permanent once a phone has seen a channel; the names are created at launch in the app's language, at Default importance — an app may raise importance later, never lower it.
5. **One notification per event**: the group's name as the title, one sentence as the body ("Ana added “Lunch”."), posted oldest first. At most 5 per group per poll, and nothing older than 24 hours rings — older entries only move the mark, so coming back from a holiday doesn't empty the shade.
6. **Off until turned on** (App settings, Notifications). Android 13's permission is asked at that moment, not at launch. Only cached, non-archived groups are polled, the 10 most recently opened: a phone in thirty groups shouldn't make thirty requests every 15 minutes. **One group can be muted** from its own settings (Notifications → Notify me), as a device-local choice that isn't part of that screen's Save: a muted group isn't polled at all, and unmuting starts from that moment rather than ringing for what was missed.
7. **Tapping opens the group**: the payload carries the group's id (and the expense's, for later), and both a warm tap and one that launched the app go through the same pending-request handoff the invite links use. A tap while signed out waits for the sign-in.
8. **Nothing here is fatal.** A missing plugin (desktop, tests), a failed schedule, a notification that can't be posted: none of it can fail a launch. Notifications are best-effort by nature.

## Costs and limits

- One small request per group per poll — the whole battery and data story.
- Delivery is at best every 15 minutes, and Android decides: Doze and app standby stretch it, and a force-stopped app doesn't run at all. Battery-optimisation exemption isn't asked for (Play discourages it).
- The log has no amounts, so the copy says what happened, not how much.
- Comments don't ring on this instance: checked against `api.spliit.cloud` on 2026-11-12, posting a comment logs no activity at all, so the Comments switch has nothing to notify about until the server logs them. The parser and channel are there for instances that do.
- Anonymous accounts have no display name — the server names them `guest-…@anonymous.placeholder.local` — so their actions read "Someone".
- A poll doesn't send the outbox. Queued edits still go out the next time the app is open.
