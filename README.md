# ivLyrics for YouTube Music (iOS)

[ivLyrics](https://github.com/ivLis-Studio/ivLyrics)（Spicetify 用の歌詞拡張）を、iOS 版 YouTube Music 向けに移植した dylib です。
UI はスマートフォンで片手操作しやすいように、一から作り直しました。

次の 2 つの tweak も統合しています。設定はすべて ivLyrics の設定画面にまとまっています。

- [LockLyrics](https://github.com/axcyum/LockLyrics)：ロック画面に歌詞を表示
- [YTMusic-iOS-Presence](https://github.com/axcyum/YTMusic-iOS-Presence)：Discord Rich Presence

対応 OS：iOS 18 以降

> この tweak は歌詞を見やすく・使いやすくすることだけを目的にしています。
> 広告ブロック、Premium 機能の解除、ダウンロード、その他アプリの制限を回避する機能は**一切含みません**。
> YouTube Music 内部の構造は [YTMusicUltimate](https://github.com/dayanch96/YTMusicUltimate) を参考にしていますが、利用しているのは再生状態とメタデータを読み取るフックだけです。

## 機能

**全画面歌詞ビュー**
- アートワークをぼかした背景に、同期した歌詞を大きな文字で表示（単色背景にも切り替え可）
- 現在の行を画面上部から約 1/3 の位置に自動スクロール
- 単語単位のカラオケ表示（Unison の TTML、拡張 LRC のときに有効）
- 間奏は「• • •」のアニメーションで表示
- デュエット曲（TTML の agent）では、2 人目のパートを右寄せで表示

**操作（モバイル向け）**
- 行をタップすると、その位置にシークします
- 行を長押しすると、「ここから再生」「この行に同期を合わせる」「コピー」が選べます
- 手動でスクロールすると追従が止まり、「現在の位置に戻る」ボタンが出ます（数秒後に自動で追従に戻ります）
- 歌詞をピンチすると文字サイズを変えられます
- ヘッダーを下にスワイプすると閉じます
- 下部ツールバーは親指で届く位置にまとめています：翻訳 / 発音 / 文字サイズ / 同期 / 設定
- 同期パネルでは、曲ごとに ±0.1 秒 / ±0.5 秒ずつずれを補正できます（値をタップでリセット）
- 歌詞の表示中は画面がスリープしません（設定で変更可）

**再生画面のボタン**
- Now Playing 画面にフローティングボタンを置きます。ドラッグで好きな位置に動かせ、位置は保存されます
- ボタンの中に現在の歌詞 1 行を表示できます（ミニ歌詞）
- タップで歌詞ビュー、長押しで設定を開きます
- アカウントメニューにも「ivLyrics」の設定項目を追加します

**歌詞の取得**
- YouTube Music 公式歌詞（アプリの「歌詞」タブと同じもの。InnerTube のモバイルクライアントから時間同期付きで取得）/ LyricsPlus / Unison / Lyrically（Apple Music カタログ・KuGou）/ LRCLIB に対応
- 日本語・韓国語・中国語の曲でローマ字化された歌詞が返ってきた場合は、優先度を下げます
- 有効なソースは同時に検索し、単語同期 > 行同期 > テキストの順で採用します。同じ種類なら、設定画面でドラッグして決めた順番が上のソースを優先します
- 同期歌詞が見つからないときは、テキスト歌詞を表示します
- 「(Official Video)」「- Topic」「feat.」などのタイトル・アーティスト表記を整えてから検索します
- 手動検索：LRCLIB を検索し、長押しでプレビューしてから選べます。選んだ歌詞はその曲に固定されます
- 取得した歌詞はディスクにキャッシュします

**ロック画面の歌詞**（LockLyrics を統合）
- ロック画面とコントロールセンターのジャケット部分に、再生中の歌詞を描画します
- 歌詞ソース・曲ごとの同期補正・翻訳／発音は、歌詞画面と同じものを使います
- 元の LockLyrics から変えた点：
  - 行の切り替わりをスライド＋フェードのアニメーションにしました（元は一瞬で切り替わっていました）
  - ロック画面の表示遅れを補うため、少し早めに次の行を出します（先読み時間は設定で変更可）
  - 単語同期の曲では、歌っている位置までカラオケ風に色が変わります
  - 歌詞ソースが LRCLIB だけではなく、全ソースになりました

**Spotify の歌詞**
- 設定 → Spotify から open.spotify.com にログインすると、Spotify アプリと同じ歌詞を「Spotify」ソースとして取得します
- 曲の検索は、画面に表示しない Web 版プレーヤーに検索させ、その結果を使います（`api.spotify.com` は Web 版のトークンだと 429 で拒否されるため）
- 歌詞の取得には、Web 版プレーヤー自身が取得したアクセストークンと `client-token` を使います。ログイン情報はこの端末の WebKit にだけ保存されます
- Spotify の非公開 API を使うため、予告なく使えなくなることがあります

**Discord Rich Presence**（YTMusic-iOS-Presence を統合）
- 再生中の曲名・アーティスト・残り時間・ジャケットを Discord のアクティビティに表示します
- 連携・共有の停止／再開・サムネイル・診断ログ・連携解除は、iOS のポップアップではなく設定画面から操作します
- 公式の Discord Social SDK が必要です（下記「ビルド」を参照）。SDK なしでビルドした場合、この機能は「非対応ビルド」と表示されます

**翻訳・発音**
- 翻訳：Google 翻訳の非公式ウェブエンドポイント（ivLyrics の `Addon_AI_GoogleTranslate` と同じもの。API キーは不要）
- 発音表記は**端末上で生成**し、通信はしません
  - 日本語：ローマ字、またはふりがな（漢字の読みをひらがなで表示）
  - 韓国語：ローマ字表記
  - 中国語：声調記号付きのピンイン
  - その他の非ラテン文字（キリル文字、タイ文字など）：ラテン文字への転写
- UI の言語：日本語 / English / 한국어

## ビルド

macOS、[Theos](https://theos.dev)、Xcode（iOS 18 以降の SDK）が必要です。

```sh
make package                         # 既定: ivLyricsYTM.dylib（サイドロード / IPA 注入用）
make package JAILBREAK=1             # 脱獄環境向けの .deb（rootful）
make package JAILBREAK=1 ROOTLESS=1  # 脱獄環境向けの .deb（rootless）

# Discord Rich Presence も有効にする場合（Discord Social SDK の iOS 実機スライスを指定）
make package DISCORD_SDK=/path/to/discord_partner_sdk.xcframework/ios-arm64
```

- Discord SDK はリンクしません。ビルド時にヘッダーから全 API の転送スタブを生成し（`tools/gen_discord_stubs.py`）、起動時に SDK 本体を `dlopen` して割り当てます
- SDK 本体は `discord_partner_sdk.dylib`（フレームワーク内のバイナリと同じもの。CI の成果物に入っています）として、`ivLyricsYTM.dylib` と同じ場所に置けば読み込まれます。フレームワークの注入は不要なので、LiveContainer でも使えます

- 既定のビルドは `library.mk` を使います。Logos の生成方式は `internal`（ObjC ランタイムを直接使う方式）なので、**CydiaSubstrate / ElleKit に依存しない単体の dylib** になります
- 生成物は `.theos/obj/ivLyricsYTM.dylib` に出力されます

### GitHub Actions

`.github/workflows/build.yml` は macOS ランナーで dylib と deb をビルドし、成果物（Artifacts）としてアップロードします。
`workflow_dispatch` で復号済み IPA の URL を渡すと、[cyan](https://github.com/asdfzxcvbn/pyzule-rw) を使って dylib を注入した IPA も作ります。

Discord Social SDK はリポジトリに含められないため、このリポジトリのリリース `build-inputs` に `discord-sdk.zip` として置いています。CI はそれがあれば Discord 付きでビルドし、`discord_partner_sdk.framework` も成果物と IPA に同梱します。

## インストール（サイドロード）

1. 復号済みの YouTube Music IPA を用意します
2. Sideloadly / Feather / ESign / cyan などで `ivLyricsYTM.dylib`（Discord を使う場合は `discord_partner_sdk.dylib` も）を注入します
   （例：`cyan -i YouTubeMusic.ipa -o out.ipa -f ivLyricsYTM.dylib discord_partner_sdk.dylib`）
   - LiveContainer の場合：アプリの Tweak フォルダに `ivLyricsYTM.dylib` と `discord_partner_sdk.dylib` の 2 つを入れるだけです

LockLyrics と YTMusic-iOS-Presence はこの dylib に含まれているので、それらの dylib は一緒に注入しないでください（ロック画面の表示や Discord の送信が二重になります）。
3. 署名してインストールします

YTMusicUltimate と同時に注入しても動作します（フックしているメソッドは同じでも、どちらも `%orig` を呼んでつなぐ作りになっています）。

## 構成

```
Sources/
  Tweak.x                     フック（YTPlayerViewController / YTMNowPlayingViewController / YTMAvatarAccountView）
  YTMHeaders.h                YouTube Music のプライベート API 宣言（YTMusicUltimate の Headers から抜粋）
  IVLPlaybackManager.*        曲変更の検出、再生位置（補間・オフセット込み）、シーク
  IVLLyricsService.*          ソースの並列検索と選択、Unison / LRCLIB、メタデータ整形、キャッシュ、言語判定
  IVLYouTubeProvider.m        YouTube Music 公式歌詞（next → 歌詞 browseId → browse の timedLyricsData）
  IVLExtraProviders.m         LyricsPlus / Lyrically（ivLyrics の各 Addon を移植）
  IVLLyricsParser.*           LRC / 拡張 LRC / TTML / プレーンテキストのパーサー（ivLyrics の実装を移植）
  IVLTranslator.*             翻訳（Google gtx）と端末内の発音生成（CFStringTokenizer / ICU）
  IVLLyricsViewController.*   全画面の歌詞 UI
  IVLLyricCell.*              歌詞の行セルと、カラオケ描画ラベル（TextKit の 2 回描画 + クリップ）
  IVLFloatingButton.*         Now Playing 上のドラッグできるボタン・ミニ歌詞
  IVLSearchViewController.*   手動検索
  IVLSettingsViewController.* 設定（ロック画面 / Spotify / Discord のページを含む）・翻訳先の言語選択
  IVLLockScreen.*             ロック画面の歌詞（LockLyrics を統合）
  IVLSpotify.*                Spotify ログインと Spotify の歌詞
  IVLDiscord.* / IVLDiscordLog.* Discord Rich Presence（YTMusic-iOS-Presence を統合）
  IVLSettings.* / IVLLocalization.* / IVLModels.*
```

YouTube Music 側で使っているもの（YTMusicUltimate と同じフックポイント）：

- `-[YTPlayerViewController playbackController:didActivateVideo:withPlaybackData:]`：曲の変更
- `-[YTPlayerViewController singleVideo:currentVideoTimeDidChange:]`：曲変更の取りこぼし検出
- `currentVideoMediaTime` / `seekToTime:` / `playerResponse.playerData.videoDetails`：再生位置・シーク・曲名・アーティスト・アートワーク
- `-[YTMNowPlayingViewController viewDidLoad]`：ボタンの設置
- `-[YTMAvatarAccountView setAccountMenuUpperButtons:lowerButtons:]`：設定への入口
- `-[MPNowPlayingInfoCenter setNowPlayingInfo:]`（公開 API）：曲情報の取得、ロック画面の歌詞、Discord

アプリの更新でクラス名やメソッド名が変わったときに落ちないよう、呼び出しはすべて `respondsToSelector:` で確認し、クラスが存在するときだけ `%init` します。

## 移植していない機能

Spicetify 版にある次の機能は、モバイルでは使い勝手が悪いか、Spotify に依存しているため移植していません。

- API キーが必要な AI 翻訳・AI 発音（ChatGPT / Claude / Gemini など）。発音は端末内の生成で置き換えています
- 動画背景、コミュニティ同期オフセットの共有、マーケットプレイス、学習モード、同期データ作成ツール、Vinyl モード

## 注意

- 開発は Windows 上で行ったため、**実機でのビルド・動作確認はまだしていません**。最初は GitHub Actions でビルドし、実機で確認してください
- YouTube Music の内部 API は非公開で、アップデートで変わることがあります
- 歌詞・翻訳の著作権はそれぞれの権利者に帰属します。利用は各サービスの規約に従ってください
- Google 翻訳のエンドポイントは非公式のもので、予告なく使えなくなることがあります

## ライセンス

GPL-3.0。[LICENSE](LICENSE) を参照してください。

YTMusic-iOS-Presence（GPL-3.0）のコードを含むため、全体を GPL-3.0 で配布します。ivLyrics 由来の部分は LGPL-2.1 で、LGPL-2.1 第 3 条に基づいて GPL として扱っています（元のライセンス文は [LICENSE.ivLyrics-LGPL-2.1](LICENSE.ivLyrics-LGPL-2.1)）。
Discord Social SDK は Discord のライセンスに従い、このリポジトリには含めていません。

ivLyrics © ivLis STUDIO。LyricsPlus、Unison、Lyrically (Paxsenix)、LRCLIB、YTMusicUltimate の各作者に感謝します。
