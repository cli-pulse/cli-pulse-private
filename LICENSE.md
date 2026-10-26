# License

**Copyright (c) 2025–2026 Ye Yuhe & Cao Yuqi. All Rights Reserved.**

This source code is made publicly available for **transparency, security review, and privacy audit** — so anyone can verify the claims made in [PRIVACY.md](PRIVACY.md) about what CLI Pulse does and does not do with your data.

It is **NOT** an open-source license. CLI Pulse is a commercial product distributed through official channels.

## You MAY

- **Read, inspect, and audit** the source code.
- **Clone** the repository for personal review.
- **File issues** on GitHub to report bugs or request features.
- **Submit pull requests.** If accepted and merged, your contribution is licensed back to the author under the same terms as the rest of this repository. You warrant that you have the right to make the contribution.

## You MAY NOT (without prior written permission)

- **Redistribute** the source code or compiled binaries, in whole or in part.
- **Use** the code, or substantial portions of it, in any other project — commercial or non‑commercial.
- **Create derivative works**, forks intended for distribution, or competing products based on this code.
- **Remove, modify, or obscure** copyright notices, attribution, or this license.
- **Use the "CLI Pulse" name, logo, or icons** for any product, service, website, or promotional material not originating from the author.

## Official distribution channels

- **Mac App Store** — [CLI Pulse Bar](https://apps.apple.com/app/id6761163709)
- **App Store** (iPhone / iPad / Apple Watch) — same listing
- **Google Play** — [CLI Pulse for Android](https://play.google.com/store/apps/details?id=com.clipulse.android)
- **Signed & notarized DMG** — [GitHub Releases](https://github.com/cli-pulse/cli-pulse/releases)

Any binaries or installers obtained from other sources are **not** authentic and may be modified.

## Third-party components

The Mac, iPhone and iPad apps include third-party open-source software, each part under its own license, to which the terms above do not apply:

- the **Sentry Cocoa SDK** (MIT), with the notices it carries for the code it includes (KSCrash, code from YANDEX LLC, fishhook, and Apple code under the Apple Public Source License 2.0);
- **SweetCookieKit** (MIT), whose source is included in the Mac app;
- **xterm.js** with its fit and web-links add-ons (MIT);
- code adapted from **CodexBar** (MIT). Each adapted source file keeps CodexBar's notice in its header.

The full license texts ship inside each app as `ThirdPartyNotices.txt`, in the app's resources. The same file is in this repository, [`CLI Pulse Bar/ThirdPartyNotices.txt`](CLI%20Pulse%20Bar/ThirdPartyNotices.txt). `scripts/generate_third_party_notices.py` writes it; run it again whenever a dependency, a vendored folder or a bundled web asset changes.

**Known gap: the Companion CLI installer.** The Companion CLI `.pkg` is built with PyInstaller and bundles CPython (Python Software Foundation License), the `cryptography` package and OpenSSL (Apache License 2.0, which asks for its NOTICE to be passed on). Their notices are not in the `.pkg` yet; they go in with the next Companion release.

## Contact

For licensing inquiries, partnership requests, or takedown notices:
**yyyyy.yeyuhe@gmail.com**
