# Shipping

Everything in steps 1–6 is done and verified on this machine. What remains
needs an Apple Developer Program membership, so it cannot be automated from
here.

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

1. **Join the Apple Developer Program** ($99/year). There is no Developer ID
   without it, and no notarisation without a Developer ID.
2. **Create a Developer ID Application certificate** in the developer portal
   and install it in the login keychain. Confirm with:
   ```sh
   security find-identity -v -p codesigning
   ```
   This machine currently reports `0 valid identities found`.
3. **Store notarisation credentials** once, in the keychain rather than in the
   environment or a file:
   ```sh
   xcrun notarytool store-credentials localhost-notary \
     --apple-id you@example.com --team-id TEAMID
   ```
   It will ask for an app-specific password, generated at appleid.apple.com.

## Then

```sh
NOTARY_PROFILE=localhost-notary ./Scripts/release.sh
```

The script signs with the hardened runtime and a secure timestamp, verifies,
submits, staples, and finally asks Gatekeeper for the same verdict a user's Mac
will reach. It never handles a secret itself.

## Still open before a first release

- **The bundle identifier is a guess.** `com.magnisoft.Localhost`, inferred
  from the repository name. It must match the certificate's team and should be
  settled before anything is distributed, because changing it afterwards
  strands existing installs.
- **The icon is a placeholder.** `Scripts/make-icon.swift` generates it and
  says so. It should be replaced by a designer's work.
- **No trial or licensing mechanism exists.** That is a product decision, not
  an implementation gap, and it interacts with the pricing question below.
- **No update mechanism.** Direct distribution means either Sparkle or telling
  people to re-download.
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
