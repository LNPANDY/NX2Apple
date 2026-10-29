# dlopen probe — the route C gate

Route C of the universal launcher (shell app + one signed framework per game, `dlopen`ed at
runtime) is listed in [ROADMAP.md](ROADMAP.md#6-universal-launcher--proven-feasible-bounded-by-apples-rules)
as unvalidated, gated on exactly this experiment. The question: **on a stock, non-jailbroken
iPhone, can a sideloaded IPA — installed outside the App Store review with AltStore, Sideloadly or
i4Tools (爱思助手) — `dlopen` a dynamic framework inside its own bundle and call functions in it?**

Every app with dynamic frameworks loads nested code from its own bundle at launch, so the
mechanism exists, and what this probe proves is that it survives the sideloaded conditions, where a
free-provisioning signature replaces the ad-hoc one at install time and re-signs the app and every
nested framework. If `dlopen` refuses such code, route C is dead on stock devices and the dlerror
texts are the evidence for upstream. If it works, route C stands.

## What ships

`probe-out/DmProbe.ipa`, built by `dm/ios/probe/build_probe.sh` (plain `clang` and hand-written
Info.plists, no Xcode project):

```
Payload/DmProbe.app/
  DmProbe                              the shell: runs the probe at launch, then stays open
  Frameworks/Probe.framework/Probe     one C function, probe_answer() → 42 (src/probe.c)
```

At launch the shell appends one line per step to `Documents/probe-log.txt` and shows the verdict on
its screen:

1. the bundle and executable paths, the iOS version, and whether the framework file is present,
2. `dlopen` attempts in order, each with its handle or its `dlerror()` text verbatim:
   `@executable_path/Frameworks/Probe.framework/Probe`, then `@rpath/Probe.framework/Probe`, the
   absolute sandbox path of the same file, the relative `Probe.framework/Probe`, and the bare
   `Probe` (the last two are expected to fail, and their texts tell us how far dyld got),
3. on the first success: `dlsym` of `probe_answer`, a call (42 expected), and `dladdr` naming the
   image the symbol came from,
4. the last line is the verdict: `RESULT: FEASIBLE ...` or `RESULT: BLOCKED ...` plus the reason.

## Installing and reading the result

1. Sideload `DmProbe.ipa` with any of: AltStore (send the file to the phone, open it with
   AltStore, or use AltServer's *Sideload .ipa* on the computer), Sideloadly (connect the iPhone,
   drag the IPA in, enter the Apple ID, Start), or i4Tools (爱思助手: 应用游戏 → install a local
   IPA). The IPA is unsigned-but-ad-hoc on purpose: the sideloader re-signs it with the user's
   Apple ID, exactly like every game IPA this repository ships.
2. The first install from a given Apple ID needs Settings → General → VPN & Device Management →
   trust the certificate. A free Apple ID re-signs every 7 days, but a one-shot probe does not mind.
3. Open DmProbe and wait two seconds. The result is on the screen and in the file:
   **Files app → On My iPhone → DmProbe → probe-log.txt** (`UIFileSharingEnabled` in the app's
   Info.plist makes Documents visible there, and runs append, so nothing is lost).
4. Send the log back by sharing it from the Files app (long-press → Share → AirDrop / Mail /
   WeChat), or from i4Tools' app-file browser (DmProbe → Documents → probe-log.txt). If no new
   lines appeared, the app died before logging: send the crash report instead (Settings → Privacy
   & Security → Analytics Data → `DmProbe-*.ips`).

## Result: FEASIBLE (device run, 2026-10-26)

Run on an iPhone (iOS **27.0.1**, sideloaded IPA, probe built 2026-10-27). The full log:

```text
---- DmProbe run 2026-10-26 19:51:50 +0000 (probe built Oct 27 2026 03:48:01) ----
bundle:      /private/var/containers/Bundle/Application/62C345BC-…/DmProbe.app
executable:  /private/var/containers/Bundle/Application/62C345BC-…/DmProbe.app/DmProbe
iOS:         27.0.1 (iPhone)
framework file …/DmProbe.app/Frameworks/Probe.framework/Probe: present
dlopen("@executable_path/Frameworks/Probe.framework/Probe", RTLD_NOW)
  -> handle 0x66951e70
dlsym(handle, "probe_answer")
  -> probe_answer at 0x102878000 in …/Frameworks/Probe.framework/Probe (image base 0x102874000)
  -> probe_answer() = 42
RESULT: FEASIBLE - dlopen("@executable_path/Frameworks/Probe.framework/Probe") succeeded and probe_answer() = 42: a sideloaded app can load and call code in a framework inside its own bundle (route C is viable)
```

So the gate is passed: on a stock, non-jailbroken iPhone, after the sideloader re-signed the app
and every nested framework, iOS loads the nested framework from `@executable_path/Frameworks/`,
resolves a symbol in it and executes it. Route C is viable in principle.

**What this still does not prove** (design doc §R1, and the reasons are different):
- a framework carrying the game's working set — the many `__DM*W` sections (up to 255 per image),
  tens of MB of `__TEXT` — loads and executes like this one-function probe,
- the launcher's `vm_remap` of the game image's signed `__TEXT` into an anonymous address
  (copy = FALSE) is accepted for a sideloaded, re-signed framework,
- `getsectiondata` on a *dylib* header (the probe only used `dlsym`/`dladdr`),
- loading a framework that was re-signed by a free Apple ID and installed through a different
  sideloader than the probe's.

The next step is the first milestone of the plan on [#123](https://github.com/LNPANDY/NX2Apple/issues/123):
one real game as a framework, in a shell app, on a device.

## Reading the result

| Last line of probe-log.txt | Meaning |
|---|---|
| `RESULT: FEASIBLE - dlopen("@executable_path/Frameworks/Probe.framework/Probe") succeeded and probe_answer() = 42` | Route C is viable: a sideloaded app loads and calls code in a framework inside its own bundle. Proceed with the launcher shell + per-game frameworks. |
| `RESULT: BLOCKED - ... no suitable image found ... (no such file)` | The framework is not in the installed bundle: the sideloader stripped it or the layout broke. Record the sideloader and version, and fix the packaging before concluding anything about `dlopen`. |
| `RESULT: BLOCKED - ... code signature ... not valid` / `not signed` / `no Team ID` | The nested framework's signature was rejected: the sideloader failed to re-sign it, or iOS refuses its signature. Record the exact text and sideloader, and retry with another sideloader (or an `ldid`-signed IPA) before treating it as a platform refusal. |
| `RESULT: BLOCKED - ...` with any other `dlerror` text | Record the text verbatim with the device model, iOS version and sideloader. The attempt lines above it show which forms were tried. |

The failing fallbacks (relative and bare-name forms) always log `no suitable image found` texts —
that is their expected outcome, not a verdict. The verdict uses only whether some form loaded.

## What it does not prove

- **App Store review rules** (a policy question, not a technique one): irrelevant to sideloaded
  distribution, which is how this project ships.
- **Loading code that is not in the signed bundle** (streaming game payloads from disk — the
  original ROADMAP blocker): still expected to be blocked, since route C compiles each game's modules
  into its framework at packaging time, inside the signed bundle.
- **JIT, or anything about the game modules themselves**: the rewriter's output needs much more
  than one C function, and this probe only opens the door the launcher would walk through.

The build was self-checked on the Mac only (`codesign -vvv --verify --strict` on the framework,
the app, and the app extracted from the packed IPA again. `otool` load commands: the app's
`LC_RPATH @executable_path/Frameworks`, the framework's install name `@rpath/Probe.framework/Probe`,
`minos 26.0`, `lipo` arm64, `plutil` on both Info.plists, and `ldid` is not installed on this machine,
so codesign only). The device run is the user's step.

## Building it again

```
dm/ios/probe/build_probe.sh [out.ipa]      # default: probe-out/DmProbe.ipa
```

compiles both binaries with `xcrun -sdk iphoneos clang` (arm64, deployment target iOS 26.0), writes
the two Info.plists, ad-hoc signs the framework first and the bundle second (the same placeholder
order `build_ipa.sh` uses — the sideloader replaces both signatures), packs with
`dm/ios/tools/pack_ipa.py`, and re-verifies the extracted IPA before printing the path.
