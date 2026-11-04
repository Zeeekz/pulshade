// Tor for Pulshade (tor/src/lib.rs): Arti behind a SOCKS5 port on 127.0.0.1.
#include <stdint.h>

/// Starts Tor once and returns its SOCKS port, or 0 if it couldn't. Each SOCKS username gets its own
/// circuits; the password must be `secret`. `bridges` is one bridge line per line, or empty for none.
uint16_t pulshade_tor_start(const char *state_dir, const char *cache_dir, const char *secret, const char *bridges);

/// How many of these bridge lines (one per line) Pulshade can use.
int32_t pulshade_tor_count_bridges(const char *lines);

/// Connects through these bridges from now on (empty for none). Returns how many are usable, or -1 if Tor is
/// running and couldn't switch to them; they're used from the next start either way.
int32_t pulshade_tor_set_bridges(const char *lines);

/// 0 to 100 while connecting, 100 once ready, -1 if Tor failed to start.
int32_t pulshade_tor_progress(void);

/// Every lane's latest circuit, one per line: `lane<TAB>hop,hop,hop` (relay IP addresses in order, "onion" for
/// the last leg into an onion service). Free it with `pulshade_tor_free`.
char *pulshade_tor_circuits(void);

/// Frees a string returned by `pulshade_tor_circuits`.
void pulshade_tor_free(char *text);

/// For an app coming back to the front: opens the SOCKS port again (iOS may have shut it while the app was
/// suspended) and gives every lane fresh circuits. Returns the port, the same one unless it was taken meanwhile,
/// or 0 if Tor isn't running. Waits up to 3 seconds, so call it off the main thread.
uint16_t pulshade_tor_wake(void);

/// Gives a lane fresh circuits: its next connection builds a new one instead of reusing one that's gone quiet.
void pulshade_tor_renew(const char *lane);
