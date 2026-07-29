# Releasing DIBar

Every release must go through this workflow. A plain git push or a GitHub
Release alone will not reach users: auto-update clients only see what
`appcast.xml` on `main` describes, and Sparkle rejects anything whose EdDSA
signature does not match the downloaded bytes.

## TL;DR

```bash
# 1. Write the new section at the top of CHANGELOG.md:  ## <version>
# 2. Run:
scripts/release.sh <version>          # build number defaults to current + 1
```

The script does everything below in order and stops on the first failure.

## Prerequisites (one-time per machine)

- `gh` authenticated against github.com/drmikexo2/DIBar-macOS.
- Notarization keychain profile named `DIBar` (`xcrun notarytool store-credentials`).
- The Sparkle EdDSA private key at `~/.dibar/sparkle_private_key`
  (override with `SPARKLE_ED_KEY_FILE`). This key signs every update:
  it must never change, must never be committed, and losing it means shipped
  apps can no longer verify updates. Keep a backup outside this machine.
  The matching public key lives in `DIBar/Info.plist` under `SUPublicEDKey`.
- Sparkle CLI tools in `~/.dibar/sparkle-tools/` (from the Sparkle release
  tarball; also present in DerivedData under
  `SourcePackages/artifacts/sparkle/Sparkle/bin` after any build).
- `DIBar/Services/Secrets.swift` (copy from `Secrets.swift.example`).

## What the script enforces

1. Clean tree on `main`, release does not already exist, CHANGELOG section present.
2. Build number strictly greater than both the pbxproj value and the highest
   `sparkle:version` in `appcast.xml`. Sparkle compares `CFBundleVersion`,
   so a reused build number would make an update invisible.
3. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`, run the test suite.
4. Archive, export with `ExportOptions.plist` (Developer ID, team FA2AMFV98N),
   notarize with `notarytool --wait`, staple, package
   `dist/DIBar-v<X>-macOS.zip` plus `.sha256`.
5. Commit `Release DIBar <X>`, push, `gh release create v<X>` with the
   CHANGELOG section as notes and both files as assets.
6. Re-download the published asset and require a byte-identical sha256 —
   the appcast signature must describe what GitHub actually serves.
7. Generate the appcast entry with `generate_appcast --ed-key-file`, verify the
   enclosure signature with `sign_update --verify`.
8. Only then commit and push `appcast.xml` (`Update appcast for <X>`), and poll
   the raw URL until the CDN serves it. This ordering means the feed never
   advertises an asset that is not downloadable.

Clients pick the release up on their next scheduled check (daily) or
immediately via Settings > Check for updates. Updates download and install
automatically by default (`SUAutomaticallyUpdate`).

## If the script fails partway

Fix the cause and rerun; every step is idempotent up to the release commit.
After the release commit exists, finish the remaining steps manually in the
same order (they map one-to-one onto the script's sections).

## Release notes style

Plain text prose. No em-dashes, no emojis. Written as user-facing changes,
grouped under short `###` headings, same as existing CHANGELOG sections.
