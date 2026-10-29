# Local-network and lan-play multiplayer: what the protocol is, and what we would need

Written after reading [c22dev/mush8](https://github.com/c22dev/mush8), an independent native
port of Mario Kart 8 Deluxe for Apple platforms (Rust, `nxhost`/`nxpatch`/`nxshader` crates —
a different implementation of the same idea as nxnative). Nothing here is copied code: the
sections below describe the **public protocol** and the shape of a host-side implementation.

**We have none of this today.** `dm/host/hle_offline.c` line 1 says so outright: online play,
local wireless, friends and SSL are "out of scope … all made unavailable, the game takes its
offline branch", and there is no `hle_bsd` — every socket call returns -1 / `ENETDOWN`.

## Three modes, one virtual network

mush8 offers LAN, LanPlay and Wireless. All three are the same shape: a virtual network stack
in the host, with one pluggable transport carrying raw IP packets.

    game → nn::socket (bind/sendto/recvfrom/poll)
         → virtual network: own address 10.13.x.y, mask 255.255.0.0, gateway 10.13.37.1
         → Transport: LAN (real broadcast) | LanPlay (UDP to a server) | Wireless (peer to peer)

The game's own code is untouched: it sees a normal BSD socket API, and everything below is host
side. That is the property that makes this cheap to bolt onto a host that already has the
services stubbed out.

### The virtual network layer

- **Address**: random `10.13.<1..254>.<1..254>`, never the gateway, chosen once per process.
- **Mask** `255.255.0.0`, **gateway** `10.13.37.1`, **MTU** 1500.
- **Broadcast**: `255.255.255.255` and the subnet's own broadcast address both deliver to every
  local socket bound to that port — this is how discovery works, and why no server is needed on
  a LAN.
- **Per-socket state**: local bind address, optional connected peer, non-blocking flag, timeout,
  a receive queue and a "changed" epoch so `poll`/`select` can wake when a packet arrives.
- **Socket registry per port**: a socket can be found by the port a packet arrives on, which is
  what makes broadcast delivery work without a real routing table.

### lan-play (the public server protocol)

Port **11451** by default, plain UDP, one byte of type followed by the payload.

| Byte | Type | Direction | Payload |
|---|---|---|---|
| `0x00` | keepalive | client → server | none |
| `0x01` | IPv4 | both | a whole IP packet |
| `0x02` | ping | client → server | 4 random bytes (echoed back) |
| `0x03` | IPv4 fragment | both | 16-byte header + data (below) |
| `0x04` | auth | server → client | the server asks for a login, and implementations without it log and continue |
| `0x10` | info | server → client | a UTF-8 message to show the player |

The high bit (`type & 0x7F`) is masked off on receive, so `0x81` is accepted as IPv4.

**Fragment header** (16 bytes, all multi-byte fields big-endian):

    offset  size  field
    0       4     source IPv4 address
    4       4     (reserved in the observed implementation)
    8       2     fragment id
    10      1     part index (0-based)
    11      1     total parts
    12      2     data length in this packet
    14      2     path MTU, i.e. the data length of every part except the last

Reassembly keeps a table keyed by `(source, fragment id)`, drops entries older than 5 s, rejects
mismatched totals or MTUs, and concatenates parts in index order.

**Client behaviour**: keepalive + ping every 10 s, consider the server lost after 30 s of
silence, reconnect every 5 s on failure. The client picks its virtual address itself, and the server
maps it to the connection.

A real Switch can join a lan-play server, which is the whole point: this is how Switch players
and a ported build end up in the same lobby. For LAN mode the README of mush8 notes that the
**game update must match the Switch's** — version mismatch is the usual cause of "we cannot see
each other".

### LAN mode

Real broadcast on the physical interface instead of an encapsulation: packets go out as UDP
broadcasts on the local subnet so other Switches (and other hosts running the same build) see
them. Simpler than lan-play, but only works when everyone shares one subnet.

### Wireless mode

Peer discovery without a router, using the platform's peer-to-peer mechanism (mush8 uses mDNS /
DNS-SD to advertise and browse, `dnssd.rs`: `DNSServiceRegister` / `DNSServiceBrowse` /
`DNSServiceResolve` / `DNSServiceGetAddrInfo`). Each player advertises a service and browses for
the others, and the first contact becomes the transport.

## What the game needs above the transport

Transport alone is not enough: the game asks Horizon whether a wireless/LAN session exists and
what the room looks like. That is `nn::ldn` (local wireless), `nn::nifm` (network interface) and
in some titles `nn::vnet` (virtual network sockets). Each game uses a subset differently:

- which `ldn` calls it makes (create/join/scan, and in what order),
- how it encodes room name, password, player list and game mode in the advertise/join payloads,
- whether it opens sockets through `nn::socket` or `nn::vnet`,
- what it does when a scan returns nothing.

This is why **mush8 supports exactly one game**: the `ldn` payload layer is per-title. A general
implementation would expose the virtual network and the `ldn` primitives, and then each game
needs its own mapping from "the bytes in the room struct" to something meaningful.

## What an implementation in our host would need

Roughly four layers, in order:

| Layer | Content | Where it would live |
|---|---|---|
| 1. BSD sockets | `socket`/`bind`/`sendto`/`recvfrom`/`poll`/`select` over the virtual network, with the errno conventions the SDK expects | new `dm/host/hle_bsd.c` (replaces the offline stubs in `hle_offline.c`) |
| 2. Virtual network | address/MASK/gateway, per-port socket registry, broadcast rules, receive queues, wake-on-packet for `poll` | new `dm/host/dm_vnet.c` |
| 3. Transports | lan-play framing and reassembly, LAN broadcast, wireless via mDNS | one file per transport |
| 4. `ldn` / `nifm` | make the game believe a session can exist, per-game payload mapping | `hle_ldn.c`, and per-game code |

Layers 1–3 are game independent and reusable. Layer 4 is where a new title costs work again.

**Cost estimate**: layers 1–3 for one game (Mario Kart 8 Deluxe, since its protocol is the one
documented above and it is the title mush8 proved) ≈ 2–3 weeks. Each further title that uses
`ldn` differently: days to weeks.

## Open questions before committing to this

- **Does our Metal host survive packet injection at frame rate?** Untested. The transport runs
  on its own thread, but `poll` must wake a blocked guest thread promptly.
- **iOS local network permission**: iOS 14+ shows a prompt and the entitlement
  `com.apple.developer.networking.multicast` may be needed for broadcast. A sideloaded unsigned
  IPA cannot carry it, which could make LAN mode impossible on iOS while lan-play (unicast UDP)
  still works.
- **Matching the game update to the Switch's**, per mush8's note — our profiles already pin an
  update version per game, so this is checkable, but users must know.
- **mush8 is Rust and we are C/ObjC**: no code can be taken, only the protocol. Anything we build
  is a fresh implementation with its own bugs, and it cannot be verified without two clients —
  which means you need a real Switch, a second iPhone, or two Macs on one network to test.

## Sources

- [c22dev/mush8](https://github.com/c22dev/mush8) — `crates/nxhost/src/services/{vnet,lanplay,lan,wireless}.rs`,
  `crates/nxhost/src/dnssd.rs` (read at commit 0.1).
- lan-play itself is a public protocol with several open implementations (switch-lan-play and
  clients for it), and the constant table above matches what mush8 implements.
