# Signed game payloads

PayloadKit is shared by the Mac launcher and the iOS shell. The desktop signs a fresh copy of a game's `FH` framework, packs it, and transfers it into the installed shell. The shell validates and publishes it without modifying its installed app bundle.

Existing bundled games stay available. Imported generations override the matching title, while saves, settings, bookmarks, and RomFS data keep their existing locations. Updating a title already loaded in this process takes effect after a cold app launch. A successful transfer is reported separately from shell acceptance.

## Protocol version 2

`game.nxpayload` starts with eight bytes `NXPAYLD1`, followed by an eight-byte unsigned big-endian JSON-header length. The bounded JSON header is a `PayloadManifest`. The archive format remains version 1. Regular-file bytes follow in manifest order. The format has no compression, symlinks, or external paths. File sizes and SHA-256 digests describe the final signed bytes.

Send files into `Documents/PayloadInbox/<generation>/` and send `ready.json` last. Large archives use numbered parts of at most 512 MiB. The completion marker records total bytes, archive digest, generation, and part size. Joining and extraction stream bounded chunks. Multipart game data uses the shell's existing startup join, so reopen the shell after a large data transfer. Code-payload intake alone does not mean that game data is ready.

The shell publishes code to `Documents/GameBundles/<title ID>/<generation>/` and atomically updates `payload-registry.json`. Game data for that payload is transferred separately to `Documents/games/<title ID>/payload-data/<generation>/`. The selected code generation selects its data folder too, so an update never overwrites a running game's resources. Existing title-root data and picked folders remain supported, and saves stay at the original title root. Capability protocol 2 requires a host that understands these data paths. It writes `Documents/PayloadReceipts/<generation>.json` with `active`, `restartRequired`, or `rejected`. Incomplete transfers remain pending. After writing a receipt, the shell removes the completed inbox transaction, including rejected archives. Incomplete transfers remain available to finish. Replaying a receipted generation is idempotent and discards its duplicate archive.

Queued transfers are processed by completion-marker modification time, oldest first, with the generation ID breaking ties. Each title also records the latest accepted completion in its registry selection. An older transfer that finishes in a later scan, including after a restart, is rejected instead of replacing the newer active or pending selection. Registries without this optional metadata still load. A transaction already selected in the registry can recover its missing receipt without replacing the previous generation or queuing its loaded active generation again.

Reading an existing library does not require successful startup writes. Directory and capability-file write failures are reported through `startupWriteError`, and intake retries directory preparation. A cold start without pending generations does not rewrite the registry. The host always restores committed imports to its catalogue, even when intake fails. `PayloadProcessingError` carries outcomes already committed before a receipt failure so title restoration and successful earlier imports are preserved.

`Documents/shell-payloads.json` advertises the protocol, bundle ID, signing team, glue ABI, OS version, and installed executable digest. The launcher matches the cached signed shell, extracts its public certificate fingerprint, and selects that exact signing identity from the Mac's keychain. Private keys stay on the Mac. Once support has been negotiated, a transient handshake failure does not trigger a shell reinstall.

Archive digests verify integrity. Kernel code-signature attachment and library validation verify native code acceptance. The shell checks each native image before publication and again before Play. Imported code inherits the installed shell's process entitlements, including its memory allowance. Payload transfer does not renew the shell's provisioning profile.

Framework roots and their contents must be real directories and regular files, with no symbolic links. The desktop signs a fresh stage and commits its local framework mirrors with the library file. A failed library write restores replaced mirrors, and a successful write releases the old mirror copies.

## Checks

```sh
swift test --package-path frontend-ios/PayloadKit
swift build --package-path frontend-ios
swift test --package-path frontend-ios
swift build --package-path frontend
swift test --package-path frontend
```

The storage tests inject signature validation for synthetic, deliberately non-cryptographic fixtures. A separate test confirms that the production validator rejects those fixtures. Production uses kernel validation. Phone-side signing, Files import, and downloads are outside the initial implementation.
