# Go Dutch

<img src="assets/godutch/app-icon.png" width="96" alt="Go Dutch app icon">

Go Dutch is an unofficial, offline-capable Flutter client for [Spliit Cloud](https://github.com/antonio-ivanovski/spliit-cloud), the account-based fork of [Spliit](https://github.com/spliit-app/spliit). Android is the primary target; iOS uses the same code.

> **Upstream credit:** Go Dutch is a rebranded fork of [spliit2go](https://github.com/sharneng/spliit2go), the original Flutter client for Spliit Cloud by sharneng and its contributors. Its design language, UI and most of this code come from that project. Go Dutch's own source is at [github.com/driftywinds/godutch](https://github.com/driftywinds/godutch).

This app speaks **only** the Spliit Cloud API. It no longer joins anonymous `spliit.app` group URLs: Cloud groups belong to an account, sync across devices, and are shared through invite links.

## What it does

### Account and identity
- **Anonymous account:** a display name, no email, no social login. This is the fork's default way in.
- **Email account:** sign up with name, email and password; Cloud sends a verification link; sign in afterwards.
- **Recovery link:** every anonymous account gets a `spliit.cloud/auth/recover#code=…` link. The app makes saving it part of onboarding (Cloud refuses account APIs until it is acknowledged), copies/shares it, and can sign back in from a pasted link.
- **Account screen:** edit the display name, see the instance, open the web account page for passkeys, connected apps, email changes and privacy, and sign out (the local cache is cleared for the next account).
- **Pending invitations:** email invitations addressed to the account appear on the account screen and can be accepted there.

### Groups
- **Synced group list:** every group the signed-in account is an active member of, cached for offline reading. Favorites are a server preference, so they follow the account to another device.
- **Invite links:** share a copyable invite link from a group; join by pasting one. Cloud groups are private, so a plain group URL is not joinable.
- **Members:** account-backed members with roles; admins can promote/demote, remove members (with a balance-settling fallback), revoke pending invitations, archive/unarchive, delete the group, or leave it.
- **Appearance and settings:** group name, notes, currency, Cloud emoji/color, creation/expense date span. Cloud locks the currency once the ledger has expenses.
- **Friends:** people the account shares groups with, derived by Cloud.

### Expenses
- Expense list, details, add, edit and delete against the Cloud schema, with the same offline-first cache and outbox as before.
- **Multiple payers** are read and included in balances; Cloud's payer splits are cached with the expense.
- **Comments** on an expense, read and posted from the details sheet.
- **Activity** feed with Cloud's activity types.
- **Categories** use Cloud's slug catalogue (`general`, `groceries`, `settlement`, …) with stable local ids for icons and translations.
- **Recurring expenses:** daily/weekly/monthly creation with an indefinite series; a series badge and the server's current state are shown where available.
- **Multi-currency:** paid-in currency and conversion rate, with Cloud's custom/exchange conversion payload.
- **Receipts:** direct-to-bucket presigned uploads, cached locally for offline viewing, with the existing scanner/import flows.
- **Settlements** use Cloud's `settlement` category, so Cloud's stats exclude them.
- Read-only group archive, expense permissions (`canEdit`/`canDelete` from Cloud) and versioned updates are enforced.

### Offline
Groups, participants, expenses, categories and receipt files are cached in a local SQLite database (drift). New expenses are queued and replayed with a stable request id for Cloud's idempotency. Edits and deletes stay online-only.

## Architecture

- **Transport:** Cloud's tRPC endpoints at `{api}/trpc`, using its batch wire format and superjson responses.
- **Auth:** Better Auth at `{api}/auth`. Sessions are HttpOnly cookies; the app keeps the Better Auth cookie jar in `SharedPreferences` and sends it on every tRPC/auth request. The public instance's API is `https://api.spliit.cloud` (the web app and invite links are on `https://spliit.cloud`); self-hosted instances normally serve both from one host.
- **Data layer:** `lib/api/spliit_client.dart` maps Cloud responses into this app's own DTOs (`lib/models/`), so a schema change breaks one mapping function rather than every screen.
- **Cache:** `lib/db/` keeps the last-synced snapshot and a `pending` flag for offline-created expenses. Balances are computed on-device from cached expenses (`lib/services/balance_calculator.dart`), including multi-payer rows.
- **Sync:** `lib/sync/outbox.dart` replays pending expenses with their original request id.
- **Time:** Cloud stores an instant plus the IANA zone the expense was entered in; `lib/services/device_time_zone.dart` renders the calendar date in that zone.

## Run it

1. Install Flutter (stable) and confirm `flutter doctor`.
2. `flutter pub get`
3. `dart run build_runner build`
4. `flutter run`

The default instance is Spliit Cloud. To use a self-hosted Cloud API, tap **Server: spliit.cloud** on the welcome screen and enter its address; the API and web app normally share a host there.

> Upgrading from an earlier, unauthenticated Spliit client clears the local group cache once: those groups belong to `spliit.app`/self-hosted URLs, not to a Cloud account. Rejoin them with invite links after signing in.

Generate localization and drift code before analyzing from a clean checkout:

```
flutter gen-l10n
dart run build_runner build
flutter analyze
flutter test
```

## Releases

Pushing a `v*` tag runs [`.github/workflows/android-release.yml`](.github/workflows/android-release.yml): it builds the signed prod APK (universal plus arm64-v8a, armeabi-v7a and x86_64 splits), verifies the signer, and attaches the APKs and `SHA256SUMS` to a GitHub release. The tag without its leading `v` becomes the app's version name, and the Android version code is `1000 + run number`. The workflow can also be run by hand for a build-only artifact. It needs the four Android signing secrets listed in [`SETUP.md`](SETUP.md#ci-release-apks).

## Known limits

- Passkeys, social/OIDC sign-in, connected apps and full account deletion are web-managed; the app links to `{instance}/account/settings`.
- Itemized expenses and editing an existing multi-payer expense are displayed but not authored in the app yet; creating a new expense records one payer.
- QR-code display/scanning and CSV/bundle import/export are not in the mobile UI yet; Cloud's web app covers them.
- iOS cannot auto-open `spliit.cloud` links without the instance publishing an associated-domain entry for this bundle; pasting the invite or recovery link always works.

## License

MIT — see [`LICENSE`](LICENSE). Go Dutch is forked from [spliit2go](https://github.com/sharneng/spliit2go), which is MIT licensed. Parts are adapted from Spliit and spliit-ios, both MIT; their notices are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
