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

1. Clean tree on `main`, pull current `main`, confirm release credentials and
   tools, ensure the release does not already exist, and require a CHANGELOG section.
2. Read versions only after the pull, then require a build number strictly
   greater than both the pbxproj value and the highest
   `sparkle:version` in `appcast.xml`. Sparkle compares `CFBundleVersion`,
   so a reused build number would make an update invisible.
3. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`, run the test suite.
4. In a unique temporary directory, archive and export with
   `ExportOptions.plist` (Developer ID, team FA2AMFV98N), notarize with
   `notarytool --wait`, staple, and strictly verify the app and Sparkle helper
   signatures. Package `dist/DIBar-v<X>-macOS.zip` plus `.sha256`.
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

Before the `Release DIBar <X>` commit, the exit trap restores the project
version and removes the temporary archive/export directory. Fix the cause and
rerun the same command.

After the release commit exists, the script deliberately does not rewrite Git
or GitHub history. Do not rerun it, because the version or GitHub Release may
already exist. The failure message names the phase; continue as follows:

- **Release commit push:** inspect `git status` and `git log -1`, then `git push`.
- **GitHub release:** create `v<X>` from the existing release commit and upload
  the ZIP and checksum already present in `dist/`.
- **Published asset verification or appcast generation:** download the
  published ZIP, verify it matches the local checksum, then run the appcast
  generation/signature-verification section from `scripts/release.sh`.
- **Appcast commit or push:** confirm `appcast.xml` describes the downloadable
  asset and its EdDSA signature verifies, then commit/push it.
- **Feed CDN verification:** no repository recovery is needed; check the raw
  appcast URL until it exposes the new `sparkle:version`.

If appcast generation fails before its commit, the trap restores the last
published `appcast.xml`, preventing a partial feed from remaining in the
working tree.

## Smoke testing the update path

Unit tests cannot cover installation: that path only runs when a real Sparkle
installer replaces a real bundle. Before shipping anything that touches update
handling, run:

```bash
scripts/smoke-update.sh                      # assert recovery works
scripts/smoke-update.sh --baseline <ref>     # also assert the test detects the bug
```

It builds a fake 2.0 update, serves a signed appcast from `127.0.0.1`, holds
DIBar busy long enough to kill it after the update is staged (what a reboot
looks like to Sparkle), then relaunches idle and requires the app to recover,
install, and relaunch on 2.0 without a prompt or graceful-quit fallback.
It also starts from 1.4.1 once more and requires an ordinary idle background
update to install automatically. Everything runs under the throwaway bundle identifier
`com.di-fm-menubar.smoke`, so it has its own container and preferences and
cannot disturb an installed DIBar. Nothing is published: no tag, no GitHub
release, no change to `appcast.xml`.

Pass `--baseline <ref>` to first run the same scenario against a commit from
before the fix and require it to *fail* to recover. A test that cannot fail
proves nothing, so use it whenever the recovery logic changes. `KEEP_WORK_DIR=1`
preserves the build and feed for inspection when something goes wrong.

## Release notes style

Plain text prose. No em-dashes, no emojis. Written as user-facing changes,
grouped under short `###` headings, same as existing CHANGELOG sections.
