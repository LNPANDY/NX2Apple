# Xenoblade Chronicles: Definitive Edition (`0100FF500E34A000`)

Base title ID `0100FF500E34A000`, update 1.1.2 (`v196608`), SDK 9.3.1,
Monolith's engine, NVN. Modules: `main`, `subsdk0` (NintendoSDK_movie), `sdk`.

## Current status

Mac gameplay tested (2026-10-28, Apple M6): title, opening movies and real-time
events, the Sword Valley battle through its boss, targeting, movement, Monado
arts and Shulk / Reyn's first Colony 9 combat, with real audio. Frames during
the opening battle take about 33 ms. The unsigned 1.1.2 IPA builds successfully
(13.2 GiB), with all 15,129 shader libraries and a complete CRC check. Further
story progression, saving / reloading and iPhone validation remain open.

## Memory

The NPDM declares no system resource. The 4 GB guest reservation,
with 256 MB each for alias memory and stacks, holds the game's 3.14 GB heap.
The application memory pool remains `0xCD500000`. No game-specific cuts are used;
the SDK takes the existing function-matched address-region adaptations.

**Resolved, streamed texture lifetime:** the first opening-battle run grew to
4.8 GB resident / 5.2 GB GPU while pool and serial counts stayed nearly flat.
A descriptor census found 3,227 finalized textures' cached views retaining
1.1 GB of Switch texture storage. With the general
[descriptor-view retirement fix](../../../docs/reference/nvn-objects.md#finalized-textures-kept-by-registered-descriptor-views),
28,643 retired descriptors held zero cached views; the battle stayed near
2.1 GB resident / 2.5 GB GPU through frame 18,600. Late command replay and
compatible views are covered by the Metal texture tests.
At the first Colony 9 tutorial the final run stayed at 2,230 MB resident /
2,512 MB GPU through frame 53,700, then exited cleanly.

## Files and shaders

The merged RomFS contains 18,539 files (13.61 GiB). Its shaders are loose HCPS
programs, XBC1-compressed effect/map files and DRSM model streams containing
XBC1 resources. There is no ARH/ARD archive.

**Resolved, extraction:** the original split found only the six boot stages in
`main`, at `main+0x11ac820`. Dispatching the loose containers through the existing
[Monolith decoder](../../../docs/reference/shaders.md#monolith-arh1-xbc1-and-hcpsslct-shader-containers)
finds 15,129 keys: 5,147 vertex, 9,966 pixel, three geometry and 13 compute,
with 10,681 variation pairs. Sources contribute 8,109 map keys, 3,506 character
keys, 2,732 shared shader keys, 776 effect keys and six from `main`.
All 199 shader keys absent during the first title run match this inventory.

## Rendering

- **Resolved: scenery darkened during the first Colony 9 bridge reply by Shulk** ([PR #365](https://github.com/seedds/nxnative/pull/365)). In version 1.1.2 on the Mac, the depth-of-field initialization draw takes a Float3 position through a uint4 shader declaration. Its missing `w` caused the draw to be clipped, leaving a black depth-of-field buffer that a later composite blended over textured scenery. The general fix and synthetic regression are linked below.

## Running on the Mac

Build with `scripts/build_ipa_from_nsp.py <NSP folder> -k <prod.keys> --platform mac`;
it prints the run command. The tested interactive runs used `DM_PRESENT_LINK=0`
for direct presentation. With the default display link, a background window
stopped presenting; no profile override is retained. `Plus`, then `A`, skips an
opening event. In battle, close tutorial pages with `A`, target with `R`, start
with `A`, and approach with the left stick. Select arts with the directional
buttons and confirm with `A`. Each opening event needs its own skip.

## Checks

The full Metal graphics suite passes, including 56 CPU-texture / descriptor
lifetime checks. The Monolith decoder's 12 synthetic tests and the graphics,
tool and documentation suites pass (the Mac-packaging subset was rerun on the
external drive after the internal-disk free-space guard stopped its first run).
Mac and iOS full shader builds both report 15,129 of 15,129 successful shaders;
the Mac pipeline prebuild built all 10,681 pairs with zero failures.

The full five-game `regress.py check --baseline HEAD` report is
`0100FF500E34A000-work/regress-harness/reports/20261028-145620-check/report.md`
in the NSP folder. Xenoblade 2 and 3 cover the shared Monolith decoder; Wonder
and Dread cover other NVN engines; Three Houses covers frequent descriptor
registrations. All five have unchanged MSL and zero new shader or interface
failures. Wonder's gameplay route passes. Dread, Three Houses and Xenoblade 3
have no smoke route and receive static checks only. Xenoblade 2's timed route
reports different screenshots and 2,032 → 2,348 MB peak memory, with no new RED
lines. Inspection shows the baseline still in the cloud movie and the candidate
already at the King Crustip tutorial: screenshots and memory compare different
scenes. The earlier tool-only comparison also captured different loading
stages. This result is inconclusive; further gameplay testing was stopped at
the user's request.

## Found on this game

- [Float32 vertex padding through integer inputs](../../../docs/reference/rendering.md#float32-vertex-padding-through-integer-inputs).
- [Monolith ARH1, XBC1 and HCPS/SLCT shader containers](../../../docs/reference/shaders.md#monolith-arh1-xbc1-and-hcpsslct-shader-containers): loose programs, effects and model/map streams.
- [Finalized textures kept by registered descriptor views](../../../docs/reference/nvn-objects.md#finalized-textures-kept-by-registered-descriptor-views).

## Open

- iPhone device testing, further story progression and saving / reloading.
- Repeat the Xenoblade 2 comparison with a deterministic route when requested.
