# DualPod

[English](README.md) · **繁體中文**

DualPod 是 macOS 選單列 App，把 Mac 的聲音送到兩台 HomePod mini，一台當左聲道、一台當右聲道。不能配成立體聲的組合（例如一代配二代）也可以。Mac 本機喇叭也可以一起播，並對齊時間。

<img src="docs/menu.png" width="279" alt="DualPod 選單：兩台 HomePod mini 分別播左右聲道，加上這台 Mac">

## 起因

開開心心買了一台 HomePod mini 第二代回家，才發現它沒辦法跟之前那台第一代配成立體聲，很生氣，所以有了這個專案。

## 需要

- Apple 晶片的 Mac，macOS 14.4 以上。
- 一到兩台 HomePod，和 Mac 在同一個網路。測過 HomePod mini 第一代與第二代。大尺寸 HomePod 會出現在 DualPod 的喇叭清單，但沒測過。其他 AirPlay 裝置不會出現。
- Mac 的管理員密碼，安裝、更新、移除背景服務時要輸入。背景服務是 DualPod 負責串流的部分。

## 安裝

1. 從 [Releases](https://github.com/NightLightTw/dualpod/releases) 下載 `DualPod-<版本>.zip`，解壓縮後把 `DualPod.app` 拖到「應用程式」資料夾。
2. 打開它。DualPod 是免費軟體，沒有經過 Apple 公證，第一次打開時 macOS 會擋下來，顯示 Apple 無法驗證。這代表 App 沒有經過 Apple 付費的公證，不是偵測到惡意程式。想自己編譯的話，原始碼都在這個 repo。
   - macOS 15 以上：按「完成」，到「系統設定 → 隱私權與安全性」往下捲，在 DualPod 旁按「強制打開」，輸入密碼。
   - macOS 14：在 Finder 按住 Control 點 App，選「打開」，再按「打開」。
3. App 會問「要安裝背景服務嗎？」，按「安裝」並輸入密碼。
4. 勾選喇叭前，先照下面「『家庭』App 設定」那一節，讓喇叭不用密碼就能存取，否則 HomePod 會沒有聲音。
5. 點選單列的 DualPod 圖示（兩個交疊的圓環）。大約一分鐘內會列出同一個網路上的 HomePod，勾選要出聲的喇叭。
6. 第一次播放時，macOS 會詢問錄製系統聲音的權限。請允許，否則喇叭會沒有聲音。

### 權限與原因

| 權限 | 原因 | 不小心拒絕了 |
|---|---|---|
| 管理員密碼 | 安裝負責串流的背景服務，並綁定 AirPlay 對時需要的網路埠。裝好之後切換喇叭不用密碼 | 無法串流 |
| 錄製系統聲音 | 錄下 Mac 正在播的聲音送到喇叭。不錄麥克風，聲音只送到你勾選的喇叭 | 到「系統設定 → 隱私權與安全性 → 螢幕與系統錄音」打開 DualPod 或 audiotee（DualPod 內附的錄音元件），再取消、重新勾選一次喇叭 |
| 麥克風（可不給） | 只有「自動對齊」會用，讓 Mac 喇叭和 HomePod 同步。它會聽喇叭最多約一分鐘 | 到「系統設定 → 隱私權與安全性 → 麥克風」打開 DualPod |

安裝後，「系統設定 → 一般 → 登入項目與延伸功能」會多一個叫 **zsh** 的背景項目，那就是 DualPod 的背景服務（由 launchd 執行的 shell script）。關掉它 DualPod 就不能播。

### 「家庭」App 設定

DualPod 不支援 HomeKit 配對與喇叭密碼。請在「家庭」App 的「家庭設定 → 揚聲器與電視」選「連接相同網路的人」，並關閉「需要輸入密碼」。這樣同一個網路上的人都能對 HomePod 播放，所以請在自己信任的家用網路使用 DualPod。選了「只限共享此家庭的成員」或設了密碼，HomePod 會沒有聲音，DualPod 也不會提示原因。

## 使用

下面的「設定…」在選單列 DualPod 圖示的選單裡，不是 macOS 的「系統設定」。App 介面跟隨系統語言，也可以在「設定… → 一般 → 語言」切換。

- 勾一台 HomePod：播完整的立體聲。
- 勾兩台 HomePod：一台左聲道、一台右聲道。到「設定… → 音訊 → 左右聲道」點喇叭，它會從那一邊響一聲。左右相反就按「交換左右」。
- 同時勾「這台 Mac」：Mac 喇叭一起播完整的聲音。有回音時，到「設定… → 音訊 → 這台 Mac 的喇叭」按「自動對齊…」，請在安靜的地方用。
- 選單裡每台喇叭都有自己的音量滑桿。
- 「設定… → 光暈」會在串流時讓 HomePod 頂端亮出顏色（聲波光暈）。需要 HomePod 軟體 27.2，並在「家庭」App 開啟聲波光暈。
- 「結束 DualPod」：串流停止，聲音回到 Mac。

<img src="docs/glow.png" width="400" alt="DualPod 設定的光暈頁面，有幾組顏色可選">

## 已知限制

- 聲音大約晚 0.3 秒才從 HomePod 出來。聽音樂感覺不到，看影片時聲音可能比畫面晚一點點。
- 串流一直失敗（例如 Wi-Fi 斷線）時，5 分鐘內重新連線超過 5 次，DualPod 會放棄。網路恢復後取消、重新勾選一次喇叭。
- 其他裝置（iPhone、別台 Mac）播到 DualPod 正在用的 HomePod 時，DualPod 會讓位、不搶回來，選單顯示「被其他裝置接走了，點這裡搶回來」。HomePod 同時只能播一個來源，兩邊沒辦法一起播。
- 開著 VPN 或同時啟用多個網路介面時，可能用錯介面，喇叭會沒有聲音。請關掉 VPN，再取消、重新勾選一次喇叭。

## 疑難排解

1. 選單顯示背景服務停止，或出現「更新背景服務…」（App 內附的背景服務和已安裝的不同，通常是換了版本之後）：點那一項重新安裝或更新。
2. 顯示播放中卻沒有聲音：檢查上面的「錄製系統聲音」權限與「家庭」App 設定，有開 VPN 先關掉。
3. 找不到 HomePod：確認它開著、和 Mac 在同一個網路。清單大約每分鐘更新一次。
4. 還是不行：「設定… → 一般 → 疑難排解」可以按「打開 log 資料夾」，或按「複製診斷資訊」回報問題。

## 移除

「設定… → 一般 → 背景服務 → 管理 → 移除…」，再把 App 丟到垃圾桶。背景服務停止或需要更新時，那一頁沒有「管理」，改成「移除背景服務 → 移除…」。

App 已經刪掉的話，在「終端機」執行下面四行（名稱是 DualPod 的舊名 AirPlay Stereo）。終端機在「應用程式 → 工具程式」裡。一次貼一行，按 Return。第一個 `sudo` 會要 Mac 密碼，輸入時畫面不會顯示字元。

```bash
sudo launchctl bootout system/local.airplay-stereo
sudo rm -f /Library/LaunchDaemons/local.airplay-stereo.plist
sudo rm -rf "/Library/Application Support/AirPlayStereo"
rm -rf ~/Library/Application\ Support/AirPlayStereo
```

## 回報問題

到 [issue](https://github.com/NightLightTw/dualpod/issues) 開一則新的，附上 Mac 型號、macOS 版本、HomePod 型號與軟體版本、DualPod 版本（下載檔名裡的數字），以及出問題前做了什麼。可以的話也貼上「複製診斷資訊」的內容。它會把 IP、裝置 ID、喇叭名稱換成代號，送出前請自己再看一次。

## 隱私

- DualPod 不收集任何資料。找喇叭用的是同一個網路上的 Bonjour，聲音只送到你勾選的喇叭。
- 唯一的網際網路連線是向 GitHub 查有沒有新版，App 開啟時查一次，之後每天一次。有的話選單會顯示新版本並連到下載頁，不會自動下載或安裝。可以在「設定… → 一般 → 自動檢查更新」關掉。
- 記錄只存在這台 Mac 的 `/Library/Application Support/AirPlayStereo/logs`，每段播放的記錄 7 天後刪除。

## 運作方式

```
system audio ──audiotee (Core Audio process tap)──▶ stereotool split ──L──▶ cliairplay ──AirPlay 2──▶ 喇叭 1
                                                                     ├─R──▶ cliairplay ──AirPlay 2──▶ 喇叭 2
                                                                     └─LR─▶ localplay（這台 Mac）
                        共用一個 PTP 時鐘（cliairplay --ptp-daemon）與同一個起播時刻
```

- `stereo.sh` 是背景服務，以 root 身分執行的 LaunchDaemon。它負責找喇叭、啟動並監看串流，並從 `~/Library/Application Support/AirPlayStereo/` 裡的檔案讀取 App 的設定。
- `run_pair.sh` 啟動一段串流。
- `app/` 是選單列 App（Swift、AppKit 與 SwiftUI），透過 macOS 內建的密碼對話框安裝背景服務。
- `tools/stereotool` 負責對時和拆分左右聲道。`tools/localplay` 讓 Mac 喇叭準時播出它那一份。

在一組測試環境中，左右兩台 HomePod 的時間差測得 0.7 到 3.3 ms。用 Apple Music 把同一段聲音送到兩台，測得 0.5 到 2.2 ms，所以 DualPod 的左右同步程度和 Apple Music 接近。

## 從原始碼編譯

```bash
zsh scripts/fetch-deps.sh      # clone airplay-cli（cliairplay）與 audiotee，套用 patches/ 後編譯
zsh app/build.sh               # 產生自用的 app/DualPod.app
```

需要 Apple 晶片的 Mac，以及 Xcode 或 Command Line Tools。

Release 的 zip 是從乾淨 clone、checkout 到 `vX.Y.Z` tag 後編譯的：

```bash
zsh scripts/fetch-deps.sh && zsh app/build.sh dist   # 產生 dist/DualPod-X.Y.Z.zip
```

工作目錄有未 commit 的修改，或依賴套件和固定的 commit 加上 `patches/` 不一致時，dist 編譯會拒絕執行。

量測工具只供開發使用，給 `run_pair.sh` 的測試與量測模式用。需要裝有 numpy 與 scipy 的 Python，以及 Homebrew 的 ffmpeg。設定方式：

```bash
swiftc tools/rec.swift -o tools/rec
mkdir signals checks && python measure.py gen signals
```

## 授權與致謝

Copyright (C) 2026 NightLightTw。DualPod 是自由軟體，採用 GNU 通用公共授權條款第 3 版（GPLv3），條款見 [LICENSE](LICENSE)。

DualPod 用 Music Assistant 的 [cliairplay (airplay-cli)](https://github.com/music-assistant/airplay-cli) 串流，用 Nick Payne 的 [audiotee](https://github.com/makeusabrew/audiotee) 錄製聲音，兩者都有小幅修改。它們的授權、確切的 commit 與修改內容，見 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

DualPod 是獨立專案，與 Apple Inc. 無關，也未經 Apple 認可或贊助。Apple、AirPlay、HomePod、HomePod mini、Mac 是 Apple Inc. 在美國及其他國家和地區註冊的商標。
