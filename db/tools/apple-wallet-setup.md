# Turning the Apple Wallet card on

Everything on the AMI side is built and tested. What is missing is a certificate
from Apple, and that is a purchase and about twenty minutes of clicking. This is
the whole of it, in order.

Nothing here needs a developer. The only part that is fiddly is exporting the key
in the right format, and the two commands for that are written out below.

---

## 1. Enrol AMI in the Apple Developer Program

<https://developer.apple.com/programs/enroll/>

About eighty pounds a year. Enrol as an **organisation**, not as an individual, so
the certificate belongs to AMI rather than to a person who might leave.

**Check this first, because it is the only part with a queue in it.** Apple asks
an organisation for a **D-U-N-S number**, which is a free business identifier from
Dun and Bradstreet. If AMI already has one, the enrolment is quick. If it does
not, applying takes a few days, so start there and come back.

Apple also wants a legal entity name that matches, and a phone number they can
reach someone on.

---

## 2. Register a Pass Type ID

In <https://developer.apple.com/account/resources>, **Identifiers**, the plus
button, choose **Pass Type IDs**.

- Description: `AMI membership card`
- Identifier: `pass.uk.com.ami.membership`

The identifier is permanent and appears inside every pass, so it is worth typing
carefully. Note it down; it becomes the `APPLE_PASS_TYPE_ID` binding.

While you are on that account, note the **Team ID** as well. It is ten characters
and appears at the top right of the developer account page under Membership. It
becomes `APPLE_TEAM_ID`.

---

## 3. Create the certificate

Still in **Certificates, Identifiers and Profiles**, go to **Certificates**, the
plus button, choose **Pass Type ID Certificate**, and follow it through. It asks
for a certificate signing request.

On a Mac, make the request in **Keychain Access**: menu **Keychain Access**,
**Certificate Assistant**, **Request a Certificate From a Certificate Authority**.
Put `info@ami.uk.com` as the address, leave the CA address empty, and choose
**Saved to disk**. That produces a `.certSigningRequest` file and, importantly,
puts the matching private key into your keychain.

Upload the request, then **Download** the certificate Apple issues. It arrives as
a `.cer` file.

Double click the `.cer` to add it to Keychain Access. Find it under **My
Certificates**, expand it so you can see the private key underneath, right click
the certificate and choose **Export**. Save it as a `.p12` and set a password when
asked. Remember the password for the next step and then forget it; it is not
needed afterwards.

---

## 4. Get Apple's intermediate certificate

<https://www.apple.com/certificateauthority/>

Download the **Worldwide Developer Relations** intermediate certificate, the
current one. It is free and public. It arrives as `AppleWWDRCAG*.cer`.

---

## 5. Convert the three files to PEM

The Worker takes PEM text rather than binary files, because a Cloudflare binding
holds text. Three commands in Terminal, in the folder where those files are.

```
# the certificate
openssl pkcs12 -in Certificates.p12 -clcerts -nokeys -legacy -out pass-cert.pem

# the private key, and note -nodes, which removes the passphrase
openssl pkcs12 -in Certificates.p12 -nocerts -nodes -legacy -out pass-key-raw.pem

# the key again, converted to PKCS#8, which is the only form that will import
openssl pkcs8 -topk8 -nocrypt -in pass-key-raw.pem -out pass-key.pem

# Apple's intermediate, from DER to PEM
openssl x509 -inform DER -in AppleWWDRCAG6.cer -out wwdr.pem
```

The first two ask for the password you set when exporting the `.p12`.

**The PKCS#8 step is not optional.** A key that begins `-----BEGIN RSA PRIVATE
KEY-----` will not import and the pass will not sign. After the third command the
file must begin `-----BEGIN PRIVATE KEY-----`. If it does not, something went
wrong earlier and it is worth stopping rather than pressing on.

Delete `pass-key-raw.pem` afterwards.

---

## 6. Put the five values into Cloudflare

Pages project `ami-site`, **Settings**, **Variables and Secrets**.

| Name | Type | Value |
|---|---|---|
| `APPLE_PASS_TYPE_ID` | Text | `pass.uk.com.ami.membership` |
| `APPLE_TEAM_ID` | Text | the ten character team identifier |
| `APPLE_PASS_CERT_PEM` | Secret | the whole of `pass-cert.pem`, including the BEGIN and END lines |
| `APPLE_PASS_KEY_PEM` | Secret | the whole of `pass-key.pem` |
| `APPLE_WWDR_PEM` | Secret | the whole of `wwdr.pem` |

Paste each file complete, header and footer included, newlines and all.

**The key is a secret in the real sense.** Anybody holding it can issue passes
that look exactly like AMI's. It goes into Cloudflare and nowhere else: not into
email, not into a chat, not into a shared drive.

**Redeploy the site afterwards.** This is not optional and it is easy to miss.
Cloudflare Pages reads environment variables and secrets at deployment, not per
request, so adding them changes nothing until the next deploy.

`ami-site` is a **direct upload** project, so there is no Retry deployment button
and no way to trigger a rebuild from the settings page. The only thing that makes
a new binding live is creating a new deployment: Deployments, Create deployment,
and upload the current bundle again.

Afterwards, check <https://staging.ami.uk.com/api/pass/status>. It reports which
bindings are PRESENT, as true or false and never their values. Anything still
false is either missing, on the wrong environment tab, or the upload has not
happened.

---

## 7. It turns itself on

Nothing needs editing. The card page asks the Worker what is available every time
it loads, so once all five bindings exist AND the site has been redeployed, the
Apple button stops saying "Not yet" and starts working. If it does not, one of the five is missing or
misspelled, and that is the first thing to check.

Test it on a real iPhone, not in a simulator. Press Add, and the pass should open
in Wallet. If iOS refuses it silently, the usual causes are, in order: the key is
still PKCS#1 rather than PKCS#8, the pass type identifier in the binding does not
match the one on the certificate, or the intermediate certificate is an old one.

---

## What is still not done after this

A pass sitting on a phone does not change on its own. Apple expects a small web
service, four endpoints and a push notification, and until that exists a member
whose membership is switched off keeps a card that still looks valid on their
phone. The code on it correctly answers that they are not a current member, so
anybody who checks gets the right answer, and it is the checking that matters.

Worth building, and easier alongside than afterwards. It needs an APNs key from
the same developer account, which is free once the membership exists.

---

## Renewal

The Pass Type ID certificate lasts a year. Renewing it is steps 3 and 5 again and
pasting the two new values over the old ones. Passes already on phones keep
working; only newly issued ones need the current certificate. Put a note in the
diary a month before it expires, because nobody finds out a certificate has
lapsed until somebody cannot add a card.
