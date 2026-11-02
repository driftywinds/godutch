# Spliit Cloud port

This app was originally an unauthenticated client for the upstream Spliit
server: groups were opened by URL, each group remembered its own server, and
"who are you" was a per-device guess. Spliit Cloud changes that model, so the
port replaces the data layer and the account-facing screens while keeping the
app's visual language (grouped cards, monogram rows, bottom tabs, inline
errors, offline-first cache).

## API and identity

| Concern | Upstream Spliit | Spliit Cloud (this app) |
|---|---|---|
| Base URL | per-group `serverUrl` | one instance, default `https://api.spliit.cloud` |
| Transport | `{server}/api/trpc` | `{api}/trpc` |
| Auth | none | Better Auth at `{api}/auth`, HttpOnly cookies kept by the app |
| Groups | public group id | account membership, private invite links |
| "You" | guessed participant by name | `currentLedgerParticipantId` from `groups.get` |
| Categories | `categories.list` | Cloud's static slug catalogue |
| Expense write | form values | `expenseApiSchema`, request ids, versions, items, conversion |

## Implemented

### Account
- Anonymous account creation (name only), followed by a mandatory recovery
  link because Cloud returns `ANONYMOUS_SETUP_REQUIRED` for every account API
  until it is acknowledged.
- Email sign-up (verification email) and email sign-in, password-reset request.
- Recovery-link sign-in, pasted or from an `/auth/recover` deep link.
- Session restore on launch, sign-out, server change, account-scoped cache
  clearing, and a recovery-link replacement flow for accounts that already
  saved one.
- Account screen: name editing, identity type, server, friends, pending
  invitations, recovery status, link to the web account page (passkeys,
  connected apps, email, privacy), sign out.

### Groups
- Account group list with server-backed favorites, archive sections, member
  counts, date spans, sorting, and offline cache.
- Invite-link join (preview + accept), deep links, pending invite handoff
  through sign-in.
- Create group, edit name/notes/currency, Cloud emoji/color fields in the
  model, member roster with roles, promote/demote, remove member (including
  the settle-balances fallback), invite-link creation/reuse, revoke pending
  invitations, archive/unarchive, delete, leave.
- Friend list derived from shared memberships.
- Read-only budgets screen from `groups.budgets.list`.

### Expenses
- Cloud expense list/get/create/update/delete, with the existing offline
  outbox. New expenses replay with their original request id.
- Cloud permissions (`canEdit`, `canDelete`) and versions; edits fetch the
  current version when needed.
- Multi-payer reads: payer splits are cached, balances and lent/owed arrows use
  them, and the details sheet lists each payer.
- Itemized expenses are read and displayed; comments are read/posted/deleted;
  activity uses Cloud's event names and actor snapshots.
- Cloud categories, settlement category, multi-currency conversion payload,
  simple recurring series, presigned receipt uploads, and the existing local
  receipt scan/import flows.

### Platform
- Android manifest handles `spliit.cloud` invite and recovery links.
- README/SETUP rewritten for the Cloud API, account onboarding, invite links
  and the one-time cache reset when upgrading from the old app.
- No `.git` directory or remote metadata from the previous repository remains.

## Known gaps

- **Authoring multi-payer expenses** is not in the form yet; existing
  multi-payer expenses are only read. Editing one is blocked with an
  explanation instead of collapsing it.
- **Itemized expense authoring** is not in the form; itemized expenses are
  read-only in the app.
- **Passkeys, social/OIDC, connected apps, account deletion, webhooks and
  email notification preferences** are web-managed; the account screen links
  to `{web}/account/settings`.
- **QR invites, CSV/bundle import/export, budget creation/editing and Cloud AI
  extraction** are not in the mobile UI yet. The existing on-device receipt
  parser/scan flow remains.
- iOS universal links require the instance to publish an associated-domain
  entry for this bundle; pasting links always works.

## Verification

`flutter analyze` is clean for the app and its tests. The Cloud API tests
(`test/api`) pass. The legacy widget/service suite still contains tests for
the removed unauthenticated URL model (old `groups.get`/`groups.expenses.*`
mocks, old category-list injection, old share-link behavior and pre-v22
migration data); those are expected to need rewrites rather than indicating
compile failures in the app. The five-minute full-suite run reported 1,146
passing and 184 failing tests, concentrated in those legacy fixtures.
