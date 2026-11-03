# F-Droid

F-Droid builds the app **from source** on its own build server and signs it
with F-Droid's key. It does not publish the APKs from
[`.github/workflows/android-release.yml`](../.github/workflows/android-release.yml).
An F-Droid install and a GitHub/Play install therefore have different signing
keys: switching between them needs an uninstall and reinstall, unless a
reproducible build with the same key is set up later.

## What has to change first

### 1. Remove Google's proprietary receipt-scanning libraries

This is the blocking issue. `android/app/build.gradle.kts` currently depends on:

- `com.google.mlkit:text-recognition`
- `com.google.android.gms:play-services-mlkit-text-recognition-chinese`
- `com.google.android.gms:play-services-mlkit-text-recognition-japanese`
- `com.google.android.gms:play-services-mlkit-document-scanner`

They are not free software and F-Droid does not accept them. The app can work
without receipt scanning, so F-Droid needs a separate **FOSS flavor** that:

- leaves those four dependencies out;
- replaces `android/app/src/main/kotlin/com/dwprod/godutch/ReceiptScanChannel.kt`
  with a no-op channel returning `unavailable`/`false` for the fdroid flavor;
- keeps the normal `prod`/`dev` flavors and the ML Kit scanner unchanged.

The Dart side already treats `ReceiptScannerUnavailable` as "use the camera or
gallery instead", so the form can keep working; the receipt-scan card should
either be hidden in the fdroid flavor or show the existing fallback. That last
choice is a product decision, not an F-Droid requirement.

### 2. Keep releases tagged

Every F-Droid build points at a full commit hash and a tag such as `v1.0.2`.
Tag the commit before submitting a build.

### 3. License the icon and screenshots

The app icon and logo were supplied separately from the MIT code. F-Droid
reviews assets too; state their license (or replace them with an asset whose
license is clear) before submitting.

## Build recipe

F-Droid has no built-in `flutter` build field in the metadata. Flutter is
pulled in as a source library, and the build runs Flutter commands explicitly:

```yaml
RepoType: git
Repo: https://github.com/driftywinds/godutch.git

Builds:
  - versionName: 1.0.1
    versionCode: 302
    commit: <full commit hash of the v1.0.1 tag>
    subdir: .
    srclibs:
      - flutter@3.47.9
    sudo:
      - apt-get update
      - apt-get install -y gcc libc-dev openjdk-17-jdk-headless
    output: build/app/outputs/flutter-apk/app-fdroid-release.apk
    prebuild:
      - export PUB_CACHE=$(pwd)/.pub-cache
      - $$flutter$$/bin/flutter config --no-analytics
      - $$flutter$$/bin/flutter pub get
      - $$flutter$$/bin/flutter gen-l10n
      - $$flutter$$/bin/dart run build_runner build --delete-conflicting-outputs
    build:
      - export PUB_CACHE=$(pwd)/.pub-cache
      - export ORG_GRADLE_PROJECT_fdroid=true
      - $$flutter$$/bin/flutter build apk --release --flavor fdroid
    scanignore:
      - .pub-cache
    scandelete:
      - .pub-cache
```

Notes:

- `subdir: .` is the directory with `pubspec.yaml`.
- `flutter@3.47.9` is the tag in `flutter/flutter`. If F-Droid's build server
  cannot resolve it, use a Flutter version already available there and update
  the app's toolchain accordingly.
- `ORG_GRADLE_PROJECT_fdroid=true` is what lets the prod release build skip
  the upload-key guard; see `fdroidBuild` in `android/app/build.gradle.kts`.
  The F-Droid build is signed with the debug key first and then re-signed by
  F-Droid.
- `gen-l10n` and `build_runner` are required because
  `lib/l10n/app_localizations*.dart` and `lib/db/app_database.g.dart` are
  generated and gitignored.
- The universal APK is simplest. If per-ABI APKs are wanted, add one build
  block per ABI with `--target-platform` and `VercodeOperation` so the version
  codes increase in the right order (`armeabi-v7a` < `arm64-v8a` < `x86_64`).

## Metadata and updates

A complete `metadata/com.dwprod.godutch.yml` would start with:

```yaml
Categories:
  - Finance
License: MIT
AuthorName: Go Dutch contributors
SourceCode: https://github.com/driftywinds/godutch
IssueTracker: https://github.com/driftywinds/godutch/issues
RepoType: git
Repo: https://github.com/driftywinds/godutch.git

AutoName: Go Dutch
AutoUpdateMode: Version
UpdateCheckMode: Tags ^v.*$
UpdateCheckData: pubspec.yaml|version:\s.+\+(\d+)|.|version:\s(.+)\+
CurrentVersion: 1.0.1
CurrentVersionCode: 302
```

`UpdateCheckData` is the Flutter form F-Droid documents: the version code and
name come from `pubspec.yaml` (`version: 1.0.1+302`). The F-Droid version code
is independent of the GitHub workflow's `1000 + run number`; keep the pubspec
build number increasing, or set `forcevercode: true` and manage the code in
the metadata.

## Store text and graphics

F-Droid reads the same Fastlane-style structure as Google Play:

```text
fastlane/metadata/android/en-US/
  title.txt
  short_description.txt
  full_description.txt
  images/icon.png
  images/featureGraphic.png
  images/phoneScreenshots/1.png
  changelogs/302.txt
```

Put this in the app repository root before submitting. `title.txt`,
`short_description.txt` and `full_description.txt` are mandatory for the
Latest tab. The existing `branding/store/` images can be reused, but the phone
screenshots still show the pre-Go Dutch branding and should be retaken.

## Submission

1. Add the FOSS flavor and confirm `flutter build apk --release --flavor fdroid`
   works from a clean checkout without ML Kit.
2. Add the Fastlane metadata and a changelog for the version code.
3. Fork [fdroiddata](https://gitlab.com/fdroid/fdroiddata), add
   `metadata/com.dwprod.godutch.yml`, and run `fdroid lint com.dwprod.godutch`
   and `fdroid rewritemeta com.dwprod.godutch`.
4. Build it with `fdroid build com.dwprod.godutch` in the F-Droid build
   container.
5. Open a merge request labelled **New App**; reviewers check the license,
   dependencies and build, then the build server publishes it (usually a day
   or two after merge).

References: [Submitting to F-Droid](https://f-droid.org/en/docs/Submitting_to_F-Droid_Quick_Start_Guide/),
[Build Metadata Reference](https://f-droid.org/en/docs/Build_Metadata_Reference/),
[Fastlane metadata](https://f-droid.org/en/docs/All_About_Descriptions_Graphics_and_Screenshots/).
