# first mate 這一側：看板的轉接指令

看板（`myshape/` 與 `bin/myshape*.sh`）是使用者派工的方式和 agent 之間的轉接層，不綁 first mate。
凡是讀寫 first mate 自己的檔、用 first mate 函式庫的事，都放在這一側；看板的程式不 source 這一側的任何檔。
依賴只有一個方向：這一側可以讀看板的檔、跑看板的指令，看板不讀這一側。

看板的契約在 [contracts](../../myshape/spec/contracts.markdown)；這一頁只寫 first mate 這一側。

## 1. 檔案

| 路徑 | 內容 |
| --- | --- |
| `bin/fm-board.sh` | 轉接指令：`tag`、`setup`、帶 task 的 `split`、`--in-home`、`install-rules`、`rules`，與一次性的 `migrate-myshape` |
| `bin/fm-board-migrate-lib.sh` | `migrate-myshape` 的步驟（C57）；只有 `fm-board.sh` source 它，每個 home 都搬完之後拿掉 |
| `bin/fm-topic.sh` | 改名前的指令名稱留下的提示（第 2 節）；每個 home 都搬完之後拿掉 |
| `bin/fm-board-lib.sh` | 找同機 secondmate 的 home、在那個 home 執行指令；`fm-board.sh` 與 `fm-topic-board-read.sh` source 它 |
| `bin/fm-dispatch-plan.sh` | `order`：照看板的佇列排出該派、該 hold、該解除的 backlog 項目 |
| `fm-board/rules/` | 三個規則範本，副檔名 `.md.tmpl`（fork 不能新增追蹤的 `.md`） |
| `fm-board/test/` | `run.sh` 與這一側的測試：`tag`、`setup`、`--in-home`（`stage-1-tag.sh`），帶 task 的 `split`（`stage-3-split.sh`），規則與安裝說明（`stage-6-*.sh`、`check-guide.sh`），改名前的名字與 `migrate-myshape`（`stage-8-*.sh`） |
| `dispatch-plan/test/` | `run.sh` 與 `order` 的測試（`stage-1-order.sh`） |
| `fm-board/spec/` | 這一頁 |

`bin/` 底下的五支和看板的指令一樣，要通過 `bin/fm-lint.sh <檔>` 與 bash 3.2 的語法檢查。
`fm-board.sh` 要在 git 裡是可執行的：遠端 home 的 `tag` 與 `setup` 經 `fm-on.sh` 跑，它只執行追蹤、可執行的 `bin/fm-*.sh`。

## 2. 舊的寫法

這些子命令在改名（[open-issues](../../myshape/spec/open-issues.markdown) C57）之前的看板指令 `fm-topic.sh` 裡。
那個名字現在是這一側的提示 `bin/fm-topic.sh`：任何呼叫都回 2，什麼都不寫；不轉送，也沒有第二條路。
stderr 第一行指出新的指令，第二行說使用者還要做什麼：這個 home 還沒搬就跑 `bin/fm-board.sh migrate-myshape`，`data/captain.md` 還是舊標記的區塊就重跑 `bin/fm-board.sh install-rules` 再重開 session，不然就是 session 載入的規則比 home 的舊，重開 session。
看板的 `myshape.sh` 只留帶 task 的 `split` 的舊寫法；其餘六種在那裡是不認得的子命令。

| 舊的 | 新的 |
| --- | --- |
| `fm-topic.sh tag …` | `fm-board.sh tag <task-id> <議題 id>`、`tag <新 id> --from <舊 id>` |
| `fm-topic.sh --in-home <id> …` | `fm-board.sh --in-home <id> tag\|answers\|setup` |
| `fm-topic.sh setup` | `fm-board.sh setup` |
| `fm-topic.sh split … <task>…` | `fm-board.sh split <議題 id> <新名稱> --goal <一行> <task>…`；不帶 task 的 `split` 還是看板的 |
| `fm-topic.sh install-rules` | `fm-board.sh install-rules` |
| `fm-topic.sh status` 的「規則：」那一行 | `fm-board.sh rules` |
| `fm-topic.sh order` | `fm-dispatch-plan.sh order`，內容不變 |
| 其他的 `fm-topic.sh …` | `myshape.sh`，參數相同 |

## 3. 看板怎麼用到這一側

看板服務的白名單（contracts 第 7 節）裡，W5、W7、W8、W9 跑的是 `fm-board.sh`：同機 secondmate 的作答（`--in-home <sm> answers`），以及頁面上的「歸併到…」（主 home、同機、經 `fm-on.sh` 到遠端的 `tag`）。
頁面在 home 的帳本沒開時顯示的指令也是 `fm-board.sh setup`。

在看板自己存「要你動手」的項目之前，`myshape.sh todo add` 與 `todo done` 還會執行（不 source）四個 first mate 的指令：`fm-topic-board-read.sh`（判斷 task 是什麼）、`fm-captain-hold.sh hold`、`fm-board.sh tag`、`fm-captain-hold.sh answers`。

## 4. `fm-board.sh` 的 exit code

| 碼 | 意思 |
| --- | --- |
| 0 | 成功，含原樣重做 |
| 1 | 被拒絕或失敗，確定沒寫入 |
| 2 | 用法錯 |

例外：`--in-home <id> answers` 原樣傳回 `fm-captain-hold.sh` 的 exit code 與輸出；`split` 在看板拒絕或連不上時傳回 `myshape.sh` 的 exit code（3、69 的意思見 contracts 第 9 節）。

## 5. 寫的檔

| 路徑 | 權限 | 誰寫 |
| --- | --- | --- |
| `data/<task-id>/topic` | 0644 | `tag`；每個 home 各自一份，看板經彙整腳本讀 |
| `config/fleet-ledger` | — | `setup`；上游的帳本旗標 |
| `data/captain.md`、`data/captain-shared.md` 裡的標記區塊 | — | `install-rules` |
| `state/fm-board/rules-backup/` | 0700 | `install-rules` 寫入前的備份 |
| `state/fm-board/migrate-myshape.journal`、`migrate-myshape.d/`、`migrate-myshape.lock/` | — | `migrate-myshape` 的紀錄、它記下的校驗碼與 hold 原因、同時只跑一個的鎖；`--undo` 做完時刪掉紀錄 |
| `state/myshape/`、`data/myshape/`、`config/myshape-port` | — | `migrate-myshape` 從改名前的名字搬過來；之後由看板自己寫 |

改名前的看板指令的備份在 `state/topic-board/rules-backup/`；`migrate-myshape` 把它們搬到 `state/fm-board/rules-backup/`。

## 6. 規則範本

- 標記行的開頭是 `<!-- myshape:begin`、結尾是 `<!-- myshape:end -->`：`install-rules` 以這個開頭（容許前面的空白）找區塊，所以裝過的區塊會原地換掉，不會多出第二份。
- 改名前的標記 `<!-- topic-board:begin` 與 `<!-- topic-board:end -->` 只為了換掉它而認得：只有舊標記的區塊時原地換成新的，兩種都有時換掉新的、拿掉舊的，任一種不成對就不動那個檔；`rules` 把舊標記的區塊報成 `舊標記（vN）`，兩種都有時報成 `…，另有舊標記（vN）`。
- 第一行的 `vN` 給人看，內容才決定是不是最新；改了範本就升版本號，`fm-board/test/stage-6-rules.sh` 裡的版本、`FORK-SETUP.markdown` 寫的版本跟著改（`check-guide.sh` 會檢查後者）。
- 三個範本合計的 token 上限在 `stage-6-rules.sh`（`(位元組 + 2) / 3`）。
- 真的 home 要由使用者明講之後重跑 `bin/fm-board.sh install-rules`；有 second mate 時先確認每個 home 都在同一版（[FORK-SETUP](../../FORK-SETUP.markdown) 第 8 節）。

## 7. 依賴的框架介面

框架改到下面任何一項，就可能在不碰這些檔的情況下弄壞它們。

| 框架的東西 | 誰用 | 靠的是 | 測試 |
| --- | --- | --- | --- |
| `bin/fm-primary-scope-lib.sh` 的 `fm_root_is_secondmate_home <home>` | `fm-board.sh`、`fm-dispatch-plan.sh` | 回傳值分辨 secondmate home | `fm-board/test/stage-1-tag.sh` 的 `test_tag_in_secondmate_home_checks_format_only`；`dispatch-plan/test/stage-1-order.sh` 的 `test_falls_open_without_a_usable_topic_file` |
| `bin/fm-secondmate-registry-lib.sh` 的 `secondmate_registry_field`、`secondmate_registry_parse_line` | `fm-board-lib.sh`、`fm-board.sh install-rules` | `data/secondmates.md` 解析出 id、home、是不是遠端 | `stage-1-tag.sh` 的 `test_in_home_routes_to_a_local_secondmate` |
| `bin/fm-config-inherit-lib.sh` 的 `shared_captain_header_valid <檔>` | `fm-board.sh install-rules` | 共用檔的檔頭上游收不收 | `stage-6-rules.sh` 的 `test_creates_both_files`、`test_refuses_a_shared_file_with_a_bad_header` |
| `bin/fm-startup-memory-budget.sh report` | `fm-board.sh install-rules` | 只印它的輸出；失敗時印一句替代的話 | `stage-6-rules.sh` 的 `test_creates_both_files` |
| `bin/fm-fleet-snapshot.sh --json` | `fm-dispatch-plan.sh order`、`migrate-myshape` 找要換原因的 hold | 和彙整腳本相同（contracts 第 11.1 節） | `dispatch-plan/test/stage-1-order.sh` 全部 |
| `bin/fm-tasks-axi.sh hold <id> --reason <文字>`、`unhold <id>` | `order` 只印成給 first mate 照著跑的指令；`migrate-myshape` 用 `hold` 換掉沒有種類的 hold 的原因 | 指令的形狀；對已經 hold 的項目再 `hold` 一次只換原因、中間不解除，但會拿掉 hold 的種類（tasks-axi 0.2.6 實測），所以有種類的 hold 不換 | `stage-1-order.sh` 的 `test_sections` 只檢查印出來的字串；`stage-8-migrate.sh` 用真的 `tasks-axi` |
| `bin/fm-captain-hold.sh answers --source myshape` | `fm-board.sh --in-home <id> answers` | 在那個 home 執行並原樣傳回 | `stage-1-tag.sh` 的 `test_in_home_answers_passes_through`（替身） |
