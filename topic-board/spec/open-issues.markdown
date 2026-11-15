# 矛盾與漏接

彙整時發現各票互相矛盾、和實測或上游原始碼對不上、或沒有任何一張票接住的地方。每一條都附建議；spec 的其他檔先照建議寫，並在該處標「（採建議 Cn）」。使用者不同意哪一條，改那一條引用到的段落即可。

前六條會改變做法，請先看。

## 會改變做法的

### C1　`FM_SNAPSHOT_SECONDMATES=0` 不是「跳過遠端」

- **票怎麼說**：資料來源那張第 2 點、派工順序那張第 2 點，都要彙整腳本與 `order` 設 `FM_SNAPSHOT_SECONDMATES=0`，理由是「主 home 不在每輪抓遠端摘要」。
- **實際**：上游寫明 0 是「取消數量上限」（`bin/fm-fleet-snapshot.sh:260`、`:1773`）。照票做，主 home 每 10 秒會去抓**所有**遠端的 `home-summary.json`。收集那一段（`:1396-1500`）對每個抽到的遠端都開一個 `fm-on.sh <id> fm-remote-file.sh get state/home-summary.json`，沒有略過的分支；`FM_SNAPSHOT_REGISTRY_*` 那幾個變數只限制讀 `data/secondmates.md` 的大小與筆數，設小了會讓 registry 被判成不完整，不是乾淨的關法。
- **建議**：設 `FM_SNAPSHOT_SECONDMATES=1` 與 `FM_SNAPSHOT_BUDGET=1`：最多抽一個遠端、最多等 1 秒。看板不用那份摘要（`secondmate_current`），所以抽到誰、有沒有成功都無所謂。
- **這個建議還沒站穩**：第一段的 1-1 要在真機量。如果這個每 10 秒一次的遠端 job 會搶佔遠端的 reply listener 或讓 lane 排隊，目前沒有退路，要回頭開一個決定。到時的候選：主 home 的彙整腳本不經 snapshot、改成自己組 `tasks` 與 `holds`（違反上游「人看的畫面要用 snapshot 的輸出」的契約）；或接受主 home 的輪詢降到每分鐘一次；或只在主 home 有遠端 secondmate 時才降頻。
- **副作用要知道**：這表示主 home 每輪的 snapshot 內部仍會經 `fm-on.sh` 開一個遠端 job。那是上游腳本自己做的，不是看板執行的指令，白名單不受影響；但遠端 lane 會多這個流量。

### C2　socket 路徑太長時 Node 不會報錯

- **票怎麼說**：服務生命週期那張第 5 點：路徑超過上限時啟動失敗。
- **實際**：實測 Node 默默截斷路徑，把 socket 建在別的地方，並回報成功。
- **建議**：服務在 `listen` 之前自己算路徑的位元組長度，超過就啟動失敗。已寫進第二段。

### C3　由誰啟動服務

- **票怎麼說**：服務生命週期那張第 2 點：Bash 議題指令用 `nohup` 加獨立 process group 啟動 `node`，形狀參考上游的 `docs/verification/supervision.md`。
- **實際**：那份文件沒有指令的形狀。上游實際用的是 `set -m; nohup … &`。實測三種形狀都活得過工具呼叫；其中由 node 自己 `spawn({detached: true})` 最乾淨（自己的 session、沒有殘留的包裝程序），而且不依賴 macOS 沒有的 `setsid`。
- **建議**：由 node client 啟動服務。連 socket 本來就要先跑 client，沒有多一個相依。已寫進第二段。

### C4　TypeScript 怎麼跑（問過使用者）

- **實際**：這台的 `node` 沒有 TypeScript 支援，type stripping 不能用。
- **定案**：提交 `tsc` 的編譯結果。連帶的改動：啟動失敗的類別裡「`node` 低於 22」照舊（任何 22.x 都行），另加一類「編譯結果不見了」；多一個 `check-dist.sh` 防止 `dist/` 過期。

### C5　fork 裡不能有新的 `.md`

- **票怎麼說**：偏好檔那張把範本定成三個 `.md`，「實作時原樣搬進 fork」。
- **實際**：上游的文件稽核要求每個追蹤的 `*.md`、`*.txt` 都登記在既有的清單檔。加了就失敗，而改清單檔違反「只新增」。
- **建議**：範本改用 `.md.tmpl`，spec 用 `.markdown`（使用者已選），新目錄不放 `README.md`。內容一個字都不用改。

### C6　fork 的測試不能放在 `tests/`

- **票怎麼說**：誰來實作那張：照上游的測試慣例。
- **實際**：上游的 `fm-test-run.sh --check-coverage` 目前剛好在 15% 的上限，多一個 `tests/*.test.sh` 就失敗；時間量測表寫在上游的 `bin/fm-test-run.sh` 裡。
- **建議**：fork 的測試全放 `topic-board/test/`，用自己的 `run.sh`，只借用上游的 `tests/lib.sh`。代價：在開發用的 clone 裡跑上游的 `fm-test-run.sh --changed` 會因為找不到對應的測試而中止（`no changed-test mapping`）。fork 的 PR 不用 `--changed`，改跑各段驗收列的指令。上游的 CI 本來就不在 `carry` 上跑，所以沒有東西會因此變紅。

## 票與票之間對不上的

### C7　`status` 的規則狀態用詞

偏好檔那張第 7 點寫「未裝、和範本相同、和範本不同」，比的是內容；指令介面那張的補記寫「未裝、已裝 vN、或比範本舊」。**建議**：照前者，並附上版本號給人看：`和範本相同（vN）`、`和範本不同（vN）`。「比範本舊」判斷不出來（使用者手改也會不同）。

### C8　主 home 的歸併沒有列在最終的 argv 清單

安全防護那張第 8 點有「議題指令的 `tag`（本機直接跑）」，但後來幾則補記列 argv 時只列了遠端與同機 secondmate 的形狀。**建議**：最終的表補上 `fm-topic.sh tag <task-id> <議題 id>`（W7）。

### C9　經 secondmate 轉達的訊息，同一個 argv 有兩種分類

重送那張第 2、10 點：遠端的 secondmate 算可去重，同機的算不可去重，但 argv 完全一樣。**建議**：分類的依據寫明是 `secondmates[]` 的 `remote` 欄位，在 `sending` 那一行記下來，重啟後照它判斷。

### C10　`summary --home <id>` 在服務剛啟動時無從檢查

里程碑那張要求 `--home` 的值在 `secondmates[]` 裡，但服務只在有人看頁面時輪詢，剛被 `summary` 帶起來時可能一次都沒讀過主 home。**建議**：服務手上沒有主 home 的彙整結果時，先同步跑一次主 home 的讀取（白名單的 R1）再檢查，最多等 10 秒。

### C11　`failed` 的摘要在首頁沒有位置

版面那張的「最近的結果」只列就緒、報告、落地。**建議**：四種都列，`failed` 用卡住的顏色。失敗正是一陣子沒看的人最需要看到的。

### C12　哪些選項算「不可逆」、確認碼綁什麼

- **票怎麼說**：brief 第 18 項與安全防護那張第 6 點：合併、捨棄等不可逆動作兩步確認，確認碼綁 PR 網址與 head commit。
- **對不上的地方**：選項只是 hold 最後一行的散文，沒有任何一張票定怎麼認出哪個選項是「合併」。`holds[]` 裡也沒有 PR 網址與 head commit；每輪又設了 `FM_CREW_STATE_NO_FORGE=1`，不查 forge。
- **建議**：不猜。**所有**作答都走兩步，確認碼綁 (home, task id, 問題全文的雜湊, 答案)。理由：送出答案就會關掉那個 hold，本身就收不回來；看板又不執行合併，真正合併的是 first mate，上游在那一側自己有防護。代價是每次作答多按一下。
- 連帶補定：答案是單行，不能含 tab 或換行（上游的輸入格式用 tab 分欄、一行一筆）。

### C13　「600 字」的單位

里程碑那張說約 300 字、拒收超過 600 字。**建議**：算 Unicode 碼位。

### C14　`t<流水號>` 的計數存哪

格式那張說轉不出 slug 時用 `t<流水號>`，id 永不重用，但沒說號碼記在哪。**建議**：`topics.json` 加 `next_seq`，只增不減。

### C15　同機的 secondmate 怎麼跑 `setup`

改用 fork 那張說「同機的 secondmate 在它自己的 home 跑」，沒說誰、怎麼跑。**建議**：`fm-topic.sh --in-home <id> setup`，由使用者或主 first mate 從主 home 跑。不進看板的白名單。

### C16　完全沒有 `node` 時的 `status` 與 `stop`

指令介面那張把它們歸在「需要 `node`（服務沒跑時只讀檔）」，沒說連 `node` 都沒有時怎樣。**建議**：`status` 退成只讀檔並註明原因，回 0；`stop` 回 69。

### C17　名詞表的「議題標記」還寫「派工前」

派工順序那張已經把時機提前到「建立 backlog 項目時」。**建議**：照後者；這份 spec 的名詞已改，規劃目錄的 `GLOSSARY.md` 也一併改了。

## 沒有任何一張票接住的

### C18　彙整腳本沒有 `decisions_open`

brief 與帳本研究都說待決事項從 snapshot 的 `decisions_open` 讀。實測 `fm-fleet-snapshot.sh --json` 的頂層沒有這個欄位；資料來源那張第 1 點改從 `backlog.records[]` 取，是對的。這裡只是記一筆，免得實作時照 brief 找不到。

### C19　作答時用 `done` 還是 `release`

- **問題**：`fm-captain-hold.sh answers` 每行的第四欄決定作答之後怎麼處理被 hold 的項目：空或 `done` 是把它標成完成，`release` 是解除 hold 讓它繼續。上游的守則：純粹的決定用 close，還有沒做完的工作用 release，合併的同意也用 release（`.agents/skills/captain-hold-lifecycle/SKILL.md:34-42`）。看板分不出一個 hold 是哪一種，沒有任何一張票定這件事。
- **選錯的後果**：該 release 的用了 done，一件還沒做的工作會被標成完成，而且不會有人發現。該 done 的用了 release，一個純決定的項目會留在 backlog，first mate 收到通知後自己關掉。
- **定案（問過使用者）**：不由看板猜。作答的第二步確認放兩個送出鈕，「送出，這件事結束」（`done`）與「送出，讓工作繼續」（`release`），沒有預設。
- 還沒驗的：兩種之後項目實際的狀態（第四段 4-4）。已知上游在 away 狀態下拒絕 `release`（回 `refused:`），那時那筆寫入顯示「失敗」並附原因。

### C20　各段怎麼分

誰來實作那張的六段草稿沒有安置下面這些，這份 spec 的分法是：

| 項目 | 放在 | 理由 |
| --- | --- | --- |
| `--in-home` 的 `tag`、`answers`、`setup` | 第一段 | 純 Bash、不碰 socket |
| `open`、`reset-token`、token 檔 | 第二段 | 服務一啟動就要有 token 與埠 |
| `summary`、`which` | 第三段 | 要靠彙整結果查議題 |
| 各 home 的版本狀態與 `status` 裡的那幾行 | 第三段 | 資料來自輪詢 |
| 議題變成可派的 30 秒通知 | 第四段 | 它是一筆寫入 |
| `status` 的規則狀態 | 第六段 | 和範本一起 |
| 頁面上的改名、改目標、封存、議題併議題 | 第五段 | 這次補定，見該段 |

### C21　`fm-inbox.sh note` 回 3 時上游建議的修法

上游的檔頭說「已存但沒叫醒」時呼叫端應該用 `announce <id>` 修復。重送那張定的是用同一個 request-id 重放，並已確認重放會補叫醒。兩者效果相同；**建議**照票（重放），白名單不用多一個形狀。
