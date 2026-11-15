# Release notes: English first, then Chinese

Every release body is written in **English first, then Chinese**, as two complete halves with a
`---` between them. This exists because the fork's users are mostly Chinese while the upstream
project and most contributors are not, and a release written in one language loses half of them.

**Do not interleave the languages.** Earlier releases alternated one Chinese line and one English
line, and the result was hard to read in both: a Chinese reader's eye had to skip every other line,
and the two halves could not be compared. Each language is written as a complete document, in the
same section order, and a reader picks one and reads straight through.

## The shape

```
## What this release does
<one paragraph>

## New            (optional: only when there is new functionality)
- …

## Fixes
- …

## Known issues
- …

## Install
- …

## Credits
- …

---

## 这一版做了什么
<一段>

## 新增           （可选）
- …

## 修复
- …

## 已知问题
- …

## 安装
- …

## 致谢
- …
```

The two halves use the **same headings in the same order** (the Chinese ones are the translations
of the English ones), and the same number of items under each heading. Item 2 in English is item 2
in Chinese, so a reader comparing the two does not have to map lists.

Rules that matter more than the template:

1. **English first.** It is the canonical text, and the Chinese half is written from it.
2. **Both halves say the same thing.** Not "a translation of the headline and a summary of the
   rest" — a user reading either half must learn everything the other one learns.
3. **Never split a section across the two halves.** All of Fixes is in one place, then all of
   修复 is in the other.
4. **Say what it does for the user, not what the commit did.** "游戏数据现在是一个文件，拷到手机上
   快得多" beats "switched romfs_arc.py to romfs_image.py" — and the English line says the same.
5. **State what is NOT shipped.** If the Windows build is not in the release, both halves say so in
   the same section (a reader who only reads one must not conclude the other platform shipped).
6. **Credit contributors by name in both halves**, with the PR number.

The app's own update sheet (`UpdateSheet.swift`) reads the body and shows one language: it splits on
the `**中文**` / `**English**` markers if they are there, and otherwise picks the lines whose
characters belong to the reader's language. A body in the shape above works with both paths, so
changing the template means checking that sheet's tests too.

## Where the text comes from

- `CHANGELOG.md` and `CHANGELOG.zh-CN.md` share an update-history table. A release row goes in both, the
  English one first (it is the canonical project history), then translated.
- The release body itself is written once, in both languages, and is what `gh release edit
  --notes-file` takes. Keep the file in `/tmp` while working, since the release is the record.
- If a fact differs per platform (a macOS-only fix), say which platform in the same sentence in both
  languages rather than relying on the reader's inference.

## A worked example (v0.4.7)

```markdown
## 这一版做了什么 / What this release does

**中文** 游戏数据现在打成一个 `romfs.img`（一个文件，不再是几十万个碎文件），拷到手机上快得多，
也可以整个放在外置硬盘上。DLC 跟着游戏数据走，不再塞进 IPA——IPA 更小，装得更快。

**English** Game data is now one `romfs.img` (a single file, not hundreds of thousands), which
copies to a phone far faster and can live on an external drive as a whole. DLC follows the game
data instead of going into the IPA, so the IPA is smaller and installs faster.

## 修复 / Fixes

- 依赖面板的语言切换现在翻译整个界面。
- The language toggle now translates the whole interface.
```

That example is what "both languages, same structure" means in practice: the Chinese paragraph and
the English paragraph carry the same facts, and the bullet list interleaves rather than splitting
into two lists.
