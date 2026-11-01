<!--
Template for the notes of a release. Copy it to a file, fill it in, delete these comments and the groups that stay empty.
Publish with `gh release edit <tag> --notes-file <file>`. Never paste notes from a chat: pasted text brings emojis along.

Rules (RELEASING.md, "Release notes" has the same list):
- English first, Chinese second, with the same content in both.
- No emojis, no pictograms and no symbols in the text (no warning signs, no flags, no arrows).
- No semicolons (also not the full-width one), no em-dashes (also not the Chinese double dash).
- Plain English and plain Chinese. Short sentences.
- People are written as @login, the owner as @LNPANDY.
- Every claim comes from the changelog row, the merged PRs or the issues. Nothing is invented.
- Write the notes before the final tag is pushed or right after it. CI only writes a short body at first.
-->

<!-- One line: the version and what it is about. Same in both parts if you keep it. -->
**vX.Y.Z: the one thing this release is about.**

## English

<!-- First paragraph, only when players must act, for example "update now". Bold, plain words, no symbol. Then what to do and where to read more. Delete it when no action is needed. -->
**On 0.7.3 or older? Update now.** One sentence on what breaks and one on what the update does. Details: link.

<!-- One group per kind of change, in this order. A bullet is a bold lead, a colon, a short plain explanation and the numbers as #N. -->
**New**
- **Lead of the change**: what a player can do now, in one or two sentences (#N, #M)

**Fixed**
- **Lead of the fix**: what went wrong and what happens now (#N)

**Known issues**
- **Lead of the issue**: what does not work yet and what to do meanwhile (#N)

<!-- Optional, only when something needs a word that is not a change: for example a new requirement or a changed default. -->
**Note**
- **Lead**: the point in one sentence

## 中文

<!-- The same content as English, in the same order, with the same numbers. Not a second set of facts. -->
**App 版本是 0.7.3 或更早？请立即更新。** 一句话说明什么会出问题，一句话说明更新后会怎样。详情：链接。

**新增**
- **改动的标题**：玩家现在能做什么，一两句话（#N、#M）

**修复**
- **修复的标题**：原来哪里出错，现在会怎样（#N）

**已知问题**
- **问题的标题**：哪里还不能用，暂时怎么办（#N）

**说明**
- **标题**：一句话说明要点

---

<!-- The install line closes the notes (v0.7.2 and v0.7.3 had it). Keep it for a final release. A release candidate gets its own body from CI. -->
**Install:** download `NX2Apple-macOS-arm64.zip`, unzip, drag it to Applications. 中文：下载后解压，拖进「应用程序」。
