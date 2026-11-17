# 交接

看板由一個獨立的 session 做到這裡，之後的維護移交給 fleet。這一頁給接手的人：怎麼跑測試、每個問題的狀態、哪些事還沒驗、已知的限制。看板依賴框架的哪些指令與輸出，在 [contracts](contracts.markdown) 第 11 節。

狀態以 `carry` 上這個檔所在的 commit 為準。標「回報」的結果是主 first mate 在真的 home 或 Mac 上跑完告訴這個 session 的，這個 session 沒有自己重跑。

## 1. 怎麼跑測試

全部在 fork 的 checkout 裡跑，不需要真的 home。測試只寫自己建的暫存目錄，服務開在當下空著的埠，不會碰 `config/topic-board-port` 設的埠（預設 47819）。

需要的工具：

| 工具 | 用在 | 沒有的時候 |
| --- | --- | --- |
| `bash`（3.2 以上）、`git`、`jq`、`curl` | 全部 | 少了 `jq` 的腳本印 `skip:` 後結束，算通過 |
| `node` 22 以上 | 第二段起 | 那些腳本印 `skip:` 後結束 |
| `pnpm` | 單元測試、型別、lint、格式、重編 `dist/` | 只影響這一列的指令 |
| `firefox`（在 `PATH` 上） | `stage-5-page.sh`，用真的瀏覽器走一遍頁面 | 印 `skip: firefox not found` 後結束 |
| `tasks-axi` | `stage-4-writes.sh` 裡對真的 hold 工具的那一個測試 | 那一個測試印 `ok - skip: tasks-axi not found` |

指令（工作目錄是 checkout 的根目錄）：

```
topic-board/test/run.sh            # 六段全部，十個腳本，這台 Linux 約十分鐘
topic-board/test/run.sh 1          # 只跑第一段；可以列多個數字
bash topic-board/test/stage-4-writes.sh   # 單跑一個腳本
bash topic-board/test/check-dist.sh       # dist/ 是不是 src/ 編出來的
bin/fm-doc-audience-check.sh              # 上游的檢查；新增的檔不能違反
(cd topic-board && pnpm install --frozen-lockfile)   # 只有第一次
(cd topic-board && pnpm test)             # vitest 單元測試
(cd topic-board && pnpm run typecheck && pnpm run lint && pnpm run format:check)
(cd topic-board && pnpm run build)        # 改了 src/ 之後重編 dist/，結果要一起提交
shellcheck -x bin/fm-topic.sh bin/fm-topic-lib.sh bin/fm-topic-board-read.sh topic-board/test/*.sh
```

- 每個腳本在第一個失敗的檢查印 `not ok - …` 並以非 0 結束；全過時 `run.sh` 的最後一行是 `# topic-board tests passed (<n> scripts)`。
- `run.sh` 用啟動它的那個 bash 跑每個腳本，但腳本裡呼叫的 `bin/fm-topic*.sh` 是照自己第一行的 `#!/usr/bin/env bash` 找 bash。要在 macOS 上驗 bash 3.2，兩邊都要是 3.2：`PATH="/bin:$PATH" /bin/bash topic-board/test/run.sh`。正式環境裡遠端的 home 用哪個 bash，同樣取決於當時 `PATH` 上第一個是哪一個。
- 測試用的環境變數由各腳本自己設：`FM_TOPIC_BOARD_TEST=1` 打開只給測試用的 socket 操作，`FM_TOPIC_BOARD_LOCAL_MS` 等縮短輪詢與重試的間隔。不用事先設任何變數。
- 暫存目錄：macOS 預設的暫存目錄很深，會讓 socket 路徑超過 103 位元組的上限。`helpers.sh` 在預設暫存目錄的路徑超過 40 個字元時改用 `/tmp`。
- 範圍：這台 Linux 要十個腳本全過。遠端的 home 只跑 `bin/fm-topic*.sh`，不跑服務也不開頁面，所以在 Mac 上要過的是第一段。頁面程式在使用者開看板的那台機器的瀏覽器裡執行。
- ShellCheck 會對 `tests/lib.sh` 的 source 報 SC1091，可以忽略；其他的要是零。

### 在暫時的 home 手動試

```
H=$(mktemp -d /tmp/tb-try.XXXXXX)
mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$H/data/backlog.md"
echo 47931 > "$H/config/topic-board-port"          # 任何空著的埠，不要用 47819
t() { FM_HOME="$H" FM_ROOT_OVERRIDE="$PWD" bin/fm-topic.sh "$@"; }
t propose "試試看" --goal "一行目標" --id try && t confirm try
t open                                            # 印出帶 token 的網址
t stop                                            # 用完要停，再把 $H 丟進垃圾桶
```

`FM_ROOT_OVERRIDE` 指向 checkout，`FM_HOME` 指向暫時的 home。真的 home 不要拿來試。

## 2. 每個問題的狀態

[open-issues](open-issues.markdown) 的每一條。「完成」是已經照那一條寫的做法實作並進了 `carry`；PR 是那一條進 `carry` 的那一個。

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
| C46 | 完成；真的 home 上建立過項目（回報），「做完了」到關閉的一整輪還沒有結果 | #27 |
| C47 | 完成，Mac 上重跑通過（bash 5.3.20，回報） | #28 |
| C48 | 完成；修正之後在 bash 3.2 上的結果待回報 | 交接的 PR |
| C49 | 完成 | #32 |
| C50 | 完成 | #33 |
| C51 | 完成 | 這一條的 PR |

提過但沒有人要求、不做的三件：合併與拆分的來歷加一句原因；`find <議題>` 列出搬過的 task；沒有議題標記的排隊項目顯示在未分類區。C28 延後是使用者 2026-11-17 定的，要補的項目列在第 4 節。這三件不做，還等使用者點頭。

## 3. 還沒驗的事

[verification](verification.markdown)「沒驗到的」那張表是規劃當時寫的，下面是現在的結果。

| 項目 | 結果 |
| --- | --- |
| bash 3.2 的語法相容 | C48 修正後，Mac 上強制每一層都用 3.2.57 的結果和 5.3.20 相同（回報，commit `09cb5768`）：第一段全過，第二段過了前面的檢查後停在下一列說的那個測試輔助函式的問題。第三到六段在 3.2 上還沒有跑到 |
| 上線 R-1、R-2、R-3、R-6 | 通過（回報），細節在 [rollout](rollout.markdown) |
| 上線 R-4 | 作廢並改寫，見 [rollout](rollout.markdown) |
| 上線 R-5 | 通過：28 個 PR 的 base 都是 fork 的 `carry` |
| 上線 R-7（容量滿時照 `order` 的順序） | 待回報 |
| 需要 secondmate 的 1-1、1-6、1-7、1-8、3-1、3-2、3-3、4-2、4-3 | 待回報，逐項一個結果 |
| 兩種作答之後項目的狀態（4-4） | 待回報 |
| first mate 照規則在對的時機跑指令（6-2） | 真的 home 上看到它照規則 `propose`、`split`、`todo add`（回報）；全新的 session 從頭開始還沒看過 |
| stow 之後區塊的標記還在（6-4） | 待回報 |
| 「要你動手」的一整輪：做完了、驗證通過、關閉；另一輪驗證沒過 | 待回報，要等使用者按 |
| 其餘各段在 macOS 上（回報） | commit `e963dc78`、bash 5.3.20、設了 `TMPDIR=/tmp/t`：第一、二、三、四、六段通過，第五段因測試用了 macOS 沒有的 `ss` 停住。commit `09cb5768`、不設 `TMPDIR`：bash 5.3.20 與 3.2.57 結果相同，28 項通過後停在第二段的一個檢查，原因是測試的輔助函式 `tb_op` 用了 `"${3:-{\}}"`，那個反斜線在不同版本的 bash 留不留不一樣；已改。看板的程式在這幾次裡沒有出錯。改完之後兩種 bash 的全套結果待回報 |
| 服務活過 Claude Code session 結束（2-1） | 沒驗 |
| `tsc` 的輸出跨機器逐位元組相同（2-3） | 沒驗；`check-dist.sh` 只在這台 Linux 上跑過 |
| 原生拖放在 Chrome 上；真的滑鼠拖曳（5-1） | 沒驗：這台沒有 Chrome，測試用 headless Firefox 與合成的拖放事件 |
| 壓縮後 Claude Code 重印摘要（6-3） | 沒驗 |

## 4. 已知限制

各段與 [rollout](rollout.markdown) 另有各自的限制；這裡是跨段、接手的人最需要知道的。

測試蓋不到的：

- 寫入用的四支框架指令（`fm-inbox.sh`、`fm-send.sh`、`fm-on.sh`、`fm-captain-hold.sh answers`）在測試裡是替身。框架改了它們的輸出或 exit code，看板的測試不會失敗。細節與每一項對應的測試在 [contracts](contracts.markdown) 第 11 節。
- 進入點 `board-server.ts`、`board-client.ts` 與 `src/page/` 沒有單元測試，由 Bash 與瀏覽器的整合測試覆蓋；CRAP 與 mutation 的關卡只管函式庫模組（C28）。
- 窄視窗的版面沒有自動測試（C42）。
- 頁面在佇列裡有上百個項目時的速度沒有量過。

行為上的：

- 「要你動手」只支援主 home 的項目；按了「做完了」之後使用者不能自己收回；first mate 不能自己關掉項目，要使用者按「好，撤下」（C46）。
- `find` 平常每個議題只印最近八筆來歷（`--all` 印全部）；來歷不記拖曳排序、改目標、確認提議；`split` 不帶 task 會建一個空議題，新名稱可以和來源相同。
- `install-rules` 會換掉結束標記之後同一行的文字（有備份）；別處有一行以標記開頭時拒絕安裝（C37）。
- 程式退回沒有 `history` 或 `todos` 欄位的舊版時，下一次存檔會丟掉這兩個欄位（見 [rollout](rollout.markdown)）。
- first mate 自己直接做、沒有派 worker 的項目，在關掉之前會被 `order` 列在「可派」。

沒有做到的規範：C28 列的那幾項。

### 延後、之後要補的（C28）

使用者 2026-11-17 決定這些先不做，但要記得之後補上；不是放棄。

- `board-server.ts`、`board-client.ts` 與 `src/page/` 共 92 個函式不在 CRAP 的關卡內。做法是把進入點裡的邏輯抽成可以單獨測試的函式，再補單元測試。這是唯一有實際風險的一項，要分幾個 PR 做。
- 輪詢器裡「到期時間等於現在」的邊界有一個存活的突變（`<=` 換成 `<`）。
- `topics.split` 的 CRAP 是 11，門檻是 10。
- Bash 腳本的函式長度與複雜度沒有量過（上限是 100 行、複雜度 8）。

不補的兩項：超過 100 字元的中文訊息行；有些測試不是先寫的。

## 5. 交接之後誰做什麼

- 上游的新版合併進 `carry`：fleet 負責，見 [rollout](rollout.markdown)「之後怎麼更新」。
- 看板的檔案是 `topic-board/**` 與 `bin/fm-topic*.sh`。改到 [contracts](contracts.markdown) 第 11 節列的任何一支框架指令時，跑那一列寫的測試。
- 規則範本改了要升版本號（`captain.block.md.tmpl` 第一行），`stage-6-rules.sh` 裡的版本與 token 上限跟著改，真的 home 由使用者明講之後重跑 `install-rules`。
- `dist/` 要和 `src/` 一起提交；`dist/` 有變，執行中的看板要重啟才生效，`public/` 的 CSS 不用。
