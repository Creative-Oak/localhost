# What only you can do

Everything here needs a person: an Apple account, a legal entity, a bank, a
decision, or a second Mac. Ordered so that nothing waits on something below it.

Anything *not* on this list is mine — say the word and it gets built.

---

## 1. Before the first signed build

These are blocking, and the first one is the dangerous one.

### 1.1 Generate the licence signing keypair ⚠️

`License.signingPublicKey` currently reads
`PLACEHOLDER_PUBLIC_KEY_REPLACE_BEFORE_RELEASE`. **Ship with that and every key
you sell will be rejected by the app**, silently, until you notice.

```sh
swift Scripts/make-license.swift --generate-keys
```

- Paste the **public** half into `License.signingPublicKey`
  (`Sources/LocalhostKit/Licensing/License.swift`).
- Put the **private** half in your password manager. Never commit it, not even
  to this private repo — the repo's privacy is a setting someone can change,
  and anyone holding that key can mint licences for your product forever.
- Keep it backed up. Losing it means every future key must use a new signing
  key, which invalidates every key already sold.

Sanity check afterwards:

```sh
swift Scripts/make-license.swift --sign you@example.com --key <private-base64>
```

Then paste that key into the app's gear menu → Enter Licence Key. It should say
"Licensed to …". If it does, the loop works end to end.

### 1.2 Apple Developer Program

$99/year. There is no Developer ID without it, and no notarisation without a
Developer ID. This machine currently reports `0 valid identities found`.

1. Join at developer.apple.com.
2. Create a **Developer ID Application** certificate and install it in your
   login keychain.
3. Confirm: `security find-identity -v -p codesigning`

### 1.3 Notarisation credentials

Generate an app-specific password at appleid.apple.com, then store it once:

```sh
xcrun notarytool store-credentials localhost-notary \
  --apple-id you@example.com --team-id TEAMID
```

After that, `NOTARY_PROFILE=localhost-notary ./Scripts/release.sh` does the
rest. The script never sees the password.

### 1.4 Confirm the bundle identifier against your team

The identifier is `dk.creativeoak.Localhost`. Check it does not clash with
anything else on your developer account before the first release — changing it
afterwards strands everyone who already installed.

---

## 2. Legal

Both documents are drafts in `docs/legal/`. **They need a lawyer**, not a
careful read by you or me.

### 2.1 Fill in the placeholders

Bolded in both files:

- Full legal entity name and address.
- Refund window (14 or 30 days is customary).
- Governing law and jurisdiction — drafted as Denmark; confirm.

### 2.2 Get advice on two specific things

- **EU right of withdrawal on digital purchases.** A customer may have a
  14-day withdrawal right unless they expressly waive it at the point of
  purchase. The wording of that waiver matters and belongs in the checkout, not
  only in the EULA.
- **EULA clause 4**, which states that quitting a process destroys unsaved
  work, that this is intended behaviour, and how the `(pid, startedAt)`
  re-check reduces the risk of hitting the wrong process. That clause is where
  a utility like this carries its only real exposure. Make sure your lawyer
  reads it as a disclaimer of *intended* destructive behaviour, not as a
  warranty about correctness.

### 2.3 Publish them

Both need to be reachable from the product page and from the checkout before
you take money.

---

## 3. Commerce

### 3.1 Decide the price

Context, so the decision is not made in a vacuum: LocalPorts is MIT-licensed,
$19 lifetime for its Pro tier, with a working free tier. You cannot win a price
war against an open-source project, and undercutting it signals you are the
lesser product. The differentiator is that Localhost needs no configuration at
all — it reads the machine instead of asking the developer to describe it.

If the brief's price band sits well above $19, that gap now rests entirely on
the zero-configuration story. Worth revisiting deliberately rather than by
default.

### 3.2 Choose how you sell

Paddle, Lemon Squeezy, Gumroad or Stripe. The one requirement the app imposes:
**you must be able to run a script on purchase**, or accept issuing keys by
hand at first.

Paddle and Lemon Squeezy act as merchant of record and handle EU VAT, which is
the part that is genuinely tedious to do yourself.

### 3.3 Wire up key issuing

Manual is fine for the first weeks — it is one command per sale:

```sh
swift Scripts/make-license.swift --sign customer@example.com --key <private>
```

Automating it means running that on a webhook. Tell me when you have picked a
store and I will build the issuing endpoint.

---

## 4. Distribution

### 4.1 Decide where updates live

I recommend **Sparkle**, driven by the panel opening rather than a background
timer, so the app keeps its "does nothing while closed" property. You need to
provide:

- An EdDSA keypair (Sparkle's `generate_keys` tool).
- Somewhere static to host `appcast.xml` — S3, GitHub Pages, Cloudflare.
- Somewhere to host the signed `.zip` of each release.

Once you have a URL for the appcast, I will integrate it.

### 4.2 Decide where the download lives

Your own site, or the store's delivery. Either is fine; it just has to be
decided before the product page is written.

---

## 5. Assets and content

### 5.1 A real icon

`Resources/AppIcon.icns` is my placeholder — a socket slot with a live
indicator. It scales and it is not embarrassing, but it is generic.
`Scripts/make-icon.swift` regenerates it if you want to tweak rather than
replace.

### 5.2 A support address that exists

`support@creativeoak.dk` is a placeholder, marked as one in
`Sources/LocalhostUI/AppServices.swift`. Create the mailbox or change the
address.

### 5.3 The product page

One thing worth putting near the top, because it is unusual and verifiable:
**Localhost makes no network connections at all.** No analytics, no telemetry,
no licence server. Licence keys are verified with cryptography on the machine.
I checked this rather than assuming it — there is no HTTP client anywhere in
the source, and the only socket is a Unix domain socket to Docker.

Also worth saying plainly, from the Reddit research: people value this kind of
tool for **targeting one service instead of `pkill -f node`**.

---

## 6. Things I cannot verify from here

### 6.1 Docker, with a container actually running

The port-to-container mapping is proven by decoding fixtures, never by
observation — no container has ever been running while the app was. Start
anything that publishes a port and check the row shows its name:

```sh
docker run -d -p 8080:80 --name localhost-test nginx:alpine
```

Then remove it. If it works, Docker support can be claimed on the product page;
until then it should not be.

### 6.2 A second Mac, and a clean install

Everything has only ever run on this machine, from a build directory. Before
release, test on a Mac that has never seen the source: a fresh install from the
signed and notarised `.zip`, first launch, the trial banner, entering a licence
key, and launch-at-login surviving a restart.

### 6.3 The trial expiring

Nothing has ever seen day 15. Set your clock forward, or temporarily lower
`EntitlementPolicy.trialDays`, and check the expired banner appears, that
quitting a process is refused, and that **the port list still works** — that
last part is the design decision most likely to have been broken by accident.

---

## 7. Open questions I have flagged and you have not answered

Neither is urgent; both change behaviour.

- **Monorepo naming.** A `package.json` with no `name` currently causes the
  walk to continue upward, so a server in `acme/apps/web` is labelled `acme`.
  The alternative is preferring the directory name, `web`. Both are honest.
- **`go run` and `cargo run`** now resolve by executable path. If you use them,
  check the label is what you would expect — I have no Go or Rust servers here
  to test against.

---

## 8. Known gaps, so they do not become surprises

- The known-daemon table has eight entries. Every addition is a moment the app
  looks like it knows something; it is cheap to extend when you meet a port
  that confuses you.
- No localisation. English only, strings inline.
- No first-run guidance. The app launches and appears in the menu bar with no
  explanation, which a stranger may simply not notice.
