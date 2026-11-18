# 共用契約

六段都會用到的格式與規則只寫在這裡，各段的檔案只引用。實作時改到這裡的任何一條，要在同一個 PR 改這個檔。

標「（採建議 Cn）」的地方，是各票互相矛盾或沒接上、這份 spec 先照建議寫的；清單與理由在 [open-issues](open-issues.markdown)。

## 1. 名詞

- **議題**：看板上的一張卡。有名稱、一行目標、所在佇列與順序。一建立就排在佇列最後，不等誰確認（C52）。可以沒有任何 agent。
- **議題 id**：議題成立時給的穩定識別碼，改名不變。所有指向議題的地方都用它。
- **task**：firstmate 原意，一個 worker 跑的一件事。**agent** 是執行某個 task 的 worker，一個 agent 只屬於一個議題。
  home 還有紀錄的 task 照它的 `kind` 判斷（secondmate 自己不是 agent）；home 已經沒有的 task，只有帳本記過它的 worker 生命週期（`task.dispatched`、`task.pr_ready`、`task.merged`、`task.cleaned_up` 任一筆），而且最近一次派工不是 secondmate 時，才算已經結束的 agent。
  所以退役 secondmate 自己的事件、遠端 secondmate 的回報通道（`parent-replies`，只有狀態行）都不是 agent；它們的事件仍在更新裡，有標記就歸那個議題（C53）。
- **home**：一個 firstmate home。主 home 記作 `main`；secondmate home 用它的 secondmate id。task id 只在單一 home 內唯一，所以指 task 一律用 (home, task id)。
- **議題標記**：某個 home 裡一個 task 屬於哪個議題的紀錄，建立 backlog 項目時寫下，最晚在派工前；每個 home 只對自己的 task 持有正本。
- **歸併**：把一個 agent 歸到一個議題，或把一個議題併進另一個議題。對 agent 而言就是在它所在的 home 補寫一筆議題標記。
- **未分類區**：還需要一個議題的東西：沒有有效標記、還在跑的 agent，沒有歸屬的待決事項、worker 提問與這些 agent 的摘要，沒標議題的排隊項目。
  已經結束、沒有有效標記的 agent 與它們的摘要摺在最後的「已結束、沒標議題 N」，仍可歸併（C53）。
- **要你動手的項目**：要使用者親手做的事（sudo 指令、登入）。底層是主 home 的一個 captain hold，原因以 `動手：` 開頭，那一行其餘的字是要做什麼。只有主 home 的 hold 算；secondmate home 裡同樣開頭的 hold 仍是一般的待決事項。
  之後的每一行帶一個標籤：`說明：` 是一行說明（不是指令，沒有複製鈕），`指令：` 開始一個指令，`續：` 是上一個指令的下一行；標籤後面的字原樣保存。
  一個項目可以沒有說明、沒有指令，也可以有好幾個指令（C54）。
  之後有任何一行沒有標籤的，是 C54 之前寫的舊紀錄：第一行之後全部當成一個指令，和以前一樣。
- **待決事項**：等使用者回答的 captain hold。**worker 提問**是狀態行裡的 `needs-decision`，對象是 first mate，看板只列出、不能作答。
- **燈號**：待你決定、卡住、進行中、完成、未知，共五種。
- **直送**：從看板把訊息送給某一個 agent，不經主 first mate。
- **里程碑**：`ready`、`report`、`failed`、`landed` 四種結果。**里程碑摘要**是 first mate 在里程碑發生時寫的一到三句。
- **系統紀錄**：看板自己寫的一行紀錄（議題確認、歸併、在看板作答、提議關閉），不經模型。
- **結果不明**：寫入已送出、不知道有沒有生效、重送可能重複。**未送達**：可以安全重送，但重試次數用完。**失敗**：確定沒生效。

## 2. fork 裡新增的檔案

看板只新增檔案，不改上游既有的檔案；例外有兩處：`bin/fm-session-start.sh` 裡的呼叫點（第 11.3 節），以及 [open-issues](open-issues.markdown) C19 的 `bin/fm-captain-hold.sh` `hold --on-answer` 與它在既有的 `tests/fm-captain-hold-lifecycle.test.sh` 裡的測試（第 11.2 節）。
上游合併進 `carry` 時這些檔可能衝突，衝突時保留這幾行。

| 路徑 | 內容 | 哪一段加入 |
| --- | --- | --- |
| `bin/fm-topic.sh` | 議題指令，Bash | 一（之後各段加子命令） |
| `bin/fm-topic-board-read.sh` | 唯讀彙整腳本，Bash | 一 |
| `bin/fm-topic-lib.sh` | 上面兩支共用的函式（id 檢查、查同機 secondmate 的 home），只被 source | 一 |
| `bin/fm-topic-session-start.sh` | 開 session 時檢查看板服務、沒在跑就啟動，印啟動摘要裡的那一行，Bash | 上線後 |
| `topic-board/src/` | TypeScript 原始碼：服務、node client、頁面腳本 | 二起 |
| `topic-board/dist/` | `tsc` 的編譯結果，提交進 git；執行期只跑這裡的 `.js` | 二起 |
| `topic-board/public/` | 靜態頁面：`index.html`、`board.css`、`icon.svg` | 五 |
| `topic-board/rules/` | 三個規則範本，副檔名 `.md.tmpl` | 六 |
| `topic-board/spec/` | 這份 spec，副檔名 `.markdown` | 一 |
| `topic-board/test/` | fork 自己的測試與 `run.sh` | 一起 |
| `topic-board/package.json`、`pnpm-lock.yaml`、`tsconfig.json`、`.gitignore` | 只有開發期相依；`.gitignore` 忽略 `node_modules/` 與 `.metrics/` | 二 |
| `FORK-SETUP.markdown`（根目錄） | 新機器從零安裝 fork 與看板的說明；`topic-board/test/check-guide.sh` 檢查它引用的名稱 | 上線後 |

硬性限制（都實測過，見 [verification](verification.markdown)）：

- fork 裡不能新增任何追蹤的 `*.md`、`*.mdx`、`*.rst`、`*.txt`，也不能在 `docs/examples/` 加檔。上游的 `bin/fm-doc-audience-check.sh` 要求這些檔全部登記在既有的 `docs/documentation-audiences.json`。所以新目錄裡不放 `README.md`。
- 不能追蹤 `data/`、`state/`、`config/`、`projects/`、`.no-mistakes/` 底下的檔（上游 `.gitignore` 與 CI 的 invariants 都擋）。
- 不在 `tests/` 新增任何檔。上游的 `fm-test-run.sh --check-coverage` 限制沒有時間量測的 serial 測試不超過 15%，目前是 44/297，多一個 `tests/*.test.sh` 就超標；量測表在上游的 `bin/fm-test-run.sh` 裡，不能改（採建議 C6）。
- `bin/fm-topic.sh` 與 `bin/fm-topic-board-read.sh` 要通過上游釘住版本的 ShellCheck（`bin/fm-lint.sh <檔>`）與 bash 3.2 的語法檢查（`/bin/bash -n`，macOS 內建版本），不直接呼叫 `bd`。
- `fm-on.sh` 只執行遠端 code root 裡 git 追蹤、可執行、非 symlink 的 `bin/fm-*.sh`，所以遠端要用到的兩支都在 `bin/`、都要 `chmod +x` 後提交。

## 3. 執行期的檔案（都在主 home，不進 git）

| 路徑 | 權限 | 內容 | 誰寫 |
| --- | --- | --- | --- |
| `data/topics.json` | 0644 | 沒封存的議題 | 只有看板服務 |
| `data/topics-archive.json` | 0644 | 已封存的議題 | 只有看板服務 |
| `data/topic-board/events.jsonl` | 0644 | 各 home 的帳本事件加系統紀錄，只追加 | 只有看板服務 |
| `data/topic-board/summaries.jsonl` | 0644 | 里程碑摘要，只追加 | 只有看板服務 |
| `data/topic-board/offsets.json` | 0644 | 每個 home 的帳本 offset 與前綴雜湊 | 只有看板服務 |
| `data/<task-id>/topic` | 0644 | 議題標記，每個 home 各自一份 | `fm-topic.sh tag` |
| `state/topic-board/` | 0700 | 下面這些檔的目錄 | 服務；`install-rules` 在它不存在時也會建 |
| `state/topic-board/board.sock` | 0600 | Unix socket | 服務 |
| `state/topic-board/token` | 0600 | 瀏覽器用的 token | 服務 |
| `state/topic-board/port`、`pid` | 0600 | 實際的埠、服務的 pid | 服務 |
| `state/topic-board/startup-error` | 0600 | 上一次啟動失敗的原因，一行 JSON；啟動成功就刪掉 | 服務 |
| `state/topic-board/start.lock/` | — | 啟動鎖（目錄），裡面記持有它的 client 的 pid | node client |
| `state/topic-board/service.log`、`service.log.1` | 0600 | 服務的 stdio | 服務 |
| `state/topic-board/audit.jsonl` | 0600 | 稽核紀錄，只追加 | 服務 |
| `state/topic-board/rules-backup/` | 0700 | 偏好檔的備份 | `install-rules` |
| `config/topic-board-port` | — | 選用，一行埠號 | 使用者 |
| `config/fleet-ledger` | — | 上游的帳本旗標，每個 home 各一 | `fm-topic.sh setup` |

每次改寫整個檔（`topics.json`、`topics-archive.json`、`offsets.json`、`token`、`port`、`pid`）都用同目錄的暫存檔 `<檔名>.tmp-<pid>` 加 rename。

### 3.1 `data/topics.json`

```json
{
  "v": 1,
  "next_seq": 3,
  "queues": { "high": ["billing"], "normal": ["t2"], "later": [] },
  "topics": {
    "billing": {
      "name": "帳務重構", "goal": "把扣款流程搬到新服務",
      "status": "confirmed", "created_at": "2026-11-16T02:00:00Z",
      "close_proposal": { "at": "2026-11-17T01:00:00Z", "reason": "三個 PR 都已合併" }
    }
  },
  "merged": { "old-id": "billing" },
  "history": [
    { "at": "2026-11-18T01:00:00Z", "kind": "renamed", "topic": "reports", "name": "帳務報表", "from_name": "報表" },
    { "at": "2026-11-20T01:00:00Z", "kind": "merged", "topic": "billing", "name": "帳務重構",
      "from": "reports", "from_name": "帳務報表", "reason": "和帳務是同一件事", "by": "command" }
  ],
  "todos": {
    "mac-todo-xcode": { "state": "claimed", "at": "2026-11-17T03:00:00Z" },
    "mac-todo-tailscale": { "state": "rejected", "at": "2026-11-17T03:10:00Z", "reason": "服務沒起來" }
  }
}
```

- `queues` 的陣列順序就是顯示與派工順序。
- `status` 一律是 `confirmed`：議題一建立就已確認，這個欄位留著只是讓還在讀它的舊版程式讀得懂（C52）。
  舊版程式留下的 `status: "proposed"` 議題，看板啟動時照建立時間排到它提議時的佇列（`suggested_queue`，沒有就是 `normal`）最後，立刻寫回檔案，每一個寫一筆系統紀錄並通知主 first mate；封存檔裡的同樣改成 `confirmed`，仍然留在封存。
  舊檔的 `proposed_by`、`suggested_queue` 讀了不用，下一次存檔就不再寫。
- `merged` 是「舊 id → 新 id」，可以串接；讀到舊 id 的地方一律走到底。各 home 的標記檔不重寫。
- `history` 是來歷紀錄，舊的在前，和議題的變動寫在同一次存檔裡。`kind` 是 `merged`、`renamed`、`split`、`archived`、`reopened`；`topic` 與 `name` 是變動之後留下來的議題，合併另記被併掉的 `from` 與 `from_name`，改名另記舊名字 `from_name`，拆分的 `topic` 是新議題、`from` 是它拆出來的來源。另有兩個可省略的欄位：`reason` 是原因（`merge`、`split` 帶的 `--reason`，或封存之前的關閉提議），`by` 是在哪裡做的，`page` 或 `command`（C50）。搬了哪些 task 不記在這裡，各 task 的標記檔本來就有每次標記的時間。沒有這個欄位的舊檔當成空的；讀不懂的項目略過。`fm-topic.sh find` 讀它。
- `todos` 記要你動手的項目在「還沒做」之外的狀態，鍵是主 home 的 task id：`claimed`（使用者按了做完了，等 first mate 驗證）、`rejected`（first mate 驗證沒過，附 `reason`）、`obsolete`（first mate 不再需要，附 `reason`，等使用者撤下）。項目本身（標題、說明、指令、開或關）只在 backlog 的 hold 裡；這裡的紀錄只在對應的 hold 還開著時才顯示，hold 不在了的紀錄在下一次寫入時清掉。沒有這個欄位的舊檔當成空的；讀不懂的項目略過。
- `close_proposal` 沒有就省略。
- `next_seq` 是 `t<流水號>` 的下一個號碼，只增不減（採建議 C14）。
- `data/topics-archive.json`：`{"v":1,"topics":{<id>:{…同上…,"archived_at":…}}}`。

**議題 id**：文法 `[A-Za-z0-9._-]`，不以 `.` 或 `-` 開頭，最長 64 字元。建立時由名稱產生 slug（小寫、非 `[a-z0-9]` 的連續字元換成 `-`、去頭尾的 `-`）；slug 是空的（例如純中文）就用 `t<next_seq>`；和既有的 id 重複就加 `-2`、`-3`。「既有」包含 `topics`、封存檔與 `merged` 的鍵：封存或併掉的 id 永不重用。`--id` 可以自行指定，一樣要通過這些檢查。

### 3.2 議題標記 `data/<task-id>/topic`

只追加，每行 `<議題 id> <UTC ISO 8601 時間>`。最後一行是目前的議題。看板把每筆帳本事件歸給「事件時間之前最近的一行」的議題；task id 被重用時，舊事件留在舊議題。

### 3.3 `data/topic-board/events.jsonl`

每行一個 JSON：

- 帳本事件：`{"src":"ledger","home":"<home>","raw":"<上游帳本的那一行，原樣的字串>"}`。存原始字串而不是解析後的物件，重啟後才能用同樣的位元組去重。上游的事件有 `v`、`ts`（epoch 秒）、`event`、`task`，五種 `event`：`task.dispatched`、`task.status`、`task.pr_ready`、`task.merged`、`task.cleaned_up`。
- 系統紀錄（`ts` 也是 epoch 秒）：`{"src":"board","ts":…,"kind":"topic.created|topic.confirmed|topic.merged|agent.tagged|hold.answered|topic.close_proposed|topic.archived|topic.reopened","topic":"<id>","home":…,"task":…,"text":"<顯示用的一行>"}`。議題層級的紀錄沒有 `home` 與 `task`。
  `topic.confirmed` 只在看板啟動時確認舊版留下的提議時寫（第 3.1 節）；更早寫下的照樣顯示。

去重的鍵是 (home, 帳本那一行的原始位元組)。啟動時讀完整個檔重建去重集合；最後一行沒有換行字元就截掉。

### 3.4 `data/topic-board/summaries.jsonl`

每行 `{"ts":…,"home":"<home>","task":"<task-id>","kind":"ready|report|failed|landed","text":"…"}`。屬於哪個議題在顯示時才依議題標記與 `merged` 算。去重的鍵是 (home, task, kind, text)。`text` 上限 600 個 Unicode 碼位（採建議 C13），超過就拒收。

### 3.5 `state/topic-board/audit.jsonl`

每次狀態轉換一行，用同一個 `write_id` 串起來：

```json
{"ts":…,"write_id":"w-…","state":"sending","channel":"browser|socket|auto",
 "kind":"note|send|relay|answer|tag","home":"main","task":"…","topic":"…",
 "text":"<全文>","dedupe":{"request_id":"…"},"attempt":0}
```

- `state`：`sending`（送出中）、`retrying`（重試中，另帶 `attempt`、`next_at`、`error`）、`delivered`（已送達）、`handled_elsewhere`（已由別處處理）、`failed`（失敗，帶 `stderr`）、`undelivered`（未送達）、`unknown`（結果不明）、`ignored`（使用者按了忽略）。
- 全文、對象、去重用的 key 只在 `sending` 那一行寫一次。
- 被拒絕的瀏覽器請求另記 `{"ts":…,"rejected":"<原因>","host":…,"origin":…,"path":…}`。`path` 只記路徑、不記查詢字串（有人可能把 token 貼在網址裡），所以紀錄裡不會有 token。

## 4. 彙整腳本的輸出

`bin/fm-topic-board-read.sh [--in-home <secondmate-id>] <ledger-offset> <prefix-sha256>`，第一次傳 `0 -`。唯讀，stdout 是一個 JSON：

```json
{
  "schema": 1,
  "code_commit": "<所在 code root 的 git commit>",
  "generated": "<UTC 時間>",
  "ledger_enabled": true,
  "tasks": [ { "id": "…", "kind": "ship|scout|…", "state": "working", "source": "…", "detail": "…" } ],
  "queued": [ { "id": "…", "kind": "…", "title": "<backlog 項目的標題>", "hold": "<hold reason 原文或 null>",
                "captain": false, "blockers": [], "topic_hint": "<內文 topic: 那一行的 id 或 null>" } ],
  "holds": [ { "id": "…", "title": "<backlog 項目的標題>", "question": "<hold reason 原文>",
               "hold_bucket": "live|aged|dated|blocked", "hold_until": null,
               "unresolved_blocker_ids": [], "hold_age_days": 0, "origin": "<origin task id 或空字串>",
               "on_answer": "close|release|null" } ],
  "status_decisions": [ { "id": "…", "key": "…", "summary": "…" } ],
  "topics": { "<task-id>": "<data/<task-id>/topic 的原文>" },
  "ledger": { "status": "delta|continuity-broken|absent",
              "to_offset": 0, "to_prefix_sha256": "…", "more": false, "lines": ["<原始行>"] },
  "secondmates": [ { "id": "…", "remote": false, "home": "<路徑>" } ]
}
```

- `tasks[]`、`holds[]` 取自 `fm-fleet-snapshot.sh --json`：`tasks` 與 `backlog.records[]`。`holds[]` 只收 `hold_kind` 是 captain 的紀錄。`origin` 由腳本自己從 hold 內文的 `Captain hold origin:` 那一行取出，取不到就是空字串。`on_answer` 同樣取自 `Captain hold on answer:` 那一行（`fm-captain-hold.sh hold --on-answer` 寫的），沒有那一行或值不是 `close`、`release` 就是 `null`。
- `ledger.lines` 從 offset 起、每次最多 256 KiB 的完整行；還有沒讀完的就 `more: true`。offset 超過檔案長度、或前綴雜湊對不上，回 `continuity-broken`。沒有帳本檔回 `absent`。
- `secondmates[]` 只在主 home 的輸出裡有，資料取自上游的 `fm-secondmate-registry-lib.sh` 逐行解析 `data/secondmates.md`。
- `schema` 是這個格式的版本號。欄位有不相容的改動就加一。
- 腳本自己設 `FM_CREW_STATE_NO_FORGE=1`。`FM_SNAPSHOT_SECONDMATES` 的設法見第一段的待驗項目（採建議 C1）。

## 5. 燈號

| 燈號 | 條件 |
| --- | --- |
| 待你決定 | 該 task 有 `hold_bucket: live` 的 captain hold。優先於其他四種 |
| 卡住 | crew-state 是 `blocked`、`failed` |
| 進行中 | `working`、`parked`、`paused` |
| 完成 | `done` |
| 未知 | `unknown`、讀不到，或該 home 的彙整結果超過 3 分鐘沒更新 |

燈旁另列 crew-state 的原始狀態與 detail。已清理的 task 不在 snapshot 裡：最後一筆帳本事件是 `task.merged` 或 `task.cleaned_up` 就顯示「完成」，其他顯示「未知」。例外：`kind` 是 `ship` 的 task 被清理、而且從最近一次派出之後沒有 `task.merged`，顯示「未知」，狀態寫 `discarded`、說明寫「已收掉，帳本裡沒有落地紀錄」。上游的 teardown 不分落地或捨棄都記同一筆事件，所以要靠有沒有合併紀錄來分。

## 6. 兩條通道

### 6.1 Unix socket（`fm-topic.sh` 用）

`state/topic-board/board.sock`，0600，不帶 token。一條連線一個要求：client 送一行 JSON `{"v":1,"op":"<名稱>","args":{…}}`，服務回一行 JSON `{"ok":true,"line":"<要印的那一行>",…}` 或 `{"ok":false,"code":"refused|usage|…","line":"<原因與修法>"}`，然後關閉連線。

`op` 的清單：`health`、`status`、`stop`、`create`、`merge`、`close-propose`、`move`、`rename`、`split`、`goal`、`archive`、`reopen`、`keep`（清掉關閉的提議；`fm-topic.sh` 沒有對應的子命令，頁面的「先不關」用它）、`summary`、`which`、`find`、`todo-failed`、`todo-obsolete`、`todo-clear`（`todo add` 改寫內容後清掉舊狀態用）、`todo-claim`（頁面的「做完了」用它；`fm-topic.sh` 沒有對應的子命令）、`reset-token`。`open` 與 `restart` 由 client 用 `health` 與 `stop` 組出來。另有只給測試用的 `dump`、`test-write`、`test-resend`、`test-ignore`，只在服務的環境變數 `FM_TOPIC_BOARD_TEST=1` 時註冊，平常送這些 `op` 會得到「不認得的 op」。

`health` 回 `{"ok":true,"pid":…,"port":…,"code_commit":…,"boot_id":…,"started_at":…}`。

### 6.2 TCP（瀏覽器用）

只綁 `127.0.0.1:<埠>`。預設埠 47819，可用主 home 的 `config/topic-board-port` 改。每個請求都過下面的檢查，任何一項不過就回 4xx 並記入稽核紀錄，不讓服務當掉：

1. `Host` 精確等於 `127.0.0.1:<埠>` 或 `localhost:<埠>`。
2. `/api/` 底下的所有請求（含讀取）都要 `Authorization: Bearer <token>`，用固定時間比較。
3. 改變狀態的請求（非 GET）要求 `Origin` 精確等於 `http://127.0.0.1:<埠>` 或 `http://localhost:<埠>`；缺少或是 `null` 一律拒絕。
4. 改變狀態的請求 `Content-Type` 只收 `application/json`，body 上限 64 KiB，解析失敗回 400。
5. 靜態頁面不需要 token，但仍檢查 `Host`，而且不內嵌任何資料。
6. 每個回應都帶 `Content-Security-Policy: default-src 'self'; frame-ancestors 'none'`、`X-Frame-Options: DENY`、`X-Content-Type-Options: nosniff`、`Referrer-Policy: no-referrer`、`Cache-Control: no-store`。不設任何 CORS header。不回應 `OPTIONS` 預檢（回 405）。
7. 不提供 WebSocket 或 SSE；`Upgrade` 請求回 400。

token 是 32 位元組亂數的十六進位，第一次啟動時產生，之後不變，直到 `reset-token`。`fm-topic.sh open` 印出 `http://127.0.0.1:<埠>/#t=<token>`；頁面讀到後存進 `sessionStorage`、把 fragment 從網址列拿掉，之後用 header 帶。

API 的路徑與 body 由第五段定；這裡只定兩件事：

- **輪詢**：`GET /api/state?v=<boot_id>:<版本>`。版本沒變回 `{"changed":false}`；`boot_id` 不同一律回全量。版本是一個字串：一個只在「看得到的東西真的變了」時才加一的計數，加上每個 home 是否過期的旗標。輪詢讀到一模一樣的結果不算變；某個 home 跨過過期線算變（那一刻沒有任何讀取會回報它）。
- **兩步確認**：第一個請求回 `{"confirm":"<碼>","expires_at":…}`，碼約 2 分鐘有效、只能用一次、只存在記憶體；第二個請求帶碼才執行。碼綁定當時的對象，對象變了就拒絕。哪些動作要兩步，見第 8 節。

生命週期的操作（`status`、`stop`、`restart`）與 `summary`、`which`、`find` 只在 socket 提供。`reset-token` 也只在 socket 提供。

## 7. 指令白名單

看板服務能執行的外部指令只有下表，寫死在程式裡，不從設定檔讀。一律用 `execFile` 傳參數陣列、不經 shell；使用者輸入只當單一參數或 stdin。每次執行都明確帶環境變數 `FM_HOME=<主 home>`，執行檔路徑是 `<code root>/bin/<名稱>`。主 home 與 code root 的路徑、程式版本，由啟動服務的 `fm-topic.sh` 當參數傳入；服務自己不執行 `git`、不猜路徑。

| # | 類別 | argv | stdin | 用在 |
| --- | --- | --- | --- | --- |
| R1 | 讀 | `fm-topic-board-read.sh <offset> <sha>` | — | 主 home |
| R2 | 讀 | `fm-topic-board-read.sh --in-home <sm> <offset> <sha>` | — | 同機 secondmate home |
| R3 | 讀 | `fm-on.sh <sm> fm-topic-board-read.sh <offset> <sha>` | — | 遠端 home |
| W1 | 寫 | `fm-inbox.sh note --request-id <id> -` | 本文 | 給主 first mate 的訊息、作答後的通知、議題變成可派的通知 |
| W2 | 寫 | `fm-send.sh <task-id> <text>` | — | 直送主 home 的 worker |
| W3 | 寫 | `fm-send.sh <sm> --fire-and-forget <16 位小寫十六進位> <text>` | — | 經 secondmate 轉達，`<text>` 是「轉給 <worker-id>：<原文>」 |
| W4 | 寫 | `fm-captain-hold.sh answers --source topic-board` | 答案一行 | 主 home 的 hold |
| W5 | 寫 | `fm-topic.sh --in-home <sm> answers` | 答案一行 | 同機 secondmate home 的 hold |
| W6 | 寫 | `fm-on.sh --stdin <sm> fm-captain-hold.sh answers --source topic-board` | 答案一行 | 遠端 home 的 hold |
| W7 | 寫 | `fm-topic.sh tag <task-id> <議題 id>` | — | 主 home 的歸併（採建議 C8） |
| W8 | 寫 | `fm-topic.sh --in-home <sm> tag <task-id> <議題 id>` | — | 同機 secondmate home 的歸併 |
| W9 | 寫 | `fm-on.sh <sm> fm-topic.sh tag <task-id> <議題 id>` | — | 遠端 home 的歸併 |

參數的檢查：

- `<sm>` 必須出現在最近一次主 home 輸出的 `secondmates[]` 裡；R2、W5、W8 還要求 `remote: false`，R3、W6、W9 要求 `remote: true`。W3 兩種都可以。
- `<offset>` 是非負整數；`<sha>` 是 64 位十六進位或 `-`。
- `<task-id>`、`<議題 id>` 符合 `[A-Za-z0-9._-]`、不以 `-` 開頭。
- W2、W3 的使用者文字以 `/`、`$`、`!` 或 `-` 開頭就拒收（前面有空白也算），不送出、不改寫，提示「以 /、$、! 或 - 開頭會被當成指令。要跑指令請到終端機，要傳文字請在開頭加字。」`fm-send.sh` 不收 `--` 終止符，所以這條擋在看板這一側。
- 答案一行的格式是 `<task-id>\t<answer>\t<label>\t<mode>`。`<answer>` 不能含 tab 或換行（採建議 C12）。`<mode>` 是 `done` 或 `release`，看板照 hold 記下的處理方式填，使用者不選（第 8 節，C19）。

看板直接讀寫的檔案只有第 3 節表裡它自己的那些，再加唯讀的 `config/topic-board-port` 與 `topic-board/` 底下自己的程式與靜態檔。它不讀 `data/secondmates.md`、不讀帳本、不讀 Herdr。

白名單管的是看板服務這個程序。node client 不是服務：它會啟動服務（`spawn` 同一個 `node` 執行 `dist/board-server.js`），並在服務卡死時跑 `ps -o args= -p <pid>` 與送訊號；`fm-topic.sh` 自己會跑 `git rev-parse`、`jq`、`fm-fleet-snapshot.sh`（`order`）與 `fm-startup-memory-budget.sh report`（`install-rules`）。這些都不經服務，也不受瀏覽器的請求觸發。

不在白名單裡、由 first mate 或使用者自己跑的：`fm-topic.sh setup`、`install-rules`、`order`，以及 `fm-tasks-axi.sh hold`／`unhold`。看板不碰 backlog，不執行合併、捨棄、清理。

## 8. 哪些動作要兩步確認

| 動作 | 確認碼綁定的對象 |
| --- | --- |
| 作答待決事項（按選項或送出文字） | (home, task id, 問題全文的 SHA-256, 答案, 答了之後的處理方式) |
| 議題併進另一個議題 | (舊 id, 新 id) |
| 重送一筆「結果不明」的寫入 | write id |

作答一律兩步（採建議 C12）：答案送出就會關掉或解除那個 hold，不能收回。
答了之後這一項怎麼處理，由開 hold 的人用 `fm-captain-hold.sh hold --on-answer close|release` 記在 hold 上（第 4 節的 `on_answer`），看板照著送，使用者不選：`close` 送 `done`，被 hold 的項目標成完成；`release` 送 `release`，解除 hold、項目回到排隊中。
沒有記的（較早的 hold、程式還沒更新的 home）送 `release`，只有主 home 的要你動手的項目送 `done`；原因在 C19。
第二步的畫面寫明「記成你的答覆並通知 first mate」「看板自己不會合併或捨棄」、確認碼的有效時間，以及送出之後這一項會怎樣（沒有記的再註明這是預設），只有一個「送出」鈕與「取消」。
問題全文或處理方式在兩步之間變了（hold 被改寫或已關掉）就拒絕。請求裡帶的 `mode` 不看。

封存不用兩步：可以重開。頁面上只做一次畫面內的確認，說明排隊中的項目會被停住、已經在跑的不會停。

## 9. `fm-topic.sh` 的 exit code 與輸出

| 碼 | 意思 |
| --- | --- |
| 0 | 成功，含原樣重做 |
| 1 | 被拒絕或失敗，確定沒寫入 |
| 2 | 用法錯 |
| 3 | 結果不明：要求已送出，回應前斷線 |
| 69 | 看板服務不可用 |

例外：`--in-home <id> answers` 原樣傳回 `fm-captain-hold.sh` 的 exit code 與輸出。

成功印一行 `ok <id> <做了什麼>`；`summary`、`which`、`find`、`order`、`list`、`status`、`open` 各有自己的輸出。錯誤在 stderr 印一行原因與修法。只有 `list` 有 `--json`。

回 69 時 stderr 的那一行固定是「看板服務無法啟動：<原因>。<怎麼修>。這次的要求沒有寫入。」類別見第二段。

## 10. 時間與上限

| 項目 | 值 |
| --- | --- |
| 本機 home（主 home 與同機 secondmate）輪詢 | 每 10 秒 |
| 遠端 home 輪詢 | 每 60 秒，各 home 錯開，同一 home 不重疊 |
| 頁面輪詢 `/api/state` | 每 5 秒，分頁在背景時停 |
| 沒有頁面來輪詢多久後停止輪詢 | 2 分鐘（服務本身不關） |
| 資料多舊算過期 | 3 分鐘 |
| health 逾時 | 3 秒 |
| 啟動後等就緒 | 10 秒 |
| 卡死時 TERM 到 KILL | 5 秒 |
| 確認碼有效 | 約 2 分鐘 |
| 寫入的重試間隔 | 10 秒、30 秒、1 分、5 分、15 分，共 5 次 |
| 重啟後接續可去重寫入的時限 | `sending` 寫下後 30 分鐘 |
| 議題變成可派後多久發通知 | 30 秒內沒有再被移動 |
| `summary`／`which` 等一次補讀 | 最多 10 秒 |
| `service.log` 輪替 | 啟動時超過 1 MiB 就改名成 `service.log.1`，只留一份 |
| 彙整腳本一次回傳的帳本 | 最多 256 KiB（`fm-on.sh` 每個 job 上限 1 MiB） |

## 11. 看板依賴的框架介面

看板幾乎只新增檔案（例外是 11.3 的 session start 呼叫點與 C19 的 `hold --on-answer`，見第 2 節），它呼叫、source、讀取下面這些框架的東西。框架改到其中任何一項，就可能在不碰看板檔案的情況下弄壞看板。每一列寫了看板靠的是什麼，以及哪個測試會在它壞掉時失敗。

「真的」是測試執行 checkout 裡真的那支指令；「替身」是測試用自己寫的假指令取代它，只檢查看板送出去的參數與 stdin，並照劇本回應。**替身的那幾列，框架改了輸出或 exit code，看板的測試不會失敗**，要靠人對照這張表。

### 11.1 讀取

| 框架的東西 | 誰用 | 看板靠的是 | 測試 |
| --- | --- | --- | --- |
| `bin/fm-fleet-snapshot.sh --json`，環境變數 `FM_SNAPSHOT_SECONDMATES=1`、`FM_SNAPSHOT_BUDGET=1`、`FM_CREW_STATE_NO_FORGE=1`、`FM_HOME` | `fm-topic-board-read.sh`、`fm-topic.sh order` | exit 0 並在 stdout 印一個 JSON 物件；失敗時非 0。用到的欄位見下一張表 | 真的：`stage-1-read.sh` 全部、`stage-1-order.sh` 全部、`stage-3-data.sh` 全部 |
| `state/fleet-ledger.jsonl` | `fm-topic-board-read.sh` 逐位元組分段讀；服務解析每一行 | 只會從尾端增加的 JSONL。每行是物件，有字串 `event`、字串 `task`、數字 `ts`；另外用到 `kind`、`pr`、`text`、`state`。`event` 認得 `task.dispatched`、`task.status`、`task.pr_ready`、`task.merged`、`task.cleaned_up`，其他的照原樣顯示 | `stage-1-read.sh` 的 `test_ledger_delta_and_continuity`；`stage-3-data.sh` 的 `test_updates_and_topics`、`test_ledger_is_stored_once_and_survives_rewrites`（帳本是測試自己寫的固定內容，不是框架產生的） |
| `config/fleet-ledger` 存在與否 | `fm-topic-board-read.sh`、`fm-topic.sh setup` | 檔案存在就是這個 home 的帳本開著；`setup` 建一個空檔來打開 | `stage-1-topic.sh` 的 `test_setup_is_idempotent`；`stage-3-data.sh` 的 `test_home_status` |
| `bin/fm-primary-scope-lib.sh` 的 `fm_root_is_secondmate_home <home>` | `fm-topic.sh`、`fm-topic-board-read.sh`、`fm-topic-session-start.sh` | 回傳值分辨 secondmate home（標記檔 `.fm-secondmate-home`） | 真的：`stage-1-topic.sh` 的 `test_tag_in_secondmate_home_checks_format_only`；`stage-1-order.sh` 的 `test_falls_open_without_a_usable_topic_file` |
| `bin/fm-secondmate-registry-lib.sh` 的 `secondmate_registry_parse_line`（設 `SECONDMATE_REGISTRY_ID`、`_HOME`、`_REMOTE`）與 `secondmate_registry_field <登記檔> <id> remote\|home` | `fm-topic-board-read.sh`、`fm-topic-lib.sh` | `data/secondmates.md` 每個 `- ` 開頭的行解析出 id、home、是不是遠端 | 真的：`stage-1-read.sh` 的 `test_secondmates_and_in_home`；`stage-1-topic.sh` 的 `test_in_home_routes_to_a_local_secondmate` |
| `bin/fm-config-inherit-lib.sh` 的 `shared_captain_header_valid <檔>` | `fm-topic.sh install-rules` | 回傳值判斷共用檔的檔頭上游收不收；印出缺的那一段 | 真的：`stage-6-rules.sh` 的 `test_creates_both_files`、`test_refuses_a_shared_file_with_a_bad_header` |
| `bin/fm-timeout-lib.sh` 的 `fm_run_timed <秒> <指令…>` 與 `fm_timed_out <exit code>` | `fm-topic-session-start.sh` | 指令超過秒數就被停下，回 `fm_timed_out` 認得的 exit code；其他時候回指令自己的 exit code | 真的：`stage-2-startup.sh` 全部（沒有逾時的情況） |
| `bin/fm-startup-memory-budget.sh report` | `fm-topic.sh install-rules` | 只把它的輸出印出來；失敗時印一句替代的話，不影響安裝 | 真的：`stage-6-rules.sh` 的 `test_creates_both_files`（只檢查安裝成功） |
| `data/backlog.md` 的項目行格式 | 經 snapshot 間接讀；看板自己不解析 | 測試的 backlog 是照這個格式手寫的；hold 的原因用 `fm-hold-v1:<base64>` 編碼時由 snapshot 解回原文 | `stage-4-writes.sh` 的 `test_hands_on_items`（編碼過的原因）；`stage-5-page.sh` |

snapshot 的 JSON 裡用到的欄位（少了哪一個，對應的東西就從看板上消失或顯示成未知，不會報錯）：

| 路徑 | 用途 |
| --- | --- |
| `generated` | 這次讀取的時間 |
| `tasks[].id`、`.kind`、`.current_state.state`、`.current_state.source`、`.current_state.detail` | agent 的燈號。`state` 是 `working` 且 `detail` 剛好是 `harness busy (fm-spawn)` 時當成「還沒開始」（C32） |
| `tasks[].hints.open_decisions[]` 的 `verb`（只取 `needs-decision`）、`key`、`summary` | worker 提問 |
| `backlog.records[]` 的 `structured`、`state`（`queued`、`done`）、`id`、`title`、`kind` | 排隊中的項目；`order` 的分組 |
| `backlog.records[]` 的 `hold_kind`（`captain`）、`hold_reason`、`hold_bucket`（`live`、`aged`、`dated`、`blocked`）、`hold_until`、`hold_age_days`、`unresolved_blocker_ids` | 待決事項、要你動手的項目、排隊項目在等什麼 |
| `backlog.records[].body_lines[]` 裡 `Captain hold origin: <id>` 那一行 | 待決事項沒有自己的議題標記時，跟著來源 task 的議題 |
| `backlog.records[].body_lines[]` 裡 `Captain hold on answer: close\|release` 那一行 | 作答時送 `done` 還是 `release`（第 8 節） |
| `backlog.records[].body_lines[]` 裡 `topic: <議題 id>` 那一行 | 排隊中的項目沒有議題標記時用它（C51）；first mate 轉交項目時寫的 |

### 11.2 寫入

argv 的確切形狀在第 7 節，結果怎麼判在 [第四段](stage-4-writes.markdown)「結果怎麼判」。

| 框架的指令 | 看板靠的是 | 測試 |
| --- | --- | --- |
| `bin/fm-inbox.sh note --request-id <id> -` | exit 0 是送到（重放同一個 id 也是 0）；exit 3 是存了但沒叫醒 first mate，用同一個 id 重放會補叫醒；其他是失敗 | 替身：`stage-4-writes.sh` 的 `test_message_to_firstmate`、`test_answer_notice_survives_a_restart`、`test_dispatchable_notice`、`test_decisions_made_on_the_page_reach_firstmate` |
| `bin/fm-send.sh <task-id> <文字>` 與 `<sm> --fire-and-forget <16 位十六進位> <文字>` | exit 0 是送到；exit 3 是自己重試後仍未確認；不接受 `--` 終止符，所以開頭是 `/`、`$`、`!`、`-` 的文字由看板擋下 | 替身：`stage-4-writes.sh` 的 `test_direct_message`、`test_retries_run_out` |
| `bin/fm-on.sh <sm> <指令…>` 與 `--stdin` | 在遠端 home 執行並把 stdout、exit code 傳回；exit 255 是連線層失敗，可以重試 | 替身：`stage-3-data.sh`（遠端 home 是本機的目錄）、`stage-4-writes.sh` 的 `test_answers`、`test_tagging` |
| `bin/fm-captain-hold.sh answers --source topic-board`，stdin 一行 `<task-id>\t<answer>\t<label>\t<mode>` | 逐行讀 stdout：`closed: <id>` 是成功；`skipped: <id> (already closed)`、`(… records a different captain decision …)`、`(not held for the captain)` 是別處已處理；其他的 `skipped:`、`refused:` 是失敗。`mode` 是 `done` 或 `release` | 替身：`stage-4-writes.sh` 的 `test_answers`、`stage-5-http.sh` 的 `test_answer_takes_two_steps`。真的：`test_hands_on_item_with_the_real_hold_tool`，只有裝了 `tasks-axi` 才跑，涵蓋 `done` 與 `release` |
| `bin/fm-captain-hold.sh hold <id> --title <標題> --reason <多行文字> --on-answer close` | 建立或更新 captain hold；原因可以有換行、括號、引號，讀回來一字不差；重複執行會更新原因。`--on-answer` 寫成內文的 `Captain hold on answer:` 一行，之後重複 hold 不帶它也保留 | 真的：`test_hands_on_item_with_the_real_hold_tool`（同上，要 `tasks-axi`）。替身：`test_hands_on_commands` |
| `bin/fm-tasks-axi.sh hold <id> --reason <文字>`、`unhold <id>` | 看板不執行，只由 `order` 印成給 first mate 照著跑的指令 | `stage-1-order.sh` 的 `test_sections` 只檢查印出來的字串；指令本身能不能跑沒有測試 |

### 11.3 其他

- `bin/fm-session-start.sh`：fleet state 那一段的最後，只在拿到 session 鎖、不是 `--reemit` 時，呼叫 `bin/fm-topic-session-start.sh`，它的輸出原樣印進啟動摘要。這是看板在上游檔案裡唯一的呼叫點；合併上游時要留著這幾行。看板的測試靠真的 `fm-session-start.sh` 與 `fm-lock.sh`：拿得到鎖時跑、鎖被一個活著的 harness 程序拿著時是唯讀。測試：真的，`stage-2-startup.sh` 全部。
- `tests/lib.sh`：看板的測試腳本 source 它，用 `fm_test_tmproot`、`fm_test_run`、`fm_test_cleanup`、`fm_git_init_commit`、`fm_write_meta`、`pass`、`fail`、`assert_equals`、`assert_contains`、`assert_not_contains`、`assert_grep`、`expect_code` 與變數 `ROOT`。改到這些，十二個腳本都受影響。
- 環境變數 `FM_HOME`、`FM_ROOT_OVERRIDE`、`FM_DATA_OVERRIDE`、`FM_CONFIG_OVERRIDE`、`FM_STATE_OVERRIDE`：看板的 Bash 指令照上游的慣例解析路徑。
- 自我更新：主 home 的 `config/self-update-source` 指向 `carry`。看板的服務在下一個議題指令發現程式的 commit 變了，就換掉自己。
- `data/captain.md`、`data/captain-shared.md`：`install-rules` 在裡面維護一個有標記的區塊；`/stow` 之類的整理不能動到標記行。
