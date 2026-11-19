# 在新機器上裝這個 fork：firstmate 加議題看板

這一頁從零開始，把這個 fork 的 firstmate 與議題看板裝到一台新機器上，每一步都附上怎麼確認做對了。
讀者可以是人，也可以是 agent。
內容只取自這個 fork `carry` 分支上追蹤的檔案；已經有別的文件寫好的地方，這裡只連過去，不重抄。

這一頁在 `carry` 分支上。
fork 的首頁顯示的是 `main`，和上游一樣，但首頁右側 About 的網站連結指到這一頁；要給別人看時，用同一個指到 `carry` 的網址：<https://github.com/guybeju/firstmate/blob/carry/FORK-SETUP.markdown>。

## 0. 先知道的事

- **為什麼用 fork 而不是上游**：看板（`myshape/` 與 `bin/myshape*.sh`）和 first mate 這一側接看板的指令（`bin/fm-board*.sh`、`bin/fm-dispatch-plan.sh`、`fm-board/`）只在 fork 的 `carry` 分支上。
  `carry` 是上游的 `main` 加上看板與 fork 自己的修正，上游沒有這些東西。
  fork 的 `main` 和上游的 `main` 相同，所以只 clone 不切換時，手上是沒有看板的上游版本。
- **怎麼跟著 `carry`**：home 的 checkout 停在預設分支 `main`，由 `config/self-update-source` 讓更新改從 fork 的 `carry` 前進。
  這個檔的規則在 [configuration「Self-update source」](docs/configuration.md#self-update-source-configself-update-source)。
  不要 `git clone -b carry`，也不要 `git checkout carry`：停在非預設分支的 checkout 會被更新跳過，開 session 時也會報 `TANGLE`（[configuration「Toolchain」](docs/configuration.md#toolchain) 的 Checkout diagnostics）。
- **兩種樣子**：只有一台機器、只有主 home，是第 1 到 7 步。
  有 second mate（同機或遠端）時，順序與多出來的步驟在第 8 節，先讀完再動手。
- **下面的路徑**：`<clone>` 是 fork clone 下來的目錄，同時也是主 home。
  沒有特別說的指令，工作目錄都是 `<clone>`。
- **給 agent 的提醒**：不是要當 first mate 的 session，不要把 `<clone>` 當專案目錄打開。
  上游的 `CLAUDE.md` 會匯入 `AGENTS.md`，`.claude/settings.json` 又掛了 hook，打開的 session 會自認是 first mate（[看板 spec「在哪裡、怎麼實作」](myshape/spec/README.markdown)）。
  從別的目錄開，用絕對路徑或 `git -C <clone>` 下指令。

## 平台：驗過什麼、沒驗過什麼

先看這一節，決定這台機器要不要多做驗證。

- **Linux**：上游的 README 列為支援的平台。
  看板在 Linux 上開發；[handover](myshape/spec/handover.markdown) 第 1 節要求在那台 Linux 上看板的測試全部通過，第 3 節沒有另外記一筆 Linux 全套測試的結果。
- **macOS**：上游的 README 列為支援的平台。
  看板的全套測試在 macOS 上跑過，記在 handover 第 3 節：當時的 commit 是 `faa7a8f6`，不設 `TMPDIR`。
  `PATH` 預設（bash 5.3.20）與 `PATH="/bin:$PATH"`（每一層都是 bash 3.2.57）結果相同：第一段 23 項、第二段 13、第三段 14、第四段 14、第五段 8 加上 `skip: firefox not found`、第六段 9，沒有失敗。
  工具是 BSD 的 `cut`、`awk`、`sed`、`grep`，`jq`，node 26.13.1，curl 8.7.1。
  用真的瀏覽器走頁面的那個測試因為沒有 Firefox 而跳過，handover 也註明最後的 commit 要再跑一次。
  那台 Mac 是遠端的 second mate，不是跑看板服務的主 home。
- **Windows、WSL**：沒有驗過。
  上游的 README 只列 macOS 與 Linux，這個 fork 也沒有任何在 Windows 或 WSL 上跑過的紀錄。

從零裝起這件事本身沒有完整驗過：handover 第 3 節的結果都來自已經在用的 home。
這一頁的第 2、3、5、6 步曾在 Linux 上一個暫時的 home 裡照本頁走過一遍，用 curl 代替瀏覽器開看板；第 4 步（開 session、補齊工具到能派工）與第 8 節沒有從零走過。

macOS 上 `bin/myshape*.sh` 與 `bin/fm-board.sh` 用的是 `PATH` 上第一個 `bash`（腳本第一行是 `#!/usr/bin/env bash`），細節在 handover 第 1 節。

## 1. 需要的東西

firstmate 本身的需求只在上游的文件寫一次，照那裡準備：

- [README「Requirements」](README.md#requirements)：一個支援的主 harness、`git`、`gh`（`gh auth login` 登入）、執行期 backend 的工具（預設 tmux）。
- [configuration「Toolchain」](docs/configuration.md#toolchain)：每個 home 都要的工具清單（`node`、`git`、`gh`、`no-mistakes`、`gh-axi`、`chrome-devtools-axi`、`tasks-axi`、`quota-axi`），加上依 backend 多出來的工具（tmux 要 `tmux` 與 `treehouse`）。
  第一次開 session 時 first mate 會列出缺的與太舊的工具，經你同意才裝，所以不必事先裝齊。

看板多要的東西（[rollout「前提」](myshape/spec/rollout.markdown)）：

- 主 home：`node` 22 以上與 `jq`。
  看板只跑編譯好的 `dist/`，不需要 TypeScript 支援。
- 開看板的瀏覽器要在主 home 這台機器上：服務只綁 `127.0.0.1`（[contracts](myshape/spec/contracts.markdown) 第 6.2 節）。
- 遠端 second mate 的機器：只要 `jq`，不需要 `node`（第 8 節）。
- `pnpm` 與 `firefox` 只有開發與跑看板的測試時才要（handover 第 1 節），裝起來用不需要。

**確認**：`node --version` 印出 22 以上，`jq --version` 有輸出；firstmate 自己的工具在第 4 步由啟動檢查確認。
**不對時**：照上面兩個上游連結安裝；`node` 低於 22 時看板的指令會停下並說要升級（第 5 步）。

## 2. clone fork

```
git clone https://github.com/guybeju/firstmate <clone>
```

fork 是公開的，用 https 讀取不需要憑證。
clone 下來的 `origin` 就是 fork；不需要另外加上游的 remote。
停在 clone 給的 `main`，不要切到別的分支。

**確認**：

```
git -C <clone> remote get-url origin        # https://github.com/guybeju/firstmate
git -C <clone> branch --show-current        # main
git -C <clone> merge-base --is-ancestor HEAD origin/carry && echo ok   # ok
```

最後一行印 `ok` 表示 `main` 可以快轉到 `carry`。
**不對時**：讀不到 fork 就查這台機器的對外連線或 proxy，不要改用需要憑證的網址（rollout R-3）。
`merge-base` 沒有印 `ok` 時，fork 的 `main` 有 `carry` 沒有的東西，快轉不會成功；這是 fork 維護者要處理的事，不要自己合併。

## 3. 跟到 `carry`

在 `<clone>` 寫 `config/self-update-source`，內容一行，第一個字是這台機器上指向 fork 的 remote 名稱：

```
mkdir -p <clone>/config
printf 'origin carry\n' > <clone>/config/self-update-source
```

然後更新。
還沒開過 session 時，直接在 shell 跑更新的指令（它是 `/updatefirstmate` 的第一步，[updatefirstmate 技能](.agents/skills/updatefirstmate/SKILL.md)；其餘步驟是重讀指示與重啟 second mate，這時還用不到）：

```
FM_HOME=<clone> <clone>/bin/fm-update.sh
```

已經在 session 裡時，改成對 first mate 下 `/updatefirstmate`；它印出 `reread-firstmate: yes` 時，重開 session 最乾淨。
環境裡的 `FM_HOME` 要嘛不設、要嘛指向 `<clone>`：指到別的 home，更新與後面的看板指令就會作用在那個 home 上（[configuration「FM_HOME」](docs/configuration.md#fm_home)）。

**確認**：輸出的前兩行是

```
self-update source: origin carry (config/self-update-source)
firstmate: updated <舊 commit>..<新 commit> (instructions changed: …)
```

之後 `git -C <clone> rev-parse HEAD` 要等於 `git ls-remote https://github.com/guybeju/firstmate.git carry` 的第一欄，`<clone>/myshape/`、`<clone>/bin/myshape.sh` 與 `<clone>/bin/fm-board.sh` 要存在。
再跑一次會印 `firstmate: already current`。

**不對時**：

- `config/self-update-source` 讀不懂、remote 不存在或分支名稱不合法時，整個更新在動任何東西之前停下並指出那個檔；照訊息改檔，不會退回 `origin`。
- `firstmate: skipped: …` 表示 checkout 髒了、不在預設分支或分歧了，更新什麼都沒動；照原因處理後再跑。
  原因是 `fetch of origin carry failed` 時是讀不到 fork，照第 2 步的「不對時」處理。
- 不要為了讓更新過而刪掉 `config/self-update-source`：home 跟到 `carry` 之後，拿掉這個檔會被當成分歧，要手動處理（[configuration](docs/configuration.md#self-update-source-configself-update-source)、[rollout「已知限制」](myshape/spec/rollout.markdown)）。

## 4. 開 session，補到能派工

照 [README「Install and launch」](README.md#install-and-launch) 在 `<clone>` 啟動主 harness，例如 Claude Code 是在 `<clone>` 裡跑 `claude`。
session 一開始會跑啟動檢查，列出缺的或太舊的工具與安裝指令；同意後 first mate 會裝能自動裝的，其餘照它印的說明手動裝（[configuration「Toolchain」](docs/configuration.md#toolchain)）。

**確認**：啟動摘要的 bootstrap 那一段沒有 `MISSING:`、`OUTDATED:`、`MISSING_MANUAL:`、`NEEDS_GH_AUTH`、`BACKEND_INVALID:` 這類行；全部正常時那一段是安靜的。
最後的證明是照 [README「Talk to it」](README.md#talk-to-it) 請它做一件專案裡的小事，看它派出 worker。

**不對時**：每一種診斷行的處理由 first mate 的 `bootstrap-diagnostics` 技能負責；照它印的指令或說明做。
這一步和看板無關，完全照上游的流程。

## 5. 開帳本，打開看板

開帳本（看板讀的是 firstmate 的 fleet ledger，[fleet-ledger](docs/fleet-ledger.md)；開帳本是 first mate 這一側的指令 `bin/fm-board.sh`，不是看板的）：

```
bin/fm-board.sh setup
```

**確認**：印出 `ok setup 帳本已開`，再跑一次印 `ok setup 帳本本來就開著`；`config/fleet-ledger` 存在。

打開看板。
預設的埠是 47819；要換就在 `config/myshape-port` 寫一行 1024 到 65535 的埠號。

```
bin/myshape.sh open
```

它在需要時啟動看板服務，印出 `http://127.0.0.1:<埠>/#t=<token>`。
這個 home 第一次 `open` 之前，看板其他的指令（`create`、`list`、`status` 等）都會回 1，說這裡沒有看板、要先跑 `open`：服務第一次啟動時寫下的 `state/myshape/token` 是看板認這個 home 的依據。
在這台機器的瀏覽器打開那個網址，停留一分鐘以上。
服務只在最近 2 分鐘內有人要過看板狀態時才輪詢各個 home（[stage-3-data](myshape/spec/stage-3-data.markdown)「輪詢」），頁面在前景時每 5 秒要一次（contracts 第 10 節）。
然後：

```
bin/myshape.sh status
```

**確認**：有 `看板服務：在跑`、`輪詢：進行中`、`aggregator：已接上（first mate）`，每一行 `home <id>：` 都是 `相同`（只有主 home 時只有 `home main：相同`）。
看板經 `bin/fm-board.sh` 讀 first mate 的資料、把頁面上的動作交給 first mate（[adapter](fm-board/spec/adapter.markdown) 第 3 節）；那支程式不在時這一行是 `aggregator：沒有接上（沒有 bin/fm-board.sh）`，頁面上的動作照常完成，要送出的會等到下一次服務啟動、程式在了再依序送出。
剛打開時那一行可能是 `還沒讀到`，等一下再看。

服務第一次成功啟動之後，主 first mate 每次開 session 都會檢查它：沒在跑就啟動，並在啟動摘要 fleet state 那一段的最後印一行 `看板服務：在跑`、`看板服務：原本沒在跑，已啟動`、`看板服務：原本沒有回應，已重新啟動` 或 `看板服務：無法啟動：<原因>`（[`bin/fm-topic-session-start.sh`](bin/fm-topic-session-start.sh)）。
沒拿到 session 鎖的唯讀 session、second mate 的 home、服務從來沒成功啟動過的主 home，都不檢查也不印這一行。

**不對時**：

- 指令以 exit 69 結束，stderr 是一行「看板服務無法啟動：<原因>。<怎麼修>。這次的要求沒有寫入。」（[contracts](myshape/spec/contracts.markdown) 第 9 節）；照那一行修。
  沒有 `node` 或低於 22、`myshape/dist/` 不完整（回第 3 步更新）、`config/myshape-port` 不合法，都在這一行說明。
  開 session 時的 `看板服務：無法啟動：<原因>` 是同一個原因，照著修，下一次開 session 或任何一個看板指令會再試。
- 上一次啟動失敗的原因在 `state/myshape/startup-error`，服務的輸出在 `state/myshape/service.log`（contracts 第 3 節）。
- 某個 home 顯示 `無法回報`（頁面上那個 home 的橫幅說原因，例如 `還沒換到 fork`）、`版本不相容` 或 `版本不同`，或頁面說帳本未開，表示那個 home 不在同一版或沒開帳本；只有主 home 時不會出現，有 second mate 時見第 8 節。
- 不用時 `bin/myshape.sh stop` 停掉服務；主 first mate 下一次開 session 時會再把它啟動。

## 6. 裝規則，重開 session

規則告訴 first mate 什麼時候該跑看板的指令。
它是最後一步：要等第 5 步的 `status` 每個 home 都是 `相同` 才裝（[rollout](myshape/spec/rollout.markdown) 第 7 步）。

```
bin/fm-board.sh install-rules
```

它把兩段規則各寫成一個標記區塊，放進 `data/captain.md` 與 `data/captain-shared.md`，區塊外的內容不動，寫之前備份到 `state/fm-board/rules-backup/`。
規則是 first mate 的，所以安裝的指令與範本（`fm-board/rules/`）都在 first mate 這一側。

**確認**：輸出有 `captain.md：新增（v10）` 與 `captain-shared.md：新增（v4）`（已經裝過的是 `已更新` 或 `已是最新`）。
之後 `bin/fm-board.sh rules` 印出 `規則：captain.md 和範本相同（v10）；captain-shared.md 和範本相同（v4）`。
裝完重開主 first mate 的 session：規則在下一次 session 開始或下一次壓縮之後才生效（`install-rules` 自己也會印這一句）。
重開的 session 的啟動摘要裡會有第 5 步說的那一行；服務一直開著時是 `看板服務：在跑`。

**不對時**：

- `標記不成對`：檔案裡的區塊標記被改壞了，那個檔沒有動；照訊息手動整理成一對標記，或兩個都刪掉再裝。
- `檔頭不合上游的要求`：`data/captain-shared.md` 的檔頭缺了上游要求的句子，那個檔沒有動；照訊息補上。
- 輸出最後的啟動記憶預算那一行說 `config/startup-memory-budget` 不存在：這個檔由 session 開始時的啟動檢查建立，第 4 步開過 session 就會有；規則本身照樣裝好了。

## 7. 之後怎麼更新

- **fork 有新版**（看板或 fork 的修正進了 `carry`）：在主 home 跑 `/updatefirstmate`。
  下一個看板指令發現服務的程式版本不同，會自動換掉舊服務（開 session 時的檢查不換，只回報 `看板服務：在跑`）；`status` 出現「目前的程式是 …；下一個指令或 restart 會換成新版」時，也可以直接 `bin/myshape.sh restart`。
  **確認**：`status` 的 `程式版本：` 等於 `git -C <clone> rev-parse HEAD`。
- **看板改名成 myshape 的那一次更新**（只有一次）：看板的程式、指令與檔案從 `topic-board`、`fm-topic.sh` 改名成 `myshape`、`myshape.sh`。
  有看板資料的 home 一更新到這一版，看板的每個指令都回 69，說這個 home 還有改名前的檔；還開著的舊服務也不再給頁面，直到那個 home 跑過 `bin/fm-board.sh migrate-myshape`。
  所以更新和搬家要在同一次做完：使用者明講之後，`/updatefirstmate`，再跑
  ```
  bin/fm-board.sh migrate-myshape --check
  bin/fm-board.sh migrate-myshape
  ```
  它停掉舊服務，把 `state/topic-board`、`data/topic-board`、`config/topic-board-port` 搬到新名字，核對搬過去的每個檔，換掉兩個規則檔裡舊標記的區塊（不用另外跑 `install-rules`），把看板自己下的 hold 的原因改成新的開頭 `看板佇列：`，清掉 checkout 裡改名前留下的 `topic-board/`，最後重新打開看板並印出網址；然後重開 session。
  **確認**：最後一行是 `已搬完`，前面有 `S6：… 個檔的校驗碼和搬之前相同` 與 `… 都和搬之前相同`；`bin/fm-board.sh migrate-myshape --check` 印 `已搬完`；`bin/fm-board.sh rules` 印 `規則：captain.md 和範本相同（v10）；captain-shared.md 和範本相同（v4）`；`bin/myshape.sh status` 是 `看板服務：在跑`，`程式版本：` 等於 `git -C <clone> rev-parse HEAD`。
  **不對時**：照它印的那一行處理後原樣再跑一次；中途停掉也一樣，再跑一次會接著做完。
  有 second mate 時，每個 second mate 的 home 也跑一次（遠端的是 `bin/fm-on.sh <id> fm-board.sh migrate-myshape`）：那裡沒有看板的檔，只清那個 code root；共用的規則檔照平常由主 home 傳過去。
  還沒重開的 session 照舊規則跑 `bin/fm-topic.sh` 時，那支舊名字什麼都不做，只回改用哪個指令與使用者還要跑什麼。
- **規則範本有變**：更新後 `bin/fm-board.sh rules` 會印 `和範本不同`；由使用者決定之後再跑一次 `bin/fm-board.sh install-rules`，再重開 session。
  有 second mate 時，先和第 8 節第 4 點一樣確認每個 home 都是 `相同` 再裝：新的規則可能用到只有新版程式才有的指令，例如共用規則從 v3 起叫 second mate 跑 `bin/fm-board.sh tag`，還沒更新的 home 沒有這支指令。
- **上游有新版**：只有在 fork 的維護者把上游的 `main` 合併進 `carry` 之後才會到你手上，之後就和「fork 有新版」一樣（[rollout「之後怎麼更新」](myshape/spec/rollout.markdown)）。
  這台機器不用自己合併上游。
- `carry` 的推送與 base 是 `carry` 的 PR 會跑 fork 自己的 lint 檢查 [`carry-lint.yml`](.github/workflows/carry-lint.yml)，內容是 `bin/fm-lint.sh` 完整的兩個 partition；它只在 fork 的 Actions 開著時才會跑。
  上游的 CI 只在 `main` 上跑，在 fork 上是停用的，所以上游的測試套件不會在 `carry` 上自動跑。
  base 是 `carry`、又改到看板或它用到的檔（列在那個檔的 `paths:`）的 PR，另外會跑看板的測試 [`carry-board-tests.yml`](.github/workflows/carry-board-tests.yml)：`myshape/test`、`fm-board/test`、`dispatch-plan/test`、`check-dist.sh`，以及單元測試、型別、lint、格式的檢查，在 GitHub 的機器上跑，不在這台機器上。
  這個檢查只供參考，不是合併的必要條件；沒改到那些檔的 PR 不會出現這個檢查。
  任何一個測試印出 `skip:` 時這個檢查就算失敗，job summary 列出每一個 `NOT RUN:`。
  它用的 pnpm 與 `tasks-axi` 鎖在只給 CI 用的 `ci-tools/board-tests/`。
- **退回較舊的版本或退回上游**：沒有定好的步驟。
  退版之前先備份 `data/topics.json`，舊版存檔時會丟掉後來才加的欄位（rollout「之後怎麼更新」）。
  要退回看板改名成 myshape 之前的程式，先在每個跑過 `migrate-myshape` 的 home 跑 `bin/fm-board.sh migrate-myshape --undo`，再退程式：舊的程式只認舊的名字。

## 8. 有 second mate 時

只有一台機器、沒有 second mate 的話，這一節可以跳過。
second mate 本身怎麼佈建照上游：同機的見 [secondmate-provisioning 技能](.agents/skills/secondmate-provisioning/SKILL.md)，遠端的見 [remote-secondmates](docs/remote-secondmates.md)。
看板要多做的事與順序在 [rollout「步驟」](myshape/spec/rollout.markdown)，順序不能換：

1. **每台遠端機器的 code root 先跟到 `carry`**（是 code root，不是 second mate 的 home）。
   code root 要有一個指向 fork 的 remote，並寫自己的 `config/self-update-source`，第一個字是那個 remote 在那台機器上的名稱。
   這個檔不繼承，每台都要自己寫，而且要常駐。
   rollout 第 2 步寫的是另外加一個叫 `fork` 的 remote，寫 `fork carry`；code root 若是從 fork clone 的，指向 fork 的就是 `origin`，要寫 `origin carry`（rollout R-1 的結果）。
   **確認**：在那台機器的 code root 跑 `git fetch <remote> carry`，exit 0（rollout R-3）。
2. **主 home 才寫 `config/self-update-source`、跑 `/updatefirstmate`**（第 3 步）。
   這一步一定在上一步之後：主 home 一旦跟到 `carry`，每次 session 開始都要求遠端 home 對齊到主 home 的 commit，遠端 code root 拿不到那個 commit 時，那個 home 的同步會一直被跳過。
   同機的 second mate 會自動跟到主 home 的 commit；遠端的 code root 依自己的 `self-update-source` 前進，home 再對齊到 code root。
   更新後照輸出的 `restart-secondmates:` 重啟 second mate（updatefirstmate 技能第 3 步）。
3. **每個 home 開帳本**：同機的是 `bin/fm-board.sh --in-home <id> setup`，遠端的是 `bin/fm-on.sh <id> fm-board.sh setup`。
   遠端那一行能跑、回 `ok setup …`，就表示那台已經跟到有 `fm-board.sh` 的 `carry`（rollout R-1）。
4. **確認每個 home 都在同一版**：打開看板停留一分鐘以上（讓遠端輪到一次），`bin/myshape.sh status` 的每一行 `home <id>：` 都要是 `相同`。
   `無法回報`、頁面上那個 home 的橫幅寫 `還沒換到 fork`，表示那台遠端還沒跟到 `carry`：停在這裡，不要做下一步，也不要拿掉任何一邊的 `config/self-update-source`，記下那台的更新錯誤訊息再處理（rollout R-1）。
5. **最後才裝規則**（第 6 步）：共用的那段規則會叫每個 second mate 跑 `fm-board.sh`，所以要等上一步全過。
   裝完重開主 first mate 的 session；second mate 在主 home 下一次啟動檢查把共用檔傳過去之後重啟。

之後新增的遠端 second mate：在那台機器手動 clone code root 之後先做上面的第 1 點，再照上游的流程佈建 home；不把已經存在的 `origin` 改成指向 fork（rollout「之後怎麼更新」）。

**會停掉 Mac 上 second mate、或讓它的伺服器離開登入 session 的 Herdr 操作**：遠端 second mate 跑在 Firstmate 在 Mac 上起的 Herdr 伺服器裡（主 code root 的是 `fm-remote` session，[remote-secondmates「How the Herdr launch agent starts its server」](docs/remote-secondmates.md#how-the-herdr-launch-agent-starts-its-server)）。
伺服器一停，裡面每個 pane 都結束，second mate 也停了；伺服器換成不是在登入 session 起的程序時，裡面的 pane 讀不到登入鑰匙圈。
要看 second mate 在做什麼，從主 home 用 `bin/fm-peek.sh`，不要直接接進那個 session。
下表的「救回」都是同一套：沒有 second mate 正在啟動或復原時，跑 `bin/fm-on.sh <id> fm-remote-doctor.sh`，照它的 `action:` 做，需要時再跑 `bin/fm-on.sh <id> fm-remote-doctor.sh --fix`（[Repair with --fix](docs/remote-secondmates.md#repair-with---fix)），然後請 first mate 重新啟動那個 second mate（[Launch or recover](docs/remote-secondmates.md#launch-or-recover)）。
那個 session 裡還有 pane 時，`--fix` 不會動伺服器，要先請 first mate 停下 second mate。

| 操作 | 現在對 second mate 的影響 | 改做什麼、怎麼救回 |
| --- | --- | --- |
| `herdr machine add`，問要不要重啟時答 y | 現在的伺服器是 session leader，Herdr 應該不會再問（Mac 上真的伺服器量過是 session leader，對它跑 `machine add` 還沒驗過）；問了就表示那台的伺服器不是照現在的方式起的，這時答 y 會停掉它，換上一個從 SSH 起、讀不到登入鑰匙圈的伺服器 | 答 N（預設就是 N），告訴 first mate；doctor 不檢查伺服器是不是 session leader |
| `herdr --remote`（Herdr 自己的 SSH 接入） | 伺服器沒在跑時從 SSH 起一個，裡面的 pane 讀不到登入鑰匙圈；對正在跑的伺服器會不會要求重啟，現在的起法下沒有驗過 | 不要對那個 session 用；被它起了伺服器就救回，`--fix` 會換回 launch agent 起的伺服器 |
| live handoff（`--handoff`） | 換掉伺服器的程序；launch agent 跟著舊程序結束，Firstmate 證明不了新的程序是在登入 session 起的，doctor 把它當成外來的伺服器 | 不要用；用了就救回 |
| `herdr update` | 可能停掉或換掉伺服器（這個 fork 沒有驗過） | second mate 在跑時不要做；做了就救回 |
| `herdr server stop` | 停掉伺服器；launch agent 把正常結束當成做完，不會自己再起 | 不要用（[herdr-backend「Destructive lab safety」](docs/herdr-backend.md#destructive-lab-safety)）；用了就救回 |
| `herdr session stop` | 同上：伺服器停掉，launch agent 停著不再起 | 不要用；用了就救回 |

## 這一頁怎麼保持正確

看板每次修改（程式、指令、規則範本、需要的工具）都要在同一個修改裡對照這一頁、改掉不一致的地方，PR 說明裡寫出這一頁查過了、改了什麼。
這條規則記在 [handover](myshape/spec/handover.markdown) 第 5 節。

`fm-board/test/check-guide.sh` 自動檢查這一頁的一部分，由 `fm-board/test/run.sh` 一起跑（`stage-6-guide.sh`）：

- 每個相對連結指到的檔案存在（不檢查 `#` 後面的段落錨點）。
- 提到的每支 `bin/fm-*.sh` 與 `bin/myshape.sh` 存在而且可以執行。
- `myshape.sh`、`fm-board.sh`、`fm-dispatch-plan.sh` 後面接的每個子命令都列在那支指令開頭的用法裡。
- 提到的每個 `config/<名稱>` 都出現在 `bin/` 的某支腳本裡。
- 寫成 `/<技能>` 或「`<名稱>` 技能」的，在 `.agents/skills/` 底下都有那個技能。
- 寫在 `captain.md` 與 `captain-shared.md` 後面的版本（例如 `（v10）`）等於 `fm-board/rules/` 裡範本的版本。

只能靠人或 agent 讀過才能確認的：

- 步驟的順序與理由，和 rollout 是否一致。
- 每一步「確認」寫的輸出是否還是程式現在印的字。
- 平台那一節是否和 handover 第 3 節一致。
- 指到上游文件的段落錨點是否還在，上游文件的內容是否還支持這裡的說法。
- 需要的工具是否變了（上游的工具清單或看板的 `node` 版本）。
