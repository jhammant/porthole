# Porthole privacy policy

Last updated: 22 October 2026 (Porthole Anywhere: a device limit)

Porthole is a pair of apps, Porthole for Mac and Porthole for iPad and iPhone, that let you see and use
your own Mac from your own iPad or iPhone.

**What Porthole collects: nothing, unless you choose Porthole Anywhere or the waitlist (below).** Porthole
has no accounts, no analytics, no advertising and no tracking.

**Where your data goes.** The picture of your Mac's windows, your input (touches, keys, the pointer),
your clipboard text when you copy and paste, the list of your Mac's windows and apps, and the Claude
Code sessions on your Mac travel only between your own devices: over your local network, or through a
VPN you set up (such as Tailscale). The connection is encrypted and only devices you have paired with
your Mac (with the code it shows) can connect.

**Porthole Anywhere (optional subscription).** If you subscribe to Porthole Anywhere, your Mac sends a
notification request to the Porthole Anywhere service (anywhere.hammantlabs.com) when a Claude Code session
comes to need you: your device's push token, your App Store subscription receipt (signed by Apple, so the
service can check it is active), the session's title and its last line. The service checks the receipt and
passes the notification to Apple's Push Notification service, which delivers it to your device. The service
keeps none of this: nothing is stored once the notification is sent, apart from two things held in memory only (never
written to disk, gone when the service restarts): a count that limits how many notifications one device can get in an hour,
and, for each subscription, one-way hashes of up to five device tokens from the last 30 days, so one subscription can't be
shared by unlimited devices. Without a subscription, nothing is sent.

**The waitlist.** If you join the waitlist on Porthole's website, your email address is kept to tell you when
Porthole Anywhere or Pro is available, and for nothing else. Ask to be removed at any time (see Contact).

**What stays on your devices.** Your Mac remembers the devices you paired and its own settings. Your
iPad or iPhone remembers the Macs it paired with (their keys are kept in the iOS Keychain) and its own
settings, such as your favourite apps. Nothing is sent anywhere else.

**Permissions.** On the Mac, Screen Recording lets Porthole stream your windows and Accessibility lets
it send your input to them. On the iPad or iPhone, Local Network lets it find your Mac, and the camera
is used only if you scan a pairing code.

**Children.** Porthole is not directed at children and collects no data from anyone.

**Changes.** If this policy changes, the new version will be published at this address with a new date.

**Contact.** Questions: open an issue at https://github.com/jhammant/porthole/issues.
