# Shipping

Everything in steps 1–6 is done and verified on this machine. The Developer
ID certificate is installed; what remains is storing notarisation credentials
and the first real release run.

## What is already proven

Hardened runtime works with **no entitlements at all**. A release build,
ad-hoc signed with `--options runtime`, still enumerates every listener,
resolves projects, and reads root-owned listeners:

```
CodeDirectory flags=0x10002(adhoc,runtime)
scan: 0.0032s, 19 listeners, oracle: verified(matched: 20)
```

That is the design's distribution decision confirmed rather than assumed: not
sandboxed, hardened runtime, direct distribution, no privileged helper.

## What you have to do once

1. ~~**Join the Apple Developer Program.**~~ Done.
2. ~~**Create a Developer ID Application certificate.**~~ Done:
   `Developer ID Application: Creative Oak ApS (493257NQK3)` is in the login
   keychain. Confirm with:
   ```sh
   security find-identity -v -p codesigning
   ```
3. ~~**Store notarisation credentials**~~ Done, as the `localhost-notary`
   profile. To redo it:
   ```sh
   xcrun notarytool store-credentials localhost-notary \
     --apple-id you@example.com --team-id 493257NQK3
   ```
   It will ask for an app-specific password, generated at appleid.apple.com.

## Then

```sh
VERSION=0.2.0 BUILD=2 NOTARY_PROFILE=localhost-notary PUBLISH=1 ./Scripts/release.sh
```

The script signs the app and Sparkle's helpers with the hardened runtime and a
secure timestamp, builds `Localhost-<version>.dmg`, notarises and staples it,
asks Gatekeeper for the same verdict a user's Mac will reach, writes the Sparkle
`appcast.xml`, and with `PUBLISH=1` creates the GitHub release `v<version>`
carrying both. It never handles a secret itself.

`BUILD` must go up every release: it is what Sparkle compares. Installed copies
read `releases/latest/download/appcast.xml`, so a published release is live
immediately — there is no separate deploy. Leave `PUBLISH` unset to inspect
the DMG first; the script prints the `gh release create` command.

## Still open before a first release

- **The licence signing key is a placeholder.** `License.signingPublicKey`
  must be replaced with a real public key (see `human-plan.md` §1.1), or every
  key sold will be rejected.
- **The bundle identifier** is `dk.creativeoak.Localhost`. It must match the
  certificate's team (493257NQK3), and must not change after the first
  release — changing it afterwards strands existing installs.
- **The icon is a placeholder.** `Scripts/make-icon.swift` generates it and
  says so. It should be replaced by a designer's work.
- **Licensing is built, pricing is not decided.** A 14-day trial and offline
  Ed25519 licence keys are implemented; the price and the store are still
  open, see below.
- **The port-to-container mapping is proven by fixture, not observation.** No
  container has ever been running while the app was. Worth one real test with
  a published port before claiming Docker support on a product page.

## Pricing note

LocalPorts is MIT-licensed, $19 lifetime for its Pro tier, with a working free
tier. A price war against an open-source project is not winnable, and
undercutting it would signal that this is the lesser product. The differentiator
is that this app requires no configuration at all: it reads the machine rather
than asking the developer to describe it. If the brief's price band sits well
above $19, that gap now rests on the zero-configuration story, and the band is
worth revisiting deliberately rather than by default.
