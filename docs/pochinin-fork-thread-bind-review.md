# Hermes gateway: session fork → 新 Discord thread bind — 独立設計レビュー (2号 Fable)

- 作成: 2026-08-18 / 2号 (Mac-mini-3.local) Fable owner lane
- 対象: 「Discord thread/会話を別 thread に fork する」機能 (= `/branch`/`/fork` 相当で新 Discord thread を作成し、コピーした Hermes session を bind して履歴を引き継ぐ)
- 位置づけ: 1号実装に対する独立レビュー・設計パケット。同 branch に **参照プロトタイプ** (`pochinin/fork-thread-2gou-review`) を同梱。プロトタイプはマージ候補ではなく設計の実証。

---

## 0. 結論 (recommendation)

**コマンド面は `/branch --thread [name]` のフラグ拡張一択。新コマンド `/fork` は不可** — `fork` は既に `/branch` の alias として登録済みで衝突する (`hermes_cli/commands.py:168-169`)。

実装は既存 3 部品の合成で成立し、新規発明はほぼ不要:

1. **fork row 作成 + 履歴コピー**: `/branch` の既存機構をそのまま流用 (`gateway/slash_commands.py:4923-5071`)。ただし routing columns を **現在の chat ではなく新 thread のもの** にして書く。
2. **thread 作成**: Discord adapter の `_create_thread` 機構を by-id 解決の新 capability `create_session_thread()` として公開 (`plugins/platforms/discord/adapter.py:7087` の Interaction 依存を除去した版)。
3. **bind**: (a) SessionStore への新 primitive `bind_session_key()` (in-memory 事前 bind) + (b) fork row の routing columns 経由の **既存 DB recovery** (`gateway/session.py:2483` → `hermes_state.py:5050`) の二重化。(b) は gateway 再起動を跨いでも効く。

現在の `/branch` との決定的な違い: **現 chat の session は一切動かさない** (switch なし / parent end なし / agent cache evict なし / security state clear なし)。元 thread は元 session のまま、新 thread が fork を持つ。

---

## 1. 現状マップ (facts / file:line)

| 部品 | 場所 | 要点 |
|---|---|---|
| `/branch` gateway handler | `gateway/slash_commands.py:4923-5071` | 同一 chat 上で新 session に乗り換える方式。routing columns を CREATE 時に全部渡す (#82633 crash-window 対策)。`api_content` sidecar を保存して provider prompt cache を温存 (5041-5044)。 |
| `fork` alias | `hermes_cli/commands.py:168-169` | `CommandDef("branch", ..., aliases=("fork",))` — `/fork` 単独の新設は衝突 |
| dispatch | `gateway/run.py:16993` | `canonical == "branch"` の if チェーン。alias 解決は `hermes_cli.commands.resolve_command` (16609-16613) |
| API fork | `gateway/platforms/api_server.py:3641-3686` | `POST /api/sessions/{id}/fork`。routing columns なし・parent を `end("branched")`・`replace_messages` 使用。**この 3 点はどれも thread-bind 用途では真似てはいけない** (後述 §3) |
| Discord thread routing 規約 | `plugins/platforms/discord/adapter.py:1638-1651` | thread 内メッセージは `chat_id == thread_id == <thread channel id>`, `chat_type="thread"` |
| session key | `gateway/session.py:1090` (`build_session_key`) | Discord thread (default 共有): `<ns>:discord:thread:<tid>:<tid>` (user_id なし)。`prospective_thread_id` の auto-thread 継続機構あり |
| key→session 解決 | `gateway/session.py:2483` (`_get_or_create_session_impl`) | key 未登録 → `_needs_recover=True` → `_query_recoverable_session` |
| DB recovery | `hermes_state.py:5050` (`find_latest_gateway_session_for_peer`) | exact `session_key`+`source` 一致で `ended_at IS NULL` 行を最優先。reset boundary fence あり (#68539) |
| recovery の scope guard | `gateway/session.py` (`_recovered_row_matches_source_scope`) | **Slack 専用** — Discord は無条件通過 |
| thread 作成 (adapter) | `adapter.py:7087` (`_create_thread`) | Interaction 前提。direct + seed-message fallback。DM 拒否。`_thread_parent_channel` = `channel.parent or channel` (thread 内から呼ばれたら親 channel に作る) |
| `/thread` app command | `adapter.py:6395` (`_handle_thread_create_slash`) | thread 作成 + `ThreadParticipationTracker.mark` + starter があれば `_dispatch_thread_session` で **新規** session 起動。fork bind は無い |
| agent 側 thread 作成 | `tools/discord_tool.py:586` | REST 直叩き。bind 不可能 (store に触れない) |
| fork 独立性 | `hermes_state.py` `get_resume_conversations` (~10279) | `_is_explicit_branch_session` (= `model_config._branched_from` marker) の session は compression lineage 読みから除外 → **fork 後に parent へ書かれた行が fork に漏れない** |
| marker 意味論 | `hermes_state.py:8480-8494` | branch 可視性は (1) `_branched_from` marker (安定・#20856) OR (2) legacy heuristic (parent が `branched` で end)。**marker があれば parent を end する必要はない** |
| alternation 修復 | `gateway/session.py:3850-3890` (`load_transcript`) | `get_messages_as_conversation(repair_alternation=True)` — restore 境界で user;user wedge を一度だけ修復 |
| compression 追従 | 同上 | `load_transcript` は reroute chain + compression tip を解決してから読む → parent が compression tip でもコピーは self-contained (summary 込み model view) |
| activity timestamp | `hermes_state.py:6540` (`touch_session_activity`) / `append_messages_batch` (9118) | メッセージコピーは `last_activity_at` を**更新しない** (NULL のまま) → recovery のランク・reset 判定は `started_at` (= fork 作成時刻) で評価される |
| sessions schema | `hermes_state_common.py:259-318` | `session_key/chat_id/chat_type/thread_id/user_id/origin_json/display_name/parent_session_id/model_config` 全列実在 |
| AsyncSessionStore | `gateway/session.py:1221-1235` | `__getattr__` 自動委譲 — store の新 sync メソッドは wrapper 変更なしで await 可能 |
| adapter 参照 | `gateway/slash_commands.py:141` 等 | handler から `self.adapters.get(platform)` / `_adapter_for_source` が既存パターン |
| i18n | `locales/en.yaml:89-94` (`gateway.branch.*`) | `from agent.i18n import t` |

---

## 2. 設計

### 2.1 UX

```
(既存 thread / channel 内で)
/branch --thread 認証リファクタ案B
→ 🧵 <#新thread> を作成し、この会話のコピー (N messages) を bind
→ 元 thread は現行 session のまま続行。新 thread は独立して続く
```

- `--thread` なし `/branch` は完全従来動作 (後方互換)。
- `/fork --thread ...` も alias 経由で同じ経路に落ちる。
- DM では不可 (Discord 仕様: DM に thread は作れない) → 明示エラー。
- capability を持たない platform (Telegram 等) → 明示エラー (`create_session_thread` を持つ adapter のみ)。Telegram forum topic 対応は将来同じ capability 名で拡張可能。

### 2.2 制御フロー (gateway `_handle_branch_command` 内 `--thread` 分岐)

```
1.  transcript ロード (既存 /branch と共通; 空なら no_conversation)
2.  adapter capability gate: adapter.create_session_thread が無ければエラー (row 未作成のまま)
3.  タイトル決定 (name 引数 or get_next_title_in_lineage — 既存ロジック)
4.  thread 作成: await adapter.create_session_thread(chat_id, thread_id, name=title, ...)
      - 失敗 → エラー返して終了 (row 未作成; 副作用ゼロ)
5.  new_source 構築: dataclasses.replace(source,
        chat_id=new_tid, chat_type="thread", thread_id=new_tid,
        chat_name=<thread 名>, parent_chat_id=<親channel>,
        message_id=None, prospective_thread_id=None,
        auto_thread_created=False, auto_thread_initial_name=None)
6.  new_session_key = self._session_key_for_source(new_source)   ← 文字列手組み禁止
7.  create_session(fork_id, source=platform,
        parent_session_id=current, model_config={"_branched_from": current},
        user_id, session_key=new_session_key,
        chat_id=new_tid, chat_type="thread", thread_id=new_tid,
        origin_json=json(new_source.to_dict()), display_name=<thread 名>)
      ← routing columns は CREATE 時に全部 (#82633 と同じ理由; 以降のどこで死んでも recovery 可能)
8.  append_messages_batch(fork_id, <既存 /branch と同一 projection>, chunk_rows=500)
      ← api_content sidecar 維持。replace_messages は使わない
9.  set_session_title(fork_id, title)
10. store.bind_session_key(new_session_key, fork_id, origin=new_source, display_name=...)
      ← 新 primitive (in-memory 事前 bind)。失敗しても 7 の routing columns で recovery が拾う
11. adapter.send(new_tid, intro) — best-effort (「⑂ forked from … (N messages)」)
12. 現 chat に確認応答 (<#new_tid> リンク + 件数)
```

**やらないこと (重要)**: `switch_session` / parent の `end_session` / `_clear_session_boundary_security_state(現key)` / `_evict_cached_agent(現key)`。現 chat は無変更。

### 2.3 新 primitive: `SessionStore.bind_session_key()`

`switch_session` (gateway/session.py:3364) の変種。相違点:
- 既存 entry を **要求しない** (switch は `key not in _entries → None`)
- 旧 session の end を**しない** (bind 先 key に旧 session が存在しないことが前提)
- **collision guard**: key に既に別 session の entry がある場合は拒否 (None 返し) — 「既存 thread への bind」を構造的に不可能にする
- entry 作成 → `_save()` → `_record_gateway_session_peer(session_id, key, origin)` (self-healing 側の peer record; `include_compression_ancestors` は不要 — fork は生まれたてで lineage なし)
- `reopen_session` 不要 (row は未 end)

AsyncSessionStore は `__getattr__` 委譲なので wrapper 変更不要。

### 2.4 adapter capability: `create_session_thread()`

`_create_thread` (Interaction 前提) の by-id 版。gateway から platform 非依存に呼べる **optional capability** (hasattr ゲート):

```python
async def create_session_thread(*, chat_id, thread_id=None, name,
                                requested_by="", auto_archive_duration=1440) -> dict
# {"success": True, "thread_id": ..., "thread_name": ..., "parent_channel_id": ...}
# or {"error": "..."}
```

- channel 解決: `self._client.get_channel(int(chat_id)) or await fetch_channel(...)` (既存パターン: adapter.py:3944 等)
- thread 内から呼ばれたら `_thread_parent_channel` で親 channel に作成 (Discord は thread のネスト不可)
- DM channel → 明示エラー
- direct `create_thread` + seed-message fallback (既存 `_create_thread` と同一)
- 成功時 `self._threads.mark(thread_id)` (participation 追跡 — @mention なしで応答するため。`/thread` と同じ)

---

## 3. 落とし穴レビュー (mission 指定 8 項目 + 追加 3)

### 3.1 prompt-cache invalidation — 対処済み設計
- コピーは `/branch` と同一 projection で `api_content` sidecar を保持 (`extract_api_content_sidecar`, slash_commands.py:5044) → fork 初回 turn は parent の wire bytes を replay = provider cache warm。
- parent 側は**無変更** (行追加・end なし) → parent の cache も無傷。
- **`replace_messages` は使用禁止**: TEXT を再 dump して二重 encode する既知問題 (`hermes_state.py:8959` コメント)。API fork (api_server.py:3672) はこの経路だが、gateway 側は `append_messages_batch` が正。

### 3.2 role alternation — 既存機構でカバー
- コピーは verbatim。fork 初回ロード時に `load_transcript` → `get_messages_as_conversation(repair_alternation=True)` が user;user wedge を restore 境界で一度だけ修復 (gateway/session.py:3885-3890)。parent 末尾が未応答 user turn でも安全。

### 3.3 source/fork 独立性 — marker が生命線
- `model_config._branched_from` を **create_session の同一 write で** 付与 (atomic)。これが無いと:
  1. `get_resume_conversations` の lineage 除外が効かず、**fork 後に parent へ書かれた行が fork の表示履歴に漏れる** (hermes_state.py:10279-10283 の設計意図が壊れる)
  2. `/sessions`・`/resume` の可視性が legacy heuristic (parent の end_reason=='branched') 頼みになる — 本設計は parent を end **しない**ので、marker が無いと fork が listing から消える
- 逆方向 (fork→parent) は session_id 行分離で構造的に漏れない。

### 3.4 gateway routing key 衝突 — 構造的に回避
- 新 thread id は Discord snowflake で一意 → key `<ns>:discord:thread:<tid>:<tid>` は必ず新規。
- reset boundary fence (#68539) は同一 key の過去行が対象 — 新規 key に過去行なし → recovery を阻害しない。
- 「既存 thread への bind」は本設計に存在しない (常に新規作成) + `bind_session_key` の collision guard で二重に防止。
- `prospective_thread_id` (auto-threading 連携, session.py:189-207) との干渉: `--thread` を **channel** (auto-thread 有効) で打った場合、コマンド応答自体が auto-thread に流れる可能性がある。correctness には影響しない (key が別) が UX がややこしい。new_source では `prospective_thread_id=None` にクリアすること (dataclasses.replace のコピー残り対策)。

### 3.5 コピーされる tool outputs / attachments — 現状維持が正解
- tool_calls / tool_call_id / tool_name / reasoning* / codex_* は verbatim コピー ( `/branch` と同一)。
- `platform_message_id` は projection が**落とす** — 旧 thread のメッセージ参照なので fork では無効。落とすのが正しい (pin/reply 系操作が旧 thread を誤操作しない)。
- Discord CDN URL 等 content 内の参照は読み取り専用でそのまま有効。
- process registry / checkpoint は session_key・session_id スコープ → fork へ継承されない = 独立性として正しい (fork 側で `/stop` しても parent の background process は殺せない)。

### 3.6 compression state — 既存解決に乗る
- `load_transcript` が reroute chain + `get_compression_tip` を解決してから読む (gateway/session.py:3867-3877) → parent が compression lineage の tip でも、コピーは summary 込みの self-contained な model view。
- fork row は compression 系列 (cooldown/streak/ineffective) がクリーンな新規行。
- fork は `parent_session_id` を持つが `_branched_from` marker により compression child と区別される (`_is_explicit_fork_child_row`, hermes_state.py:10853)。
- bind の peer record で `include_compression_ancestors=True` を**渡さない**こと (fork に ancestors はいない; switch_session の resume 用フラグ)。

### 3.7 parent_session_id 意味論 — overload に注意
- `parent_session_id` は compression fork / delegate / 明示 branch の 3 用途で overload (hermes_state.py:4458 コメント, 8480-8494)。区別は marker (`_branched_from` / `_delegate_from`) と end_reason 系 heuristic。
- 本設計は `/branch` と同じ marker 付与で「明示 branch」に分類される。**API fork の「parent を end('branched')」を真似ない** — 現 thread の session を end したら現 thread が壊れる。marker があれば end は不要 (#20856 の設計意図どおり)。
- cwd 継承 (hermes_state.py:4458-4468, project sidebar 用) は create_session 内の既存処理に乗る ( `/branch` parity)。

### 3.8 platform thread identifier — 最重要の 1 行
- Discord 規約: thread では `chat_id == thread_id == <thread channel id>`, `chat_type="thread"` (adapter.py:1638-1651)。fork row と new_source が **両方この規約に従わないと key が byte 一致せず fork は永久に unroutable**。
- 実装規則: key は `self._session_key_for_source(new_source)` / `store._generate_session_key` 経由でのみ導出。文字列手組み・format 直書きは禁止。
- must-have test #1 がこの不変条件を direct に検証する。

### 3.9 (追加) reset policy との相互作用 — 挙動を文書化
- fork 直後: `last_activity_at=NULL` (コピーは更新しない, §1) → recovery / entry の評価は `started_at`=fork 時刻 → 即利用なら reset は発火しない。
- fork 作成後**長期放置**して初投稿した場合: idle/daily reset policy が recovery 時に発火し、fork row は reset boundary に昇格 → 新 thread は fresh session で始まる (通常 session と同じポリシー適用)。`/resume <fork名>` で救済可能。
- これは仕様として許容 (gateway 全体の reset 意味論と一貫)。intro メッセージに fork session 名を含めておくと救済導線になる。

### 3.10 (追加) 共有 thread 意味論
- default (`thread_sessions_per_user=False`) では thread key に user_id が入らない → **fork 作成者以外が新 thread に最初に投稿しても** exact key match (user_id 無視) で fork を拾う。Discord thread の期待 UX (thread 参加者全員で 1 session) と一致。
- `find_latest_gateway_session_for_peer` の fallback tuple query は user_id を要求するが、これは exact key が消えた場合の保険であり主経路ではない。

### 3.11 (追加) `/branch --thread` の名前衝突エッジ
- branch 名を文字どおり `--thread` にしたいケースは不可能になる (フラグ解釈が勝つ)。許容し、help 文字列に明記。

---

## 4. Must-have tests (1号 patch の受け入れ条件)

1. **key byte 一致 (最重要)**: fork row の `session_key` が、実 inbound thread メッセージの source (`chat_id=tid, thread_id=tid, chat_type="thread"`) から `build_session_key` で導出した key と一致する。
2. **restart recovery**: sessions.json を持たない新規 SessionStore (再起動シミュレーション) で新 thread の source から `get_or_create_session` → fork の session_id が返り、transcript 件数が一致する。
3. **parent 不変**: コマンド後、現 key の entry は同じ session_id のまま / parent row の `ended_at IS NULL` / parent へ追記した行が fork の履歴に現れない。
4. **api_content sidecar**: コピー後の fork rows に sidecar が保存されている (cache warm 経路)。
5. **marker**: `model_config._branched_from == parent_id` / `/sessions` 系 listing に fork が可視。
6. **DM 拒否**: DM source → 明示エラー、thread 未作成、row 未作成。
7. **capability なし platform**: adapter に `create_session_thread` が無い → 明示エラー、row 未作成。
8. **thread 作成失敗**: adapter がエラーを返す → row 未作成 (順序保証)。
9. **空 transcript**: no_conversation エラー、thread 未作成。
10. **bind collision guard**: 既に entry がある key への `bind_session_key` → 拒否。
11. **(adapter 側)** `create_session_thread` が thread 内から呼ばれたら親 channel に作成 / DM でエラー / `ThreadParticipationTracker.mark` を呼ぶ。
12. **alternation**: parent 末尾が user turn の状態で fork → fork 初回 `load_transcript` が修復済み列を返す。

## 5. 1号 patch レビューチェックリスト

- [ ] `/fork` を新コマンドとして追加していないか (alias 衝突)
- [ ] session_key を文字列手組みしていないか
- [ ] routing columns (user_id/session_key/chat_id/chat_type/thread_id/origin_json/display_name) を create_session の**引数**で渡しているか (後追い backfill は crash window)
- [ ] `_branched_from` marker があるか
- [ ] parent を end していないか / switch_session を呼んでいないか / 現 key の agent cache evict・security clear をしていないか
- [ ] `replace_messages` を使っていないか
- [ ] thread 作成失敗時に row を作らない順序か
- [ ] new_source で `prospective_thread_id` / `message_id` / auto_thread_* をクリアしているか
- [ ] DM・非対応 platform のエラーパスがあるか
- [ ] `ThreadParticipationTracker.mark` を呼んでいるか (呼ばないと @mention 必須 thread になる)
- [ ] i18n keys (`locales/en.yaml` の `gateway.branch.*`) を追加したか
- [ ] `hermes_cli/commands.py` の args_hint を更新したか
- [ ] 上記 must-have tests に相当するテストがあるか (特に #1, #2, #3)

## 6. 参照プロトタイプ

この branch (`pochinin/fork-thread-2gou-review`) に上記設計の検証実装を同梱:

- `gateway/session.py` — `SessionStore.bind_session_key()`
- `gateway/slash_commands.py` — `_handle_branch_command` の `--thread` 分岐 + `_handle_branch_to_thread()`
- `plugins/platforms/discord/adapter.py` — `create_session_thread()`
- `locales/en.yaml` — `gateway.branch.thread_*` keys
- `hermes_cli/commands.py` — args_hint
- `tests/gateway/test_branch_thread_bind.py` — must-have tests #1-#10 の実装

プロトタイプは設計実証が目的。1号実装がこの設計と同型なら受け入れ、相違点は §5 チェックリストで判定する。
