# Increased Memory Limit

The app asks for `com.apple.developer.kernel.increased-memory-limit`. `build_ipa.sh` writes the
entitlements file itself (`DM_ENTITLEMENTS=<plist>` gives another one, an empty value none): into the
unsigned IPA's placeholder signature (below), and for a prepared Xcode project as `Gen/DmIOS.entitlements`
through `CODE_SIGN_ENTITLEMENTS` in its `Gen/dm.xcconfig`.

## Why it matters

iOS gives an app a per-process physical-memory budget and kills it (jetsam, SIGKILL, no crash
report) when it goes over. On current iPhones that budget is about **3.3 GB** without the
entitlement and **6–8 GB** with it, depending on the device.

Measured here, both on a 12 GB iPhone:

| Game | Peak resident | Headroom | Result |
|---|---|---|---|
| Tears of the Kingdom | 3,342 MB | 33 MB | killed entering the world map |
| Hades II | — | — | asks for a 3.10 GB heap, which is at the budget limit |

Lowering the render scale to 0.5 did not change the Tears of the Kingdom outcome, so the limit is
the guest heap rather than the GPU. The only way past it is a higher budget.

## What the entitlement needs

Two conditions, both required:

1. **The signature carries it.** `build_ipa.sh` builds unsigned (the sideloader re-signs), so what
   matters is whether the sideloader copies unknown entitlements from the IPA into its own signature
   instead of dropping them.
2. **The App ID has it enabled.** The provisioning profile a sideloader generates only includes
   entitlements the App ID is registered for. The sideloader has to ask Apple for it.

## Which sideloaders keep it

Reported by [playport.dev](https://playport.dev/) (a different project with the same requirement):

| Sideloader | Keeps the entitlement |
|---|---|
| AltStore Classic 2.2 or later | Yes |
| Impactor (from a computer) | Yes |
| Xcode with a Personal Team | Yes |
| SideStore 0.7.0, free Apple ID | Not by default — see below |
| Sideloadly and others | Check the tool. Sideloadly does not enable it |

## SideStore with a free Apple ID

The entitlement attaches to the App ID, so it survives the weekly refresh once set. One-time fix:

1. Install this app through SideStore, so its App ID has been created with Apple.
2. Sideload **GetMoreRam** and sign in with the same Apple ID SideStore uses.
3. In GetMoreRam open **App IDs**, tap **Refresh**, select this app's App ID, then
   **Add Increased Memory Limit**.
4. Reinstall the app from SideStore (it upgrades in place, and `Documents/`, the RomFS archive and the
   saves, is preserved).
5. Confirm: `Documents/log.txt` should now show a much larger `headroom to the system memory limit`
   in the `memory up to frame N` lines. GetMoreRam uses one of a free Apple ID's three app slots, so
   delete it afterwards if you need the slot back.

## Checking whether it took effect

Launch the game, let it run a few hundred frames, then read the memory line in `Documents/log.txt`:

```
memory up to frame 600: resident 3342 MB, ... headroom to the system memory limit 33 MB
```

`resident + headroom` is the budget the kernel enforces:

- ≈ 3,375 MB → the entitlement is not in effect.
- ≈ 6,000–8,000 MB → it is.

`os_proc_available_memory()` is what produces that number (`dm/gfx/nvn/nvn_mtl.m`), and it reports
the distance to the budget the kernel enforces.

## Why the placeholder signature matters

`build_ipa.sh` builds unsigned. A sideloader decides which entitlements to carry by reading them
from the signature it is replacing — an unsigned binary has none, so the request would be lost no
matter what sits in the bundle. The script therefore embeds the entitlement with an
ad-hoc signature (`codesign --force --sign - --entitlements …`, no certificate needed): the
sideloader strips that signature and swaps in the user's own, but it now sees the entitlement and
carries it over. Check any built IPA with:

```bash
codesign -d --entitlements :- Payload/DmIOS.app/DmIOS | grep increased-memory-limit
```

Measured here (12 GB iPhone, AltStore Classic 2.3): before the placeholder signature the budget was
3,375 MB and Hades II died entering a larger scene. After it the game runs. If the budget stays at
3,375 MB with a signed IPA, the remaining step is on the App ID — enable the capability with a tool
like GetMoreRam (same Apple ID as the sideloader, App IDs → Refresh → select the app → Add
Increased Memory Limit), then reinstall so the profile picks it up.

## Xcode route

A project prepared with `--prepare-xcode` already carries the entitlement (`Gen/DmIOS.entitlements`).
With a Personal Team and a real device, build from there. That is the one route where the app is
signed at build time, so no re-signing step can drop the entitlement. The Mac launcher's
**Install on** uses this route.
