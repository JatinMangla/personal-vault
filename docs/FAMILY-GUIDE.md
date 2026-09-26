# Our family password vault — how to set it up

*Print this page. Fill in the two blanks before handing it over.*

**Vault address:** `https://______________________________.ts.net`
**Who to call for help:** ______________________

---

## What this is

One safe place for all your passwords, on your phone and computer. It fills
them in for you. Nobody else can read your passwords, **not even the person
who runs the vault**, because they are locked with your master password on
your own phone before they are saved.

## Part 1 — Join our private network (5 minutes)

The vault can only be reached through our private network, so this comes first.

1. Open the invitation email from **Tailscale** and tap the link.
2. Install the **Tailscale** app (Play Store or App Store) and sign in with the
   same account the invitation was sent to.
3. Keep it switched on all the time:
   - **Android:** Settings → Network → VPN → ⚙ next to Tailscale →
     **Always-on VPN: on**. Leave "Block connections without VPN" **off**.
   - **iPhone:** Tailscale app → Settings → **VPN On Demand: on**.

## Part 2 — Install Bitwarden and create your account (10 minutes)

1. Install **Bitwarden Password Manager** (by Bitwarden Inc.).
2. On the first screen, where it says *Logging in on*, choose **self-hosted**.
   Type the **vault address** from the top of this page. Save.
3. Tap **Create account**. Use the email address you were invited with.
4. **Choose your master password: four or more random words**, for example
   `candle river purple seven`. It must be long. Write it on paper and keep
   the paper at home, somewhere safe.

> ⚠️ **Nobody can reset your master password. Not the helper, not anybody.**
> If it is lost, everything in your vault is lost. That is what keeps it safe.

## Part 3 — Two settings to do together with the helper (10 minutes)

These are on the vault's website: open the **vault address** in your phone's
browser and log in.

1. **Stronger lock:** Settings → Security → **Keys** → KDF algorithm
   **Argon2id** → save. You will be logged out; log back in.
2. **Two-step login:** Settings → Security → **Two-step login** →
   *Authenticator app*. Write the **recovery code** on the same paper as your
   master password.

Then tell the helper you are done, so they can add you to the family.

## Part 4 — Let Bitwarden fill in passwords for you

- **Android:** Bitwarden → Settings → Autofill → turn on **Autofill service**.
- **iPhone:** Settings → Passwords → Password Options → turn on **Bitwarden**.

## Check it works

Turn **Wi-Fi off** (mobile data on). In Bitwarden, tap **+** and save a test
login. If it saves, you are set up. Delete the test login afterwards.

## If something goes wrong

- **"Cannot connect" or it will not save:** open the Tailscale app and make
  sure it says **Connected**. Your saved passwords still work without it; only
  saving new ones needs the connection.
- **New phone:** install both apps again (Parts 1 and 2), then log in instead of
  creating an account.
- **Anything else:** call the helper. Never tell anyone your master password,
  not even the helper. They will never need it.
