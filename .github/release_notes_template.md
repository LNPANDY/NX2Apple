<!--
Template for the notes of a release. Copy it to a file, fill it in, delete these comments and the groups that stay empty.
Publish with `gh release edit <tag> --notes-file <file>`. Never paste notes from a chat: pasted text brings emojis along.

Rules (RELEASING.md, "Release notes" has the same list):
- Chinese first, English second, with the same content in both.
- No emojis, no pictograms and no symbols in the text (no warning signs, no flags, no arrows).
- No semicolons (also not the full-width one), no em-dashes (also not the Chinese double dash).
- Plain English and plain Chinese. Short sentences.
- People are written as @login, the owner as @LNPANDY.
- Every claim comes from the changelog row, the merged PRs or the issues. Nothing is invented.
- One change, one bullet. Do not put the changelog row into one long paragraph.
- Write the notes before the final tag is pushed or right after it. CI only writes a short body at first.
-->

<!-- One line: the version and what it is about. -->
**vX.Y.Z: the one thing this release is about.**

## 中文

<!-- First paragraph, only when players must act, for example "update now". Bold, plain words, no symbol. Delete it when no action is needed. -->
**App 版本是 0.7.3 或更早？请立即更新。** 一句话说明什么会出问题，一句话说明更新后会怎样。详情：链接。

<!-- The headline feature: a heading line and 3 to 5 sub-bullets. Delete the group when there is no headline feature. -->
**重点**

**功能的名称**
- 一个要点
- 一个要点
- 一个要点

<!-- One bullet per change: a bold lead, a colon, one or two plain sentences, the numbers as #N. -->
**新增**
- **改动的标题**：玩家现在能做什么，一两句话（#N、#M）

**修复**
- **修复的标题**：原来哪里出错，现在会怎样（#N）

**已知问题**
- **问题的标题**：哪里还不能用，暂时怎么办（#N）

<!-- Write "暂无已知问题" when there are none. -->

**系统要求**
- iOS 或 iPadOS 26 或更新版本

## English

<!-- The same content as the Chinese part, in the same order, with the same numbers. -->
**On 0.7.3 or older? Update now.** One sentence on what breaks and one on what the update does. Details: link.

**Highlights**

**Name of the feature**
- One point
- One point
- One point

**New**
- **Lead of the change**: what a player can do now, in one or two sentences (#N, #M)

**Fixed**
- **Lead of the fix**: what went wrong and what happens now (#N)

**Known issues**
- **Lead of the issue**: what does not work yet and what to do meanwhile (#N)

<!-- Write "None known" when there are none. -->

**Requires**
- iOS or iPadOS 26 or later

---

<!-- The install line (v0.7.2 and v0.7.3 had it). Keep it for a final release. -->
**Install:** download `NX2Apple-macOS-arm64.zip`, unzip, drag it to Applications. 中文：下载后解压，拖进「应用程序」。

<!--
Last, append the generated notes. They list the merged PRs with their authors and name first-time contributors. They are English only and not edited by hand. They replace a hand-written Credits section. Make them with:
  gh api repos/LNPANDY/NX2Apple/releases/generate-notes -f tag_name=<tag> -f previous_tag_name=<previous final tag> --jq .body
and add the output to the end of the notes file, below the install line. .github/release.yml sets the categories.
-->
