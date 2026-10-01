# Third-party components

## Scroll Reverser

Source: https://github.com/pilotmoon/Scroll-Reverser
Version: 1.9, commit 7bc618d4436425c59c630cbd2956e6f4ae46ebe0.
License: Apache-2.0, included with NOTICE.

MenuCraft adapts MouseTap.m delta adjustment. Changes: separate event run loop, synchronized configuration, deterministic discrete-wheel versus continuous-trackpad routing, optional dynamic HID symbol lookup with CGEvent fallback, no logging or UI work in callbacks, corrected horizontal HID multiplier, permission/lifecycle handling and aggregate diagnostic counters. The passive gesture tap and touch-timing heuristic were removed after real-device direction instability. Touch mice and software-smoothed wheels also produce continuous events and follow the trackpad option in this mode. The original name and icon are not used as MenuCraft branding.

## 7-Zip

Version: 26.03 (2026-09-03).
Official downloads: https://www.7-zip.org/download.html
Mac binary: https://github.com/ip7z/7zip/releases/download/26.03/7z2603-mac.tar.xz
Corresponding source: https://www.7-zip.org/a/7z2603-src.tar.xz

The universal 7zz binary is unmodified apart from local ad-hoc signing and bundled as an independent process. License.txt and the complete corresponding source archive are included inside the application in Contents/Resources/ThirdParty. The LGPL terms allow replacing/rebuilding that independent executable. Portions use BSD licenses and the unRAR restriction reproduced in License.txt; RAR creation is not provided.

ZIP encryption creation accepts 1–99 printable ASCII password characters, as enforced by the upstream engine. 7Z supports Unicode passwords. Passwords are supplied through a private standard-input pipe, never command-line arguments or configuration.
