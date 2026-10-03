## 改了什么，为什么 · What and why

<!-- 一两句话。关联的 issue：Fixes # · One or two sentences. Linked issue: Fixes # -->

## 检查清单 · Checklist

- [ ] 我运行了 `scripts/verify.sh`，全部通过 · I ran `scripts/verify.sh` and it passes
- [ ] 没有提交私人数据或密钥（术语表、录音、转写原文、API Key）· No private data or secrets (glossaries, recordings, transcript text, API keys)
- [ ] 用户可见的改动已写进 `CHANGELOG.md` 的 `[Unreleased]`，必要时更新了说明书 · User-visible changes are in `CHANGELOG.md` under `[Unreleased]`, and the manual is updated if needed

## 是否改变插入语义或热键？ · Does this change insertion semantics or the hotkey?

<!-- 涉及文字插入的时机、方式、次数，或右 Option / Esc / event tap / 权限时，选“是”并回答下面的问题。需要维护者真机验收。
     Choose "Yes" if it touches when, how or how often text is inserted, or Right Option / Esc / the event tap / permissions. A maintainer will re-test on a real machine. -->

- [ ] 否 · No
- [ ] 是 · Yes

若“是”· If yes:

- 一次说话仍然最多插入一次，音频仍然先落盘，依据是什么？ · Why does an utterance still insert at most once, and audio still reach disk first?
- 测试过的 macOS 版本、芯片、三项授权状态 · macOS version, chip and the state of the three permissions you tested:

## 是否改写文字？ · Does this rewrite text?

<!-- 引入大模型改写、润色、补全、翻译或纠错的改动，必须在这里说明默认是否开启，以及为什么不违背“不改原话”。
     Any LLM rewriting, polishing, completion, translation or correction must be explained here: whether it is on by default, and why it keeps the verbatim promise. -->

- [ ] 否 · No
- [ ] 是 · Yes（请说明 · explain）:
