# Wake-up pushes

**Status: built, optional, off by default.** On iPhone, Settings → Notifications → **Wake when locked** lets the
relay wake a locked phone through Apple's push service (APNs) when a message arrives. Without it, an iPhone only
receives while Pulshade is open, because iOS wakes a closed app only through Apple. The Mac doesn't need it: the app
keeps running.

## What happens

1. **Registering.** The phone gets a device token from Apple and tells the relay "wake this token when mail lands in
   these mailboxes", proving the mailboxes are its own with their receive keys. Only the main identity's mailboxes are
   covered, never a persona's or a decoy's.
2. **Marking messages.** Every deposit carries `x-pulshade-wake`: `1` for a message, `0` for anything else (a typing
   signal, a receipt, a reaction). The relay can't read what's inside an envelope, so without this it couldn't tell a
   message from a typing signal. Apps that don't send the header wake the phone as they always did.
3. **Waking.** For a message, the relay sends Apple one push saying only "New message", and nothing about who or
   what. The phone then fetches and decrypts as usual. A phone is woken at most once every 3 seconds, however much
   mail lands, and the relay as a whole sends at most 30 pushes a second.
4. **Staying registered.** The relay keeps registrations in memory only, never on its disk, so a restart forgets them until each phone renews. It
   forgets one after 7 days without a renewal. The phone renews every 15 minutes while Pulshade is open and at every launch.
5. **Removing.** Turning the switch off, Burn, Detach, a panic passcode or opening a decoy takes the phone's
   registrations off the relay.

## What each party learns

| | With wake-ups on |
|---|---|
| Message content | Hidden from everyone but the recipient |
| Apple | That your iPhone was woken for Pulshade, and when. Never who wrote or what |
| The relay | Which of your mailboxes belong to one device token (in memory only), and whether each deposit to them is a message. It already saw when envelopes arrive and roughly how big they are |
| Your IP address | Reaches Apple when the phone registers, outside Tor, and reaches the relay as for any request |
| Other mail | Receipts, typing signals and reactions don't wake the phone |

It's like notifications in any app, minus the content. People who need the strongest anonymity should leave it off.
Settings says so plainly beside the switch.

