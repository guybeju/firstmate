# 交接

第 2、3 節是當時的紀錄，用的是改名（[open-issues](open-issues.markdown) C57）之前的名字 `topic-board` 與 `fm-topic`；新舊名字的對照在 C57。

看板由一個獨立的 session 做到這裡，之後的維護移交給 fleet。這一頁給接手的人：怎麼跑測試、每個問題的狀態、哪些事還沒驗、已知的限制。看板只經 `bin/fm-board.sh feed` 與 `deliver` 碰到另一邊（[contracts](contracts.markdown) 第 4、7、11 節）；first mate 那支程式依賴框架的哪些指令與輸出，在 [adapter](../../fm-board/spec/adapter.markdown) 第 7 節。

狀態以 `carry` 上這個檔所在的 commit 為準。標「回報」的結果是主 first mate 在真的 home 或 Mac 上跑完告訴這個 session 的，這個 session 沒有自己重跑。

## 1. 怎麼跑測試

全部在 fork 的 checkout 裡跑，不需要真的 home。測試只寫自己建的暫存目錄，服務開在當下空著的埠，不會碰 `config/myshape-port` 設的埠（預設 47819）。

需要的工具：

| 工具 | 用在 | 沒有的時候 |
| --- | --- | --- |
| `bash`（3.2 以上）、`git`、`jq`、`curl` | 全部 | 少了 `jq` 的腳本印 `skip:` 後結束，算通過 |
| `node` 22 以上 | 第二段起 | 那些腳本印 `skip:` 後結束 |
| `pnpm` | 單元測試、型別、lint、格式、重編 `dist/` | 只影響這一列的指令 |
| `firefox`（在 `PATH` 上） | `stage-5-page.sh`，用真的瀏覽器走一遍頁面 | 印 `skip: firefox not found` 後結束 |
| `curl`、`ps`、`sha256sum` | 第七段：看板從只有它自己的檔的副本跑，另一邊是 `myshape/test/stub-aggregator/` 的替身 aggregator | 少了 `jq`、`node`、`curl`、`git`（`stage-7-aggregator.sh` 另加 `sha256sum`）時印 `skip:` 後結束 |
| `tasks-axi` | `stage-4-writes.sh` 裡對真的 hold 工具的那一個測試 | 那一個測試印 `ok - skip: tasks-axi not found` |

指令（工作目錄是 checkout 的根目錄）：

```
myshape/test/run.sh            # 第一到五段與第七段，十四個腳本
myshape/test/run.sh 1          # 只跑第一段；可以列多個數字（第六段搬到 fm-board/test）
fm-board/test/run.sh               # first mate 這一側：feed、deliver、tag、setup、--in-home、帶 task 的 split、規則、安裝說明
dispatch-plan/test/run.sh          # first mate 這一側：order
bash myshape/test/stage-4-writes.sh   # 單跑一個腳本
bash myshape/test/check-dist.sh       # dist/ 是不是 src/ 編出來的
bin/fm-doc-audience-check.sh              # 上游的檢查；新增的檔不能違反
(cd myshape && pnpm install --frozen-lockfile)   # 只有第一次
(cd myshape && pnpm test)             # vitest 單元測試
(cd myshape && pnpm run typecheck && pnpm run lint && pnpm run format:check)
(cd myshape && pnpm run build)        # 改了 src/ 之後重編 dist/，結果要一起提交
shellcheck -x bin/myshape.sh bin/myshape-lib.sh bin/fm-topic-board-read.sh bin/fm-topic-session-start.sh myshape/test/*.sh myshape/test/stub-aggregator/*
shellcheck -x bin/fm-board.sh bin/fm-board-lib.sh bin/fm-board-io-lib.sh bin/fm-board-migrate-lib.sh bin/fm-topic.sh bin/fm-dispatch-plan.sh fm-board/test/*.sh dispatch-plan/test/*.sh
```

- 每個腳本在第一個失敗的檢查印 `not ok - …` 並以非 0 結束；全過時 `run.sh` 的最後一行是 `# myshape tests passed (<n> scripts)`。
- `run.sh` 用啟動它的那個 bash 跑每個腳本，但腳本裡呼叫的 `bin/myshape*.sh` 是照自己第一行的 `#!/usr/bin/env bash` 找 bash。要在 macOS 上驗 bash 3.2，兩邊都要是 3.2：`PATH="/bin:$PATH" /bin/bash myshape/test/run.sh`。正式環境裡遠端的 home 用哪個 bash，同樣取決於當時 `PATH` 上第一個是哪一個。
- 測試用的環境變數由各腳本自己設：`MYSHAPE_TEST=1` 打開只給測試用的 socket 操作，`MYSHAPE_READ_MS` 等縮短輪詢與重試的間隔。不用事先設任何變數。
- 會停掉或重啟看板的第七段腳本只經 `myshape/test/signal-lib.sh` 的 `kill_own_child` 送訊號，只送給腳本自己用 `&` 啟動、記下 `$!` 的子程序；`myshape/test/check-signals.sh` 檢查第七段、它的函式庫、替身 aggregator 與 `fm-board/test` 沒有別的送訊號的寫法。`FM_TEST_SIGNAL_DRY_RUN=1 FM_TEST_SIGNAL_LOG=<絕對路徑>` 讓這些腳本什麼都不送，只記下每一次會送給誰。
- 暫存目錄：macOS 預設的暫存目錄很深，會讓 socket 路徑超過 103 位元組的上限。`helpers.sh` 在預設暫存目錄的路徑超過 40 個字元時改用 `/tmp`。
- 範圍：這台 Linux 要十四個腳本與 `fm-board/test`、`dispatch-plan/test` 全過。遠端的 home 只跑 `bin/fm-topic-board-read.sh` 與 `bin/fm-board.sh`（`tag`、`setup`，與一次性的 `migrate-myshape`），不跑服務也不開頁面，所以在 Mac 上要過的是第一段與 `fm-board/test/stage-1-tag.sh`。頁面程式在使用者開看板的那台機器的瀏覽器裡執行。
- ShellCheck 會對 `tests/lib.sh` 的 source 報 SC1091，可以忽略；其他的要是零。

### 在暫時的 home 手動試

```
H=$(mktemp -d /tmp/tb-try.XXXXXX)
mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$H/data/backlog.md"
echo 47931 > "$H/config/myshape-port"          # 任何空著的埠，不要用 47819
t() { FM_HOME="$H" FM_ROOT_OVERRIDE="$PWD" bin/myshape.sh "$@"; }
t open                                            # 第一次 open 才有看板；印出帶 token 的網址
t create "試試看" --goal "一行目標" --id try         # 一建立就排在「一般」最後
t stop                                            # 用完要停，再把 $H 丟進垃圾桶
```

`FM_ROOT_OVERRIDE` 指向 checkout，`FM_HOME` 指向暫時的 home。真的 home 不要拿來試。

## 2. 每個問題的狀態

[open-issues](open-issues.markdown) 的每一條。「完成」是已經照那一條寫的做法實作並進了 `carry`；PR 是那一條進 `carry` 的那一個。Mac 上找到的另外三個測試相容性問題沒有編號，在 #29、#30、#31：暫存目錄太深與 `ss`、輔助函式的預設值寫法、巢狀引號。

| 條目 | 狀態 | PR |
| --- | --- | --- |
| C1 到 C21 | 完成：規劃時定案，第一次交付就照著做 | #1 |
| C22 到 C27 | 完成：實作時發現並修掉 | #1 |
| C28 | 延後（使用者 2026-11-17 定），之後要補，清單在第 4 節 | #1 起持續記錄 |
| C29 到 C31 | 完成 | #3 |
| C32 | 完成 | #4 |
| C33 | 完成 | #5 |
| C34 | 完成 | #6 |
| C35 | 完成 | #7 |
| C36 | 完成 | #9 |
| C37 | 完成 | #11 |
| C38 | 完成 | #13 |
| C39 | 完成 | #14 |
| C40 | 完成 | #15 |
| C41 | 完成 | #16 |
| C42 | 完成，只有截圖驗過，沒有自動測試 | #17 |
| C43 | 完成 | #18 |
| C44 | 完成，真的 home 上實測過（回報） | #19 |
| C45 | 完成 | #25 |
| C46 | 完成；真的 home 上建立過項目，「做完了」到關閉的一整輪還開著（第 3 節） | #27 |
| C47 | 完成，Mac 上通過 | #28 |
| C48 | 完成，Mac 的 bash 3.2.57 上通過 | #29 |
| C49 | 完成 | #32 |
| C50 | 完成 | #33 |
| C51 | 完成 | #34 |
| C52 | 完成 | #49 |
| C53 | 完成 | #51 |
| C54 | 完成 | #52 |
| C55 | 完成 | 這一條進 `carry` 的 PR（commit 訊息寫明 C55） |

C19 在 2026-11-18 改定：作答時送 `done` 還是 `release`，照開 hold 時記下的處理方式，卡片只剩一個送出鈕（見 C19）。

提過的三件小功能，使用者 2026-11-17 定案：合併與拆分的來歷加一句原因，做了（C50）；沒有議題標記的排隊項目顯示在未分類區，做了（C49）；`find <議題>` 列出搬過的 task，不做。C28 延後是使用者 2026-11-17 定的，要補的項目列在第 4 節。

## 3. 驗證的結果

[verification](verification.markdown)「沒驗到的」那張表是規劃當時寫的，下面是現在的結果。除了標明「這個 session」的，都是主 first mate 在真的 home、同機的 secondmate 或那台 Mac（secondmate `macmate`）上跑完回報的。

### 通過

| 項目 | 結果 |
| --- | --- |
| 全套測試在 macOS 上，兩種 bash | commit `faa7a8f6`，不設 `TMPDIR`。`PATH` 預設（bash 5.3.20）與 `PATH="/bin:$PATH"`（每一層都是 3.2.57）結果相同：第一段 23 項、第二段 13、第三段 14、第四段 14、第五段 8 加上 `skip: firefox not found`、第六段 9，沒有失敗。工具是 BSD 的 `cut`、`awk`、`sed`、`grep`，`jq`，node 26.13.1，curl 8.7.1。最後的 commit 要再跑一次 |
| 上線 R-1、R-2、R-3、R-6 | 細節在 [rollout](rollout.markdown) |
| 上線 R-5 | 這個 session：每個 PR 的 base 都是 fork 的 `carry` |
| 主 home 每輪抓遠端摘要的成本（1-1）；遠端 lane 的延遲（1-6） | `bin/fm-on.sh macmate fm-topic-board-read.sh 0 -` 三次：4.5、4.1、5.8 秒，exit 0，輸出 359 位元組（那個 home 沒有 task）。沒有逾時。前面排著長工作時的延遲沒有量 |
| 遠端 job 讀得到 pane（1-7） | Mac 的 home 裡有一個 scout 在跑時，`bin/fm-on.sh macmate fm-crew-state.sh <task>` 回 `state: working · source: pane · harness busy (claude-hook)` |
| 用主 home 的程式對同機 secondmate 的 home 作答（1-8） | 那個 home 的紀錄是 `Resolution mode: answered`、`Captain answered this call through topic-board` |
| parent channel 的每一行帶子 task 的 id，文字夠寫摘要（3-1、3-2） | first mate 一整天的 ready 與 landed 摘要都只靠這些行寫成，例如 `child <task> PR ready: <網址> mode=no-mistakes yolo=off` |
| 遠端沒有那支指令時的錯誤（3-3） | 主 checkout 裡沒有那個檔名時，`fm-on.sh` 在本機就拒絕，exit 1，stderr 是 `error: remote command is not a genuine tracked executable in this Firstmate checkout: <名稱>`。「主 checkout 有、遠端沒有」的情況沒有重現（兩邊同一個 commit） |
| 經 secondmate 轉達（4-2） | 同機：約 3 秒送達，worker 收到的文字逐位元組相同。遠端：10 秒送達。轉不出去時：worker 已結束，看板的寫入在 7 秒後記成已送達（送到 secondmate），secondmate 隨後在 parent channel 回報 `failed …: relay delivery=<id> to <task> not delivered: worker already ended and cleaned up`。頁面不會顯示這個後來的失敗，見第 4 節 |
| 在看板上回答遠端 home 的待決事項（4-3） | 兩步作答、選「這件事結束」：5 秒後寫入是送出中，10 秒後已送達；Mac 的 backlog 裡那一項是 done，紀錄是 `Resolution mode: answered`、`Answer: A`；主 home 的 inbox 收到通知 |
| 兩種作答之後項目的狀態（4-4） | 「這件事結束」：項目進 Done，`Resolution mode: answered`。「讓工作繼續」：`Resolution mode: released`，項目回到排隊中、不再被擋 |
| 使用者在頁面上的決定通知到 first mate（C44） | 使用者在頁面上封存五個議題，first mate 各收到一則通知並被叫醒 |
| `split` 第一次在真的 home 上用（C40） | 一個議題拆成四個，七個同機 secondmate 的 task 改標成功 |
| 轉交出去、還沒派工的項目顯示在它的議題下（C51） | 一個內文帶 `topic:` 那一行的項目轉交給 `macmate` 而不派工：看板把它列在那個議題底下，不在「沒標議題的排隊項目」裡 |
| `find --all`（C50） | 真的 home 上印出完整來歷與精確時間；功能上線前的舊紀錄沒有括號 |

### 只驗了一部分

| 項目 | 驗到的 | 沒驗到的 |
| --- | --- | --- |
| 上線 R-7（容量滿時照 `order` 的順序） | 暫時的 home、容量設 1、高／一般／待辦各一個議題各一個排隊項目：`order` 的「可派」先印高的再印一般的，待辦的列在「該 hold」並附指令 | 真的派工派到容量滿、下一輪由高優先的先拿到空位。需要真的專案與 worker |
| first mate 照規則在對的時機跑指令（6-2） | 真的 home 上它照規則 `propose`、`split`、`todo add`、寫摘要 | 全新的 session 從頭開始照不照做 |

### 還開著，由 fleet 負責

這幾項在這個 session 結束時沒有結果；任何一項查出看板的問題，就照第 5 節處理。

| 項目 | 為什麼還開著 |
| --- | --- |
| 「要你動手」的一整輪：做完了、驗證通過、關閉；另一輪驗證沒過（C46） | 要等使用者在頁面上按「做完了」。建立項目與頁面顯示已在真的 home 上看過 |
| 全新的 session 照規則做；`/stow` 之後區塊的標記還在（6-2、6-4） | 要等下一次全新的 session 與下一次真的 `/stow` |
| R-7 沒驗到的那一半 | 見上 |
| fleet 的 worker 能不能在 fleet 的權限模式下跑看板的測試 | fleet 的工作，還沒試。需要 `FM_TOPIC_BOARD_TEST`、空著的埠，第五段的瀏覽器測試需要 `firefox` |

### 沒驗，也沒有排定要驗

| 項目 | 原因 |
| --- | --- |
| 服務活過 Claude Code session 結束（2-1） | 沒有單獨驗過；真的看板已經連續跑了超過一天 |
| `tsc` 的輸出跨機器逐位元組相同（2-3） | `check-dist.sh` 只在這台 Linux 上跑過 |
| 原生拖放在 Chrome 上；真的滑鼠拖曳（5-1） | 這台沒有 Chrome，測試用 headless Firefox 與合成的拖放事件 |
| 壓縮後 Claude Code 重印摘要（6-3） | 沒驗 |

## 4. 已知限制

各段與 [rollout](rollout.markdown) 另有各自的限制；這裡是跨段、接手的人最需要知道的。

測試蓋不到的：

- `fm-board.sh deliver` 跑的四支框架指令（`fm-inbox.sh`、`fm-send.sh`、`fm-on.sh`、`fm-captain-hold.sh answers`）在測試裡是替身。框架改了它們的輸出或 exit code，測試不會失敗。細節與每一項對應的測試在 [adapter](../../fm-board/spec/adapter.markdown) 第 7 節。
- 進入點 `board-server.ts`、`board-client.ts` 與 `src/page/` 沒有單元測試，由 Bash 與瀏覽器的整合測試覆蓋；CRAP 與 mutation 的關卡只管函式庫模組（C28）。
- 窄視窗的版面沒有自動測試（C42）。
- 頁面在佇列裡有上百個項目時的速度沒有量過。

行為上的：

- 頁面上只能用拖的改順序：沒有鍵盤可用的移法，原生拖放在 Chrome 上也還沒驗（第 3 節）；這兩種情況改用 `bin/myshape.sh move`（C55）。
- 看板認一個 home 的依據是 `state/myshape/token`：全新的 home 要先 `open` 才能 `create`；`open` 在 secondmate 的 home 也不會被拒絕，那裡會開出另一個看板（沒有規則叫 second mate 跑它）。
- 「要你動手」只支援主 home 的項目；按了「做完了」之後使用者不能自己收回；first mate 不能自己關掉項目，要使用者按「好，撤下」（C46）。
- `find` 平常每個議題只印最近八筆來歷（`--all` 印全部）；來歷不記拖曳排序、改目標、建立議題；`split` 不帶 task 會建一個空議題，新名稱可以和來源相同。
- `install-rules` 會換掉結束標記之後同一行的文字（有備份）；別處有一行以標記開頭時拒絕安裝（C37）。
- 程式退回沒有 `history` 或 `todos` 欄位的舊版時，下一次存檔會丟掉這兩個欄位（見 [rollout](rollout.markdown)）。
- first mate 自己直接做、沒有派 worker 的項目，在關掉之前會被 `order` 列在「可派」。
- 經 secondmate 轉達的訊息，看板在送到 secondmate 時就記成已送達。secondmate 之後回報轉不出去，頁面不會改，使用者只會從 first mate 在聊天裡的回報知道。
- 排隊中的項目沒有議題標記時用內文的 `topic:` 那一行（C51）；內文沒有那一行的轉交項目，在 secondmate 派工之前仍顯示成沒標議題。
- secondmate 自己跑的 `tag`（以及經 `fm-on.sh` 跑的）不知道主 home 有哪些議題，只檢查 id 格式；寫錯的在頁面上是「標記的議題不存在」（C53）。
- home 已經沒有、帳本裡只有狀態行的 task 不列為 agent（C53）：帳本關著時派出、之後沒經過收掉就消失的 worker 也在其中。

沒有做到的規範：C28 列的那幾項。

### 延後、之後要補的（C28）

使用者 2026-11-17 決定這些先不做，但要記得之後補上；不是放棄。

- `board-server.ts`、`board-client.ts` 與 `src/page/` 共 92 個函式不在 CRAP 的關卡內。做法是把進入點裡的邏輯抽成可以單獨測試的函式，再補單元測試。這是唯一有實際風險的一項，要分幾個 PR 做。
- 輪詢器裡「到期時間等於現在」的邊界有一個存活的突變（`<=` 換成 `<`）。
- `topics.split` 的 CRAP 是 11，門檻是 10。
- Bash 腳本的函式長度與複雜度沒有量過（上限是 100 行、複雜度 8）。

不補的兩項：超過 100 字元的中文訊息行；有些測試不是先寫的。

## 5. 交接之後誰做什麼

- 使用者 2026-11-17 決定：做看板的這個 session 到完工線就停，之後不再從它推送看板的修改。看板的修改與 PR 走 fleet 的流程，和 fork 上其他的修改一樣由使用者經主 first mate 決定要不要合併。
- 第 3 節「還開著」的項目與第 4 節「延後、之後要補的」由 fleet 接手。

- 上游的新版合併進 `carry`：fleet 負責，見 [rollout](rollout.markdown)「之後怎麼更新」。
- 看板的檔案是 `myshape/**` 與 `bin/myshape*.sh`，另外在上游的 `bin/fm-session-start.sh` 裡有一個呼叫點（contracts 第 11.3 節）。改到 [adapter](../../fm-board/spec/adapter.markdown) 第 7 節列的任何一支框架指令時，跑那一列寫的測試。
- first mate 這一側接看板的檔是 `bin/fm-board.sh`、`bin/fm-board-lib.sh`、`bin/fm-board-io-lib.sh`、`bin/fm-board-migrate-lib.sh`、改名前的名字留下的提示 `bin/fm-topic.sh`（C57）、`bin/fm-dispatch-plan.sh`、`fm-board/**` 與 `dispatch-plan/**`（[adapter](../../fm-board/spec/adapter.markdown)）；改它們走同樣的流程，這一節的規則也適用。
- 規則範本改了要升版本號（`fm-board/rules/captain.block.md.tmpl` 第一行），`fm-board/test/stage-6-rules.sh` 裡的版本與 token 上限跟著改，真的 home 由使用者明講之後重跑 `bin/fm-board.sh install-rules`。
- `dist/` 要和 `src/` 一起提交；`dist/` 有變，執行中的看板要重啟才生效，`public/` 的 CSS 不用。
- 看板每次修改（程式、指令、規則範本、需要的工具）都要在同一個修改裡對照新機器的安裝說明 [FORK-SETUP](../../FORK-SETUP.markdown)，改掉不一致的地方。
  PR 說明要寫出那一頁查過了、改了什麼。
  `fm-board/test/check-guide.sh`（`fm-board/test/run.sh` 會跑）只檢查那一頁引用的名稱存在、寫的規則範本版本正確；步驟的順序、每一步的輸出、平台與需要的工具要讀過才知道，清單在那一頁的最後一節。
