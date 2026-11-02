# Go Dutch: the logo and app icon

**Status: implemented.** The original icon work was [#106](https://github.com/sharneng/spliit2go/issues/106), 2026-09-25; Go Dutch uses the scissors-and-banknote mark supplied with the rebrand (2026-11-02).

The art is in `assets/godutch/`:

- `app-icon.svg` is the app icon: the mark on its pale mint background (`#93EDD4`).
- `transparent-icon.svg` is the same mark with no background. It is used in the group list header, About and the empty states, where the background would look like a badge.
- `app-icon.png` and `transparent-icon.png` are 1024 px renders of the two SVGs. `scripts/make_icons.py` reads these PNGs, because Pillow can't read SVG; re-render them if the art changes.

## How it's framed

- **Android's legacy icon is rounded.** `mipmap-*/ic_launcher.png` is the square art with a 22.5% corner radius, so pre-Android 8 launchers show the rounded shape. `ic_launcher_round.png` is the circular variant, and the manifest declares `android:roundIcon`.
- **Android's adaptive icon keeps the art in its safe circle.** Android masks the 108 dp foreground to the shape the phone uses, which always contains the central 66 dp circle; the transparent mark is scaled to fit that circle.
- **The square icons leave a 10% margin.** iOS, the App Store and Google Play get the art on `#93EDD4` with no transparency. The App Store rejects an icon with an alpha channel, and iOS rounds the corners itself.
- **Android's adaptive icon has three layers:** the background is the color `#93EDD4` (`@color/ic_launcher_background`), not an image, so it scales and parallaxes cleanly; the foreground is the transparent mark; and the monochrome layer is what Android 13+ tints when the user turns on themed icons. The monochrome layer keeps the mark's shape, with the scissor holes transparent.
- **The in-app logo is transparent and unbounded.** The header uses 32 pt, About 72 pt and the empty states 60 pt. The logo has 1x, 2x and 3x versions (48, 96 and 144 px), so it isn't scaled up at run time.
- **The "Go Dutch" title is `#56BC9C`** (`spliitWordmarkGreen` in `lib/theme.dart`), the green of the Spliit wordmark that spliit-ios draws as its home screen title (its `Logo` image, sampled at `80b2e98`). It's the same in light and dark mode, like the wordmark. On the light header it's below WCAG text contrast (about 2.3:1), as the wordmark is; it's a brand mark next to the logo, not body text.

## How it's generated

`scripts/make_icons.py` (Python with Pillow) writes every size: the sizes iOS's `Contents.json` lists, Android's rounded and round launcher icons, the adaptive icon layers, the transparent in-app logo, and the two store icons. `flutter_launcher_icons` would do the same, but adding it downgraded an unrelated dev dependency (`cli_util` 0.5.2 to 0.4.2), and the list of sizes is short. See SETUP.md, "App icon".

Not done yet: a logo on the launch screen.
