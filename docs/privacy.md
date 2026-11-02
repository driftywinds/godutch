# Go Dutch privacy policy

Last updated on November 2, 2026.

Go Dutch is an unofficial, community-made mobile client for [Spliit Cloud](https://spliit.cloud), the account-based fork of [Spliit](https://spliit.app), the free and open-source app for sharing expenses. It isn't affiliated with or endorsed by the Spliit project. Its source code is public at [github.com/driftywinds/godutch](https://github.com/driftywinds/godutch). This policy describes what the app keeps on your phone, what leaves it, and where it goes.

## In short

- Go Dutch has no ads and no analytics of its own, and its developers collect nothing: no analytics, no crash reports.
- Go Dutch signs in to your Spliit Cloud account. Your account details, groups and expenses are stored on the Cloud instance you use, and are covered by that instance's privacy policy.
- Exchange rates come from Frankfurter, a free public service. The app asks it for a day's rates and tells it nothing else: not your currencies, amounts or groups.
- Receipt scanning reads the photo on your phone. On Android the photo isn't sent to Google, but Google's ML Kit, which does the reading, sends Google some diagnostic data (see below). On iPhone nothing is sent.

## What stays on your phone

The app keeps, on your phone only:

- a copy of the groups you join or create: their names, currencies and members, and their expenses, so you can use them offline;
- your account's display name, the Cloud instance you use, and the session cookie that keeps you signed in;
- for each group, which member you are, to suggest you in other groups;
- expenses and receipt photos you added offline, until they are uploaded;
- copies of receipts you opened, and of your favorite groups' receipts if you turned that on, within the storage limit you set;
- exchange-rate tables downloaded from Frankfurter (see below);
- your settings: theme, language, how your group list is sorted, the receipt languages you picked, and the receipt download settings.

Errors the app didn't expect are written to the phone's own log, which stays on the phone.

Your phone's own backup (Android's backup to your Google account, or iCloud on an iPhone) may include this data, depending on your phone's settings. Those backups are kept by Google or Apple under your account, not by Go Dutch, and you manage them in your phone's or account's settings.

## What goes to Spliit Cloud

Go Dutch is a client: it reads and changes your account's groups on the Spliit Cloud instance you use.

- **Account data:** creating an account sends the display name you choose, and for an email account your email address and password, to the Cloud instance. Signing in sends the same credentials. The instance stores your account and returns a session cookie, which the app keeps on your phone.
- **Group data:** when you view a group, the app downloads it from the instance; when you add, edit or delete an expense, change a group's settings, invite someone, or create a group, it sends that to the instance.
- **Receipt photos:** photos you attach are made smaller and have all their embedded metadata removed, including where they were taken, before they are uploaded to the instance's file storage.
- Like any app that uses the internet, your phone's IP address is visible to the server it connects to.
- **Security:** the app talks to the Cloud instance over HTTPS, which encrypts the connection. A self-hosted instance uses the address you entered, which is encrypted when it starts with `https://`.

The default instance is Spliit Cloud: its API is `https://api.spliit.cloud` and its web app is `https://spliit.cloud`. Its operator decides what happens to what is stored there. If you use a self-hosted instance, that instance's operator decides. Cloud groups are private; sharing a group's invite link lets someone join, so share it only with people you trust.

## Exchange rates

For an expense paid in another currency, the app fills in the day's exchange rate from [Frankfurter](https://frankfurter.dev), a free, open-source service publishing the rates of the European Central Bank and other central banks.

- **What's sent:** a date. The app always asks for the whole day's table against the euro, so the request doesn't say which currencies you use, and nothing about your expenses, groups or you is sent. As with any server, Frankfurter sees your phone's IP address.
- **When:** when an expense in another currency needs a rate that isn't saved on the phone, and when you tap Update next to Exchange rates in App settings. For use offline, the app also downloads the past week's rates ahead, at most every three hours, after a group refreshes if it's a favorite or has an expense in another currency from the last 30 days.
- **On your phone:** the downloaded tables are kept so rates work offline. Days fetched more than 180 days ago are deleted, except the newest one.
- **Security:** requests go over HTTPS.

## Receipt scanning on Android

Scan receipt uses Google's [ML Kit](https://developers.google.com/ml-kit) and the Document Scanner from Google Play services, both running on your phone. The photo and the text read from it are not sent to Google or anyone else: the app only fills in the expense form with what it read.

Google Play services downloads the Document Scanner, and the text recognition models for Chinese and Japanese, from Google. So that the first scan works offline, the app asks for the Document Scanner, and for your phone's language's model if it is Chinese or Japanese, in the background when it starts; the other model downloads when you pick its language. The Latin-script model is built into the app. ML Kit also sends Google diagnostic and usage data: the device's make, model and Android version, the app's package name and version, performance figures such as how long a scan took, the image format and resolution, and an identifier for the installation that is not meant to identify you. It is encrypted in transit and is not shared with third parties ([Google's disclosure](https://developers.google.com/ml-kit/android-data-disclosure)). Go Dutch doesn't receive any of it.

## Receipt scanning on iPhone

Scan receipt uses Apple's VisionKit and Vision, which are part of iOS and run on your phone. Nothing is downloaded, and the photo and the text read from it are not sent to Apple or anyone else: the app only fills in the expense form with what it read.

## Permissions

- **Camera and photos:** only when you take or choose a receipt photo.
- **Internet:** to talk to your Spliit Cloud instance and to Frankfurter.

Sharing a group's link goes through your phone's share sheet, only when you tap Share. Links on the About screen, and web links and images in expense notes, open in your browser only when you tap them: the app never downloads an image in a note.

## Keeping and removing your data

What the app keeps on your phone stays there until you remove it or uninstall the app; copies of receipts are also removed as needed to stay under the storage limit you set.

- Removing a group from the app's group list deletes its copy on your phone, including its stored receipts. Clear, under Storage in App settings, deletes stored receipts. Uninstalling the app deletes everything it kept on the phone.
- Neither removing data in the app nor uninstalling it deletes your phone's backups. A backup that includes the app's data can still hold it afterwards, and Android restores it when you install the app again. To remove it there, delete the backup, or the app's data in it, in your phone's or account's backup settings ([Android](https://support.google.com/android/answer/2819582), [iCloud](https://support.apple.com/108922)).
- Data on a Spliit Cloud instance stays there when you remove a group from the app. You can manage and delete your account from the Cloud web app's account settings; for a self-hosted instance, ask its operator.

## Children

Go Dutch isn't directed at children and doesn't knowingly collect anything from them.

## Changes

Changes to this policy are published at this address, with a new date at the top. Its history is in the [repository](https://github.com/driftywinds/godutch/commits/main/docs/privacy.md).

## Contact

Questions about privacy, or anything else: open an issue at [github.com/driftywinds/godutch/issues](https://github.com/driftywinds/godutch/issues).
