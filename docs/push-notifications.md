# Push notifications (design, not built)

**Status: a plan for review. Nothing here exists in the app or the relay yet.**

## Goal

Let people opt in to being woken when a message arrives on iPhone, without changing what Pulshade promises everyone
else. Off by default. Settings says so plainly: *Recommended: keep this off. Notifications go through Apple, which can
see that your phone got one and when.*

## Why it costs privacy

iOS only wakes a closed app through Apple's push service (APNs). Using it means:

1. **Apple** learns the device token and the time of each wake-up. Never message content.
2. **Something Pulshade runs** must know "wake this token when mailbox X gets mail", which is a link between a device
   and a mailbox. Today the relay knows no such link.
3. **The phone's IP address reaches Apple** when the app registers, outside Tor.

## Design

- **Separate service.** A small push service, apart from the relay, holds the only token-to-wake-id table. The relay
  never sees device tokens and the push service never sees mailbox keys or message envelopes.
- **Wake ids, not mailboxes.** On opting in, the app makes a random wake id per mailbox group (per persona) and
  registers `{wake id, device token}` with the push service, over Tor where possible (the token itself goes to Apple
  directly, which can't be avoided).
- **The relay pokes the wake id** when an envelope lands in a mailbox that has one. The poke carries no sender, no
  size and no content: just "wake id W has mail". The relay learns the wake id, not the token, and the push service
  learns the token, not the mailbox.
- **The push is content-free.** A silent or "New message" push. The app then wakes, fetches over Tor as usual and
  decrypts locally. Notification text still follows the existing setting (default "New message").
- **Batching and delay.** Pokes are held a random few seconds and sent together so a push can't be lined up with one
  specific send.
- **Removal.** Turning the switch off, locking, Detach or Burn deletes the registration on the push service and
  revokes the token. Registrations expire if not renewed.

## What this does and doesn't protect

| | With push on |
|---|---|
| Message content | Still hidden from everyone but the recipient |
| Who you talk to | Hidden from Apple. Hidden from the relay and the push service unless they cooperate |
| That you use Pulshade | Apple can tell the app registered a push, and when it wakes |
| Timing | Apple and the push service see when wake-ups happen |
| Your IP | Reaches Apple |

The honest summary for users: it's like the notifications on any app, minus the content. People who need the
strongest anonymity should leave it off.

## To decide before building

1. **Who runs the push service**, and can it be a second small server beside the relay without becoming a second
   point of failure for privacy?
2. **Per persona or per account** wake ids. Per persona keeps personas unlinkable to Apple but costs more tokens.
3. **Mac:** no push needed, the app can keep running.
4. **Apple requirements:** the push entitlement, an APNs key, and a disclosure in the privacy label and policy.
5. **Wording of the "recommended off" message** in Settings, and whether to show it again when switching on.

## Work, in order

1. Relay: optional wake poke, behind a setting that's off.
2. Push service: register, remove, expire and send the content-free push.
3. App: Settings switch (off by default) with the recommendation, registration over Tor, entitlement.
4. Docs and policy: update [How Pulshade works](how-it-works.md), the [privacy policy](privacy-policy.md) and the
   README's known limits.
5. Tests: registration, removal on Burn and Detach, and that the relay never receives a token.
