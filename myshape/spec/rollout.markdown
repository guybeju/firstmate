# 上線

這不是一個 PR，是六段都合併進 fork 的 `carry` 之後，把看板開始用起來的步驟。全部由使用者執行或明講之後才執行。

## 前提

1. **主 home 的 firstmate 要先裝到能用**。2026-11-16 時它還不能派工，缺 `tasks-axi`、`quota-axi`、`gh-axi`、`no-mistakes`、`treehouse`。這是使用者的環境工作，不在這份 spec 的步驟裡。
2. 主 home 有 `node` 22 以上與 `jq`。這台是 node v22.22.1；它沒有 TypeScript 支援，但看板只跑編譯好的 `.js`，不受影響。
3. 每台遠端機器有 `jq`。遠端不需要 `node`，不需要看板服務，沒有議題檔。
4. 六段都已合併進 `carry` 並推上 fork（<https://github.com/guybeju/firstmate>）。
5. 主 home 的 checkout 有一個指向 fork 的 remote。規劃時它叫 `fork`、`origin` 指向上游；2026-11-16 之後主 home 改成 `origin` 指向 fork、`upstream` 指向上游。下面步驟裡寫的 `fork carry`，在主 home 要寫成 `origin carry`：`config/self-update-source` 的第一個字是那台機器上指向 fork 的 remote 名稱。
6. 每個 code root 都停在預設分支、工作目錄乾淨。

## 步驟

順序不能換。第 2 步要在第 3、4 步之前：主 home 一旦跟到 `carry`，每次 session 開始都會要求遠端 home 對齊到主 home 的 commit；遠端 code root 拿不到那個 commit 時，該 home 的同步會一直被跳過。

1. **確認功能已在 fork 的 `carry`**：`git ls-remote https://github.com/guybeju/firstmate.git carry`。
2. **每台遠端機器的 code root**（是 code root，不是 secondmate home）：
   - `git remote add fork https://github.com/guybeju/firstmate.git`。fork 是公開的，用 https 讀取不需要憑證。
   - 寫 `<code root>/config/self-update-source`，內容一行 `fork carry`。這個檔不繼承，每台都要自己寫，而且要常駐：拿掉之後下次更新會因為分歧而中止。
   - `origin` 不動。
3. **主 home**：寫 `config/self-update-source`，內容一行 `fork carry`。
4. **在主 home 跑 `/updatefirstmate`**。主 home 前進到 `carry`；同機的 secondmate 跟到主 home 的 commit；每台遠端 code root 依自己的 `self-update-source` 前進到 `carry`，遠端 home 再對齊到 code root。更新後上游會列出要重啟的 secondmate，照做。
5. **每個 home 開帳本**：
   - 主 home：`bin/fm-board.sh setup`
   - 同機的 secondmate：`bin/fm-board.sh --in-home <id> setup`
   - 遠端：`bin/fm-on.sh <id> fm-board.sh setup`
6. **確認每個 home 都在同一版**：`bin/fm-topic.sh open`，打開看板停留一分鐘以上（讓遠端輪到一次），再跑 `bin/fm-topic.sh status`。每個 home 都要是「相同」，沒有「還沒換到 fork」「版本不相容」「版本不同」「帳本未開」。
7. **最後才裝規則**：`bin/fm-board.sh install-rules`。共用段會叫每個 secondmate 跑 `fm-board.sh`，所以要等第 6 步全過。裝完重啟主 first mate 的 session；secondmate 在主 home 下一次 bootstrap 之後重啟。

## 上線時要驗的事

這些都需要真的 secondmate，規劃時這個 home 一個都沒有。2026-11-17 主 first mate 在真的 home 與一台遠端的 Mac（secondmate `macmate`）上驗過的結果寫在表後；其餘的結果在 [handover](handover.markdown) 第 3 節。各段「先驗再做」裡標了需要 secondmate 的項目（1-1、1-6、1-7、1-8、3-1、3-2、3-3、4-1、4-2、4-3）也在這時候一起驗。

| # | 要驗的事 | 怎麼驗 | 假設不成立時 |
| --- | --- | --- | --- |
| R-1 | 第 2 到 4 步的順序在真機上走得通：遠端 code root 依自己的 `self-update-source` 前進到 `carry`，遠端 home 再對齊到 code root | 先只拿一台遠端做。第 4 步之後 `bin/fm-on.sh <id> fm-board.sh setup` 能跑就是到了 | 到不了就停在第 4 步，不做第 5 步之後的事，也不要拿掉任何一邊的 `config/self-update-source`（拿掉會讓下次更新因分歧而中止）。主 home 留在 `carry` 上沒有壞處：看板把那台遠端標成「還沒換到 fork」，其餘照常。把那台遠端的更新錯誤訊息記下來，回頭開一個決定 |
| R-2 | 遠端的 secondmate agent 自己跑 `bin/fm-board.sh tag` 時，用的是 home 的 `bin/` 還是 code root 的 `bin/` | 請遠端的 secondmate 跑 `bin/fm-topic.sh --help`，並回報當時的 `pwd` | 兩份在第 4 步之後是同一個 commit，哪一份都可以。只有兩者版本分歧時才有差別，看板會顯示「版本不同」 |
| R-3 | 遠端帳號用 https 讀得到 fork | 第 2 步之後在遠端 code root 跑 `git fetch fork carry` | 讀不到就查那台機器的對外連線或 proxy；不要改用需要憑證的網址 |
| R-4 | 開發用的 clone 用網址直接 fetch 上游、合併進 `carry` 的流程 | 上游第一次有新 commit 時照「之後怎麼更新」做一次 | 合併有衝突代表 fork 改到了上游的檔案，違反只新增的原則，要先找出是哪個檔 |
| R-5 | 第一次開 PR 時 `gh pr create --repo guybeju/firstmate --base carry --dry-run` 的目標是 fork 的 `carry` | 第一段的 PR 開之前跑一次 | 目標不對就不開，先查 clone 的 remote |

| R-6 | 遠端 home 的 `origin` 實際是 code root 的路徑（研究時依 `git clone` 的行為推論） | 在遠端 home 跑 `git remote get-url origin` | 不是的話，第 4 步「遠端 home 對齊到 code root」可能抓不到 `carry` 的 commit，表現和 R-1 失敗相同，照 R-1 處理 |
| R-7 | 設了 `config/project-capacity` 之後，容量滿時項目留在排隊中，下一輪照 `order` 的順序讓高優先的先拿到空位 | 設容量為 1、排兩個不同佇列的項目，看哪一個先被派 | 不成立的話「高優先先派」在容量滿時沒有效果，只剩「待辦不派」有效。這是 first mate 的行為，看板不用改 |

結果（主 first mate 回報，這份 spec 的作者沒有自己重跑）：

- R-1 通過：Mac 的 code root 依 `self-update-source` 跟著 `carry`，code root 與 home 在同一個 commit；`bin/fm-on.sh macmate fm-topic.sh setup` 回「ok setup 帳本本來就開著」；`status` 顯示「home macmate：相同」。那台 Mac 上 fork 的 remote 叫 `origin`，不是第 2 步寫的 `fork`，`self-update-source` 寫的是 `origin carry`。
- R-2 通過：遠端的 secondmate 回報 `pwd` 是它的 home，`bin/fm-topic.sh --help` 印出用法，跑的是 home 的 `bin/`，commit 與 code root 相同。
- R-3 通過：在 Mac 上 `git fetch origin carry` 走 https，exit 0。
- R-4 作廢：這一列假設「合併有衝突代表 fork 改到了上游的檔案」。fleet 之後在 `carry` 上改了上游的檔案（fork 的 PR 20 到 24、26），衝突不再代表看板違反只新增。上游合併改由 fleet 負責，見下一節。
- R-5 通過：每個 PR 的 base 都是 fork 的 `carry`。
- R-6 通過：Mac 的 home 的 `origin` 是它的 code root 的路徑。
- R-7 驗了一半：暫時的 home 裡 `order` 照佇列的順序列出可派的項目，待辦的列為該 hold；真的派到容量滿的那一半沒有驗，見 [handover](handover.markdown) 第 3 節。

## 之後怎麼更新

- **看板有新版**：合併進 `carry` 並推上 fork，然後在主 home 跑 `/updatefirstmate`。下一個議題指令會發現服務的程式版本不同，自動換掉舊服務。
- **上游有新版**：由 fleet 把上游的 `main` 合併進 `carry`（2026-11-17 起；原本寫的是看板開發用的 clone）。一定是真的 merge，不 squash、不 rebase：`carry` 分歧的話主 home 的更新會被跳過。開發用的 clone 沒有上游的 remote，合併時用網址直接 fetch：`git fetch https://github.com/kunchenguid/firstmate.git main && git merge FETCH_HEAD`。合併後跑一次看板與 first mate 這一側的全部驗收（`topic-board/test/run.sh`、`fm-board/test/run.sh`、`dispatch-plan/test/run.sh`；特別是 `bin/fm-doc-audience-check.sh` 與 `bin/fm-test-run.sh --check-coverage`，上游可能改了它們的範圍），再推上 fork、跑 `/updatefirstmate`。
- **退回較舊的版本**：`data/topics.json` 的 `history`、`todos`，以及 `history` 每一筆裡的 `reason` 與 `by`，都是後來才加的欄位，舊版存檔時不會寫回。以 `history` 為例：沒有這個欄位的舊版程式讀得懂這個檔，但它下一次存檔時不會寫回 `history`，來歷紀錄就沒了（議題本身與 `merged` 表不受影響）。要退版又想留著紀錄，先備份這個檔。
  退回 C52 之前的版本時，檔案照樣讀得懂（`status` 一律是 `confirmed`），議題都還在佇列裡；那一版又會有 `propose` 與提議中的狀態，規則也要跟著退回 v6。
- **規則範本有變**：更新後 `bin/fm-board.sh rules` 會顯示「和範本不同」，由使用者再跑一次 `bin/fm-board.sh install-rules`。
- **之後新增的 secondmate**：遠端的 code root 是使用者在那台機器上手動 clone 的。clone 完就做第 2 步，再照上游的流程佈建 home。不把 `origin` 改指向 fork。

## 已知限制

- **退回上游沒有定**。home 一旦在 `carry` 上，就不是上游的祖先；拿掉 `self-update-source` 之後更新會中止，要手動處理。
- 上游的 CI 只在 `main` 的 push 與 base 是 `main` 的 PR 上跑（`.github/workflows/ci.yml:3-10`、`no-mistakes-required.yml:4-8`）。`carry` 上沒有任何自動檢查，全靠各段驗收裡列的本機指令。
- 轉交給 secondmate 之後才改順序、拖進待辦或封存，傳不到 secondmate。
- 議題進出待辦之後，要等 first mate 下一次跑 `order` 才會同步 hold；中間這段，新移進待辦的議題底下還沒 hold 的項目可能被派出去。
