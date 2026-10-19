# What only you can do

Everything here needs a person: an Apple account, a legal entity, a bank, a
decision, or a second Mac. Ordered so that nothing waits on something below it.

Anything *not* on this list is mine — say the word and it gets built.

---

## 1. Before the first signed build

### 1.1 Apple Developer Program ✅

Done. `Developer ID Application: Creative Oak ApS (493257NQK3)` is installed in
the login keychain. Confirm any time with
`security find-identity -v -p codesigning`.

### 1.2 Notarisation credentials

Generate an app-specific password at appleid.apple.com, then store it once:

```sh
xcrun notarytool store-credentials localhost-notary \
  --apple-id you@example.com --team-id 493257NQK3
```

After that, `NOTARY_PROFILE=localhost-notary ./Scripts/release.sh` does the
rest. The script never sees the password.

### 1.3 Confirm the bundle identifier against your team

The identifier is `dk.creativeoak.Localhost`, to be registered under team
493257NQK3. Check it does not clash with
anything else on your developer account before the first release — changing it
afterwards strands everyone who already installed.

---

## 2. Legal

Localhost is open source under the MIT licence (`LICENSE`), which replaces the
EULA. Its "as is" clause is also what covers the one real exposure a utility
like this has — quitting a process destroys unsaved work — so no separate
disclaimer is needed.

The privacy policy is a draft in `docs/legal/privacy.md`. Fill in the CVR
number and registered address, and publish it next to the download.

---

## 3. Distribution

### 3.1 Updates

Done: **Sparkle**, checking when the panel opens (at most daily) rather than on
a timer, so the app keeps its "does nothing while closed" property. Updates and
the `appcast.xml` feed live on the GitHub releases of `Creative-Oak/localhost`,
which is public for that reason. Installed copies read
`releases/latest/download/appcast.xml`, so publishing a release is shipping it.

The Sparkle EdDSA private key is in the login keychain under the account
`localhost`. **Back it up** — export it with
`.build/artifacts/sparkle/Sparkle/bin/generate_keys --account localhost -x <file>`
into your password manager, then delete the file. Lose it and installed copies
can never be updated again; they will refuse anything signed with a new key.

### 3.2 Where the download lives

Also GitHub releases: `Localhost-<version>.dmg` on each release, linked from
the README. A product page can link to `releases/latest`.

---

## 4. Assets and content

### 4.1 A real icon

`Resources/AppIcon.icns` is my placeholder — a socket slot with a live
indicator. It scales and it is not embarrassing, but it is generic.
`Scripts/make-icon.swift` regenerates it if you want to tweak rather than
replace.

### 4.2 A support address that exists

`support@creativeoak.dk` is a placeholder, marked as one in
`Sources/LocalhostUI/AppServices.swift`. Create the mailbox or change the
address.

### 4.3 The product page

One thing worth putting near the top, because it is unusual and verifiable:
**Localhost sends nothing about you.** No analytics, no telemetry, no
account. It is open source, so this is checkable. The one network request is a daily update check against GitHub, which can be turned
off; besides that, the only socket is a Unix domain socket to Docker.

Also worth saying plainly, from the Reddit research: people value this kind of
tool for **targeting one service instead of `pkill -f node`**.

---

## 5. Things I cannot verify from here

### 5.1 Docker, with a container actually running

The port-to-container mapping is proven by decoding fixtures, never by
observation — no container has ever been running while the app was. Start
anything that publishes a port and check the row shows its name:

```sh
docker run -d -p 8080:80 --name localhost-test nginx:alpine
```

Then remove it. If it works, Docker support can be claimed on the product page;
until then it should not be.

### 5.2 A second Mac, and a clean install

Everything has only ever run on this machine, from a build directory. Before
release, test on a Mac that has never seen the source: a fresh install from the
signed and notarised DMG, first launch, launch-at-login surviving a restart,
and an update from one release to the next.

---

## 6. Open questions I have flagged and you have not answered

Neither is urgent; both change behaviour.

- **Monorepo naming.** A `package.json` with no `name` currently causes the
  walk to continue upward, so a server in `acme/apps/web` is labelled `acme`.
  The alternative is preferring the directory name, `web`. Both are honest.
- **`go run` and `cargo run`** now resolve by executable path. If you use them,
  check the label is what you would expect — I have no Go or Rust servers here
  to test against.

---

## 7. Known gaps, so they do not become surprises

- The known-daemon table has eight entries. Every addition is a moment the app
  looks like it knows something; it is cheap to extend when you meet a port
  that confuses you.
- No localisation. English only, strings inline.
- No first-run guidance. The app launches and appears in the menu bar with no
  explanation, which a stranger may simply not notice.
