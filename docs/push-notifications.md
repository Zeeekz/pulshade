# Wake-up pushes

**Status: built, always on while notifications are on.** The relay wakes a locked phone through Apple's push service
(APNs) when a message or a friend request arrives. There is no separate switch for it (from build 19): turning
notifications off in Settings → Notifications (or on the sign-up screen) is what stops it, and then the iPhone only
receives while Pulshade is open, because iOS wakes a closed app only through Apple. An automatic lock keeps Pulshade
receiving behind the passcode (unless a decoy or panic passcode is set, which needs the passcode to pick the account);
a lock you press yourself closes everything.

## What happens

1. **Registering.** The phone gets a device token from Apple and tells the relay "wake this token when mail lands in
   these mailboxes", proving the mailboxes are its own with their receive keys. They are the mailboxes your friends
   write to and, if you have a public @handle, the one friend requests arrive at, and each shared group's current
   mailbox. Only the main identity's mailboxes are covered, never a persona's or a decoy's. From build 22 they go in
   parts, each in a request of its own on a Tor circuit of its own, a random few seconds apart: the handle's mailbox,
   the one-to-one mailboxes in the same three parts they are fetched in, and each group alone. That keeps one request
   from naming them all; it doesn't stop the relay linking them, because every part carries the same token. Over a
   direct connection (Fast) every request comes from the same address anyway, so they go together, 256 mailboxes a
   request, as before build 22. Mailboxes no longer covered go off together with the rest of their part. A registration
   the relay refuses is not tried again for 15 to 60 minutes (one it couldn't be reached for, 1 to 5).
2. **Marking messages.** Every deposit carries `x-pulshade-wake`: `1` for a message, `0` for anything else (a typing
   signal, a receipt, a reaction). The relay can't read what's inside an envelope, so without this it couldn't tell a
   message from a typing signal. Apps that don't send the header wake the phone as they always did.
3. **Waking.** For a message, the relay sends Apple one push saying only "New message", and nothing about who or
   what. The phone then fetches and decrypts as usual. A phone is woken at most once every 3 seconds, however much
   mail lands, and the relay as a whole sends at most 30 pushes a second.
4. **Staying registered.** The relay keeps registrations in memory and, sealed, in a file on its disk, so a restart, crash or reboot keeps them, and a locked phone is still woken. Turning notifications off takes the phone out of the file within seconds. It
   forgets one after 7 days without a renewal. The phone renews every 15 minutes while Pulshade is open and at every launch. While notifications are on, the app asks Apple for a device token the first time it is unlocked on an iPhone, and again at launches.
5. **Removing.** Turning notifications off, Burn, Detach, a panic passcode or opening a decoy takes the phone's
   registrations off the relay.

## What each party learns

| | While notifications are on |
|---|---|
| Message content | Hidden from everyone but the recipient |
| Apple | That your iPhone was woken for Pulshade, and when. Never who wrote or what |
| The relay | Which of your mailboxes belong to one device token (in memory, and sealed on its disk), including your @handle's friend-request mailbox and your groups' mailboxes, so it can tell that handle, those chats and those groups are the same phone, and which phones are in the same group; and whether each deposit to them is a message. It already saw when envelopes arrive and roughly how big they are |
| After Burn | Apple's token for this copy of the app outlives the account. The relay is told to forget it, but a new account made in the same copy of Pulshade gets the same token, which the relay could match. Deleting and reinstalling Pulshade gets a fresh one; the Burn screen says so |
| Your IP address | Reaches Apple when the phone registers, outside Tor, and reaches the relay as for any request |
| Other mail | Receipts, typing signals and reactions don't wake the phone |

It's like notifications in any app, minus the content. People who need the strongest anonymity should turn
notifications off. Settings says so plainly under Notifications.

