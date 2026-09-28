# JBoss EAP server.log が日付変更後も前日付ファイルに追記される問題 — current リンクとログローテーションの動作原理・実機検証・対処

> **この文書は pin 方式のものです（2026-09-29 追記）:** GitHub `ProjectRubyRing/ECS_EFS_Dockerfile_Symboliclink_lite` では、この一式は `pin_method/` フォルダにあります。同リポジトリのルートにある同じ名前の文書は、**別の方式（コンテナ専用リンク方式）**の説明です。2 つの違いと、混ぜてはいけない組み合わせは [`../README.md`](../README.md) を参照してください。

| 項目 | 内容 |
|---|---|
| 対象リポジトリ | ProjectRubyRing/ECS_EFS_Dockerfile_Symboliclink_lite（ECS + EFS + readonlyRootFilesystem=true、2 段シンボリックリンク方式） |
| 前提構成 | /opt/jboss-eap/standalone/log → /mnt/logs/\<Component_name\>/logs/\<Service_Name\>/mid/current → mid/\<LOG_ID\>（起動ごとに current を張り替え） |
| 報告された症状 | 日付をまたぐタイミングのローリングデプロイ（minimumHealthyPercent=100 / maximumPercent=200）後、日付が変わっても server.log ではなく前日付のファイル（例: server.log.2026-09-16）にログが追記され続ける |
| 結論（一文） | 全タスクで共有される可変リンク current を、JBoss の日次ローテーション（パス名で rename → パス名で再 open）が辿り直すため、旧タスクが新タスクの現役 server.log を前日付へ改名してしまう。JBoss の書き込み先を実体パスへ固定して解消した |
| 検証環境 | Docker（--read-only ＋ 空の書き込み可能ボリューム ＋ 共有ボリューム＝EFS 役）で ECS と同条件を再現。WildFly 26.1.3.Final（JBoss EAP 7.4 相当、jboss-logmanager 2.1.18、JDK 11）と WildFly 41.0.1.Final（JBoss EAP 8.x 相当、jboss-logmanager 2.1.19、JDK 25） |
| 作成日 | 2026-09-27（ECS の最新仕様は 2026-09 時点の AWS 公式情報で確認） |
| フォント・配色 | Meiryo UI、モノトーン（黒・グレー・白） |

## 目次

- [1. 結論（まずここだけ読めば分かる）](#1-結論まずここだけ読めば分かる) — みんなで 1 枚だけ共有している『案内板（current）』を、夜中の片付け係が道しるべに使うせいで、よその子のノートに昨日の日付シールを貼ってしまう事故です。自分の机の住所を直接教えれば起きません。
- [2. 小学生にもわかる説明（教室のたとえ話）](#2-小学生にもわかる説明教室のたとえ話) — 開いたノートは手に持っているから大丈夫。でも夜中の片付けだけは案内板を見てノートを探す。案内板はみんなで 1 枚。だから間違える。
- [3. 登場の歴史と背景（なぜこの仕組みがあり、なぜぶつかったのか）](#3-登場の歴史と背景なぜこの仕組みがありなぜぶつかったのか) — 『名前と中身を分ける』『道順だけ書いた案内板』『日付でノートを替える』はどれも昔からある便利な工夫。コンテナ時代に『案内板を全員で共有する』使い方をしたことで、初めてぶつかりました。
- [4. 動作原理（仕組みを深掘り）](#4-動作原理仕組みを深掘り) — パスは『開く瞬間』にだけ辿られ、開いた後は中身を直接つかむ。ところが日付の切り替えでは、もう一度パスを辿り直す。その瞬間の current が他人を指していると事故になる。
- [5. ご質問への回答（4 つ）](#5-ご質問への回答4-つ) — 旧タスクは『道順』で片付けて他人のノートを改名し、新タスクは『手に持ったノート』に書き続ける。再起動のしかたで、同じ机に戻るかどうかが変わります。
- [6. 動作イメージ（時系列とディレクトリの状態）](#6-動作イメージ時系列とディレクトリの状態) — 時計の順に『current がどこを指しているか』『だれがどのファイルに書いているか』を並べると、事故の瞬間がはっきり見えます。
- [7. 実機検証（修正前のリポジトリそのまま と 修正後）](#7-実機検証修正前のリポジトリそのまま-と-修正後) — 本物の WildFly（JBoss EAP の元になっているサーバ）を ECS と同じ条件で動かし、0 時をまたがせて、どのファイルに何が書かれたかを確かめました。
- [8. 対処法（方式の比較と採用案）](#8-対処法方式の比較と採用案) — 一番よいのは『自分の机の住所を直接教える』こと。デプロイの時間をずらすのは、事故の回数を減らすだけで、なくすことはできません。
- [9. ローリングデプロイ・ECS の設定（補助策と注意点）](#9-ローリングデプロイecs-の設定補助策と注意点) — 並走する時間を短くし、0 時にかからないようにすると事故は減ります。ただし ECS は日中でも勝手にタスクを入れ替えるので、設定だけでは 0 にできません。
- [10. 実装内容（リポジトリの変更点）](#10-実装内容リポジトリの変更点) — エントリポイントが JBoss に『あなたの机はここ』と実体の住所を渡すようにし、古いタスク ID 方式も同じ仕組みに入れました。
- [11. 確認手順・移行手順・運用](#11-確認手順移行手順運用) — 直ったかどうかは『JBoss がどのファイルを手に持っているか』を見れば一目で分かります。
- [12. 用語集](#12-用語集) — むずかしい言葉を、ひとことで言い換えます。
- [13. 参考資料（一次情報）](#13-参考資料一次情報) — 調べるときに見た、元の資料の一覧です。

---

## 1. 結論（まずここだけ読めば分かる）

> **やさしく言うと:** みんなで 1 枚だけ共有している『案内板（current）』を、夜中の片付け係が道しるべに使うせいで、よその子のノートに昨日の日付シールを貼ってしまう事故です。自分の机の住所を直接教えれば起きません。

| 項目 | 内容 |
|---|---|
| **何が起きているか** | 旧タスクの JBoss は 0 時（JVM のタイムゾーン）以降に最初のログを書く瞬間に日次ローテーションを行う。その手順は「自分のファイルを閉じる → /opt/jboss-eap/standalone/log/server.log というパス名を server.log.\<前日\> へ rename → 同じパス名で開き直す」。このパスは current を経由するため、rename と再 open はその瞬間の current が指す新タスクのディレクトリで行われる。結果、新タスクが書き込み中の server.log が server.log.\<前日\> に改名される。 |
| **なぜ新タスクは前日付ファイルに書き続けるのか** | Linux / NFS(EFS) では、開いているファイル（fd）は名前ではなく中身（inode・NFS ファイルハンドル）に結び付く。rename は名前の付け替えにすぎないので、新タスクは気付かずに同じ中身（＝いまの名前は server.log.\<前日\>）へ追記し続ける。新タスク自身のローテーションは自分の起動日の翌 0 時まで来ないため、0 時後に起動した新タスクは丸 1 日、前日付ファイルに書き続ける。 |
| **旧タスクの server.log はどうなるか** | 旧タスク自身のディレクトリの server.log は一度も改名されず「server.log」のまま残る（中身は前日まで）。旧タスクの 0 時以降のログ（停止ログなど）は、新タスクのディレクトリに新しく作った server.log に書かれる（混入）。 |
| **最悪のケース** | 2 つ以上の JBoss が同じディレクトリで 0 時処理を行うと、2 回目の rename が REPLACE_EXISTING（上書き）で 1 回目の server.log.\<前日\> を置き換え、あるタスクの前日分のログが丸ごと消える（実機で確認）。 |
| **起きる条件** | 「自分より後に別タスクが起動した（＝current が自分を指していない）JBoss」が、JVM タイムゾーンの 0 時を越えて生きていて、0 時以降に 1 行でもログを出したとき。0 時をまたぐローリングデプロイだけでなく、日中・夕方に起動したタスクが 2 つ以上並走したまま 0 時を迎えると毎晩起きる（デプロイ、オートスケール、AZ リバランス、Fargate 退役、ヘルスチェック入替、失敗デプロイの再試行など）。 |
| **根本対策（実装済み）** | エントリポイントが JBoss に「自分専用の実体ディレクトリ mid/\<LOG_ID\>」を直接渡す（-Djboss.server.log.dir、JBOSS_LOG_DIR、logging.properties の fileName）。current は「最後に起動したタスク」を示す目印としてだけ残し、書き込み経路から外した。旧実装（ECS タスク ID 方式）も同じ本体に統合し LOG_ID_SOURCE=taskid で選べるようにした（設定復元・fail-fast・固定が必ず効く）。 |
| **デプロイ設定での対策** | 0 時帯のデプロイ回避、並走時間の短縮（登録解除遅延・stopTimeout）、サーキットブレーカー、Early Success Criteria の DEFERRED を使わない、TZ の明示など。発生確率は下がるが根絶できない補助策（並走は ECS の通常動作で日常的に起きるため）。 |
| **修正の効果（実機）** | 同じ 0 時シナリオで、各タスクが自分のディレクトリ内だけで server.log → server.log.\<前日\> を正しく作り、他タスクのファイルに一切触れないことを確認した。 |

> **移行時の注意:** 修正前のイメージで動いているタスクは、修正後もしばらく current 経由で rename します。切り替えのデプロイは日中に行い、0 時（JVM のタイムゾーン）までに修正前のタスクがすべて停止したことを確認してください。

> **gc.log と access_log.log（2026-09-28 追記・2026-09-29 更新）:** どちらも「閉じる → パス名で rename → パス名で開き直す」でローテーションするため、server.log と同じ事故が起きます。本番の現状（pin なし）では access_log.log に同じ症状が出ます。gc.log も、本番の JAVA_OPTS には -Xlog／-Xloggc の明示がある（2026-09-29 確認）ので、出力先が standalone/log（リンク）の下なら容量ローテーションのたびに起き得ます（明示が無ければ、standalone.sh が JAVA_OPTS の -Djboss.server.log.dir を実体に解決するので偶然起きない）。既定の書き方なら pin で直り、pin を素通りする明示の書き方（JAVA_OPTS の -Xlog、standalone.xml の access-log の directory）はエントリポイントが実体パスへ揃えます。本番の access-log は directory の指定が無い（既定）ので pin だけで直り、本番の gc.log はこの揃える処理で直ります。詳細は 10-2。

---

## 2. 小学生にもわかる説明（教室のたとえ話）

> **やさしく言うと:** 開いたノートは手に持っているから大丈夫。でも夜中の片付けだけは案内板を見てノートを探す。案内板はみんなで 1 枚。だから間違える。

### 登場人物（たとえ → 本物）

| たとえ | 本物 | ひとこと |
|---|---|---|
| **教室** | EFS（みんなで使う共有ディスク） | 全タスクが同じ教室を使う |
| **机** | mid/\<起動時刻-ランダム8桁\> などのディレクトリ | タスク（JBoss）ごとに 1 つ |
| **ノート** | ファイルの中身（inode） | 本当に字が書かれている物 |
| **ノートの名札「server.log」** | ファイル名（パス） | 名札は貼り替えられる |
| **手に持っているノート** | 開いているファイル（fd = ファイルディスクリプタ） | 一度手に取れば、名札が変わっても同じノート |
| **入口の案内板「いまの当番はこの机」** | current シンボリックリンク | 教室に 1 枚だけ。最後に来た子が書き換える |
| **生徒 A・生徒 B** | 旧タスク・新タスクの JBoss | B の方が後から来た |
| **夜 0 時の片付け当番** | 日次ローテーション | いまのノートを片付けて新しいノートを出す |
| **昨日の日付シール** | server.log.2026-09-16 のような名前 | 片付けたノートに貼る |

### お話

1. 朝、生徒 A が教室に来ます。案内板は「A の机」を指しています。A は案内板を見て自分の机に行き、「server.log」という名札のノートを手に取って日記を書き始めます。いちど手に取ったノートは、ずっと手に持ったまま書きます。
2. 夜 0 時ごろ、新しい生徒 B が来ました。B は来るとすぐ案内板を「B の机」に書き換えます。B も自分の机の「server.log」ノートを手に取って書き始めます。A は自分のノートを手に持っているので、案内板が変わっても困りません。ここまでは平和です。
3. 0 時を過ぎました。A には「日付が変わったら、いまのノートに昨日の日付シールを貼って片付け、新しい server.log ノートを出す」というお仕事があります。ところが A はこのお仕事のときだけ、手に持ったノートではなく『入口の案内板が指す机の上の、server.log という名札のノート』を探して片付けます。A の頭の中にあるのは「案内板 → 机 → server.log」という道順だけだからです。
4. 案内板はもう B の机を指しています。だから A は、B がまさに書いている最中のノートに「9月16日」のシールを貼ってしまいます。そして B の机に新しい「server.log」ノートを置き、自分の日記をそこに書き始めます。
5. B はノートを手に持ったままなので、シールを貼られたことに気付きません。9月17日になっても「9月16日」のシールが貼られたノートに書き続けます。これが今回の症状です。
6. A の机の A のノートは、片付けられないまま「server.log」の名札で置きっぱなしです。
7. もっと困るのは B も片付けをするときです。B も案内板を見て、B の机の「server.log」（A が置いたノート）に「9月16日」のシールを貼ります。同じシールのノートが 2 冊になるので、先にあった方（B の本当の昨日の日記）は捨てられてしまいます。1 日分の日記が消えます。
8. どうすればいい？ 生徒ひとりひとりに「あなたの机はここ」と住所を直接教え、片付けのときも案内板を見ないで自分の机で片付けてもらえばいいのです。案内板は「最後に来た子の机」を知りたい人のための目印として残します。これが今回の修正です。

> **3 つのポイント:** 事故が起きるのは、次の 3 つが重なったときだけです。①手に持ったノート（fd）は中身そのものを持っている　②案内板（current）は道順にすぎず、みんなで 1 枚を共有している　③片付けのときだけ道順でノートを探し直す。修正では③の道順から案内板を外しました。

---

## 3. 登場の歴史と背景（なぜこの仕組みがあり、なぜぶつかったのか）

> **やさしく言うと:** 『名前と中身を分ける』『道順だけ書いた案内板』『日付でノートを替える』はどれも昔からある便利な工夫。コンテナ時代に『案内板を全員で共有する』使い方をしたことで、初めてぶつかりました。

| 年 | 出来事 | 本件との関係 |
|---|---|---|
| **1970年代** | UNIX のファイルシステムが「名前（ディレクトリエントリ）」と「中身（inode）」を分けて管理。open したファイルは fd で中身を指す | 書き込み中のファイルでも rename で名前を付け替えられる。ログローテーションはこの性質を利用して生まれた |
| **1983** | 4.2BSD でシンボリックリンクが登場 | リンクは「道順」を書いた小さなファイル。辿るのは“使う瞬間”（open / rename のたび） |
| **1984〜1989** | Sun が NFS を開発（NFSv2 の RFC 1094 は 1989） | NFS はファイルをパスではなく「ファイルハンドル」で識別。EFS も NFSv4.x で同じ考え方。別クライアントが rename しても開いている側は書き続けられる |
| **1980〜1990年代** | syslog・newsyslog、1990年代半ばに logrotate | 外部ツールが rename してからプロセスに再 open させる方式が定着 |
| **2001〜2002** | log4j（DailyRollingFileAppender）、JDK 1.4 の java.util.logging | アプリ自身が日付でファイルを切り替える「プロセス内ローテーション」が一般化 |
| **2006ごろ** | Capistrano などの `current -\> releases/\<日時\>` デプロイ | 「current リンク＝いまの版」という慣習。1 台・1 プロセスで使う前提 |
| **2009-07** | jboss-logmanager に PeriodicRotatingFileHandler が追加（最初のコミット 2009-07-03） | 本件のクラス。「閉じる → パスで rename → パスで開き直す」。1 プロセス＝1 ファイル（＝1 パス）が前提 |
| **2011** | JBoss AS 7 リリース／The Twelve-Factor App 公開 | AS 7 で logging サブシステムと logging.properties 方式、server.log の日次ローテーション（suffix .yyyy-MM-dd）が既定に。12-Factor は「ログは標準出力のイベントストリームに」と提唱 |
| **2013〜2017** | Docker（2013）、Amazon ECS（2014 発表・2015 GA）、Amazon EFS（2016 GA）、AWS Fargate（2017） | コンテナは使い捨てになり、複数タスクが同じ共有ストレージを使う構成が一般化 |
| **2016〜2025** | JBoss EAP 7.0（2016）、7.4（2021-07）、8.0（2024-02）、8.1（2025） | いずれも server.log は periodic-rotating-file-handler（suffix .yyyy-MM-dd）が既定。ローテーション手順は 2009 年から本質的に不変（2.1.18／2.1.19／3.x のソースで確認） |
| **2020-04** | Fargate プラットフォーム 1.4.0 で EFS 対応、タスクメタデータエンドポイント v4 | Fargate からの EFS 共有と「タスク ID の取得」が可能に（本リポジトリの前提） |
| **2020-12** | ECS デプロイサーキットブレーカー GA | 失敗デプロイを自動でロールバック（旧タスクが長時間残るのを防ぐ） |
| **2024-08** | ECS コンテナ再起動ポリシー（restartPolicy） | タスクを入れ替えずにコンテナだけ再起動（同じタスク ID のまま） |
| **2024-11／2025-09** | ECS AZ リバランス発表／2025-09-05 から対象サービスで有効化 | 日中でも自動でタスクが入れ替わる → current が張り替わる |
| **2025-07／2025-10** | ECS ネイティブ Blue/Green（bake time）／Linear・Canary | 新旧が長めに並走する戦略が標準機能に |
| **2025-12** | Fargate タスク退役のイベントウィンドウ | 退役（入れ替え）の時間帯を指定可能に |
| **2026-07** | サーキットブレーカーの閾値・カウント方式が設定可能に | 失敗判定を早められる |
| **2026-09-04** | ECS Early Success Criteria（sourceServiceRevisionCleanup=BLOCKING／DEFERRED） | DEFERRED では旧リビジョンのタスクがデプロイ完了後も最大 2 週間残り得る → 修正前の実装だと 0 時のたびに確実に発生する |

### このリポジトリで「current」が必要になった経緯

- readonlyRootFilesystem=true では、起動後にルートファイルシステムへ書けない。/opt/jboss-eap/standalone/log のシンボリックリンクはイメージのビルド時にしか作れない。
- 一方「タスクごとに別のディレクトリ」は起動するまで決まらない（タスク ID も起動時刻も起動時に決まる）。
- そこで「ビルド時は固定の入口 mid/current へ向け、起動時に EFS 上の current を張り替える」2 段リンクを採用した（DESIGN.md 3 章）。
- これは『1 本の current を全タスクで共有する』ことを意味する。JBoss のローテーションは 2009 年の設計どおり『1 プロセス＝1 ファイル（パス）』を前提にしており、共有された可変リンクがパスの途中に入ることを想定していない。この前提の食い違いが不具合の正体。
- 従来の設計メモ（DESIGN.md 6 章 1）は「先行タスクがローテーションで新規作成するファイルは後発タスク側へ入り得る（open 済みハンドルは影響なし）。desiredCount=1 なら実害はほぼ無い」と評価していた。実際には rename の段階で後発タスクの現役ファイルを改名し、上書きで前日分を消すという、より深刻な影響があった（本書 7 章で実機確認）。

---

## 4. 動作原理（仕組みを深掘り）

> **やさしく言うと:** パスは『開く瞬間』にだけ辿られ、開いた後は中身を直接つかむ。ところが日付の切り替えでは、もう一度パスを辿り直す。その瞬間の current が他人を指していると事故になる。

### 4-1. パスは「開く瞬間」に 1 回だけ辿られる

JBoss は server.log を /opt/jboss-eap/standalone/log/server.log というパスで開く。カーネルはパスを左から順に辿り、log（リンク）→ /mnt/logs/…/mid/current（リンク）→ \<LOG_ID\>（実体ディレクトリ）→ server.log に到達する。open() が返す fd はこの時点の中身（inode、EFS では NFS ファイルハンドル）を指し、以後 current が張り替わっても fd の行き先は変わらない。

| 段 | パス | 種類 | 辿った先 |
|---|---|---|---|
| **1** | /opt/jboss-eap/standalone/log | シンボリックリンク（ルート FS、ビルド時に作成・読み取り専用） | /mnt/logs/\<C\>/logs/\<S\>/mid/current |
| **2** | /mnt/logs/\<C\>/logs/\<S\>/mid/current | シンボリックリンク（EFS、全タスク共有・起動のたびに張り替え） | \<LOG_ID\>（相対リンク） |
| **3** | /mnt/logs/\<C\>/logs/\<S\>/mid/\<LOG_ID\> | 実体ディレクトリ（EFS、タスクごと） | server.log |
| **4** | .../mid/\<LOG_ID\>/server.log | ファイル（inode） | fd はここに結び付く（名前ではない） |

```
open("/opt/jboss-eap/standalone/log/server.log")      ← JBoss が知っているのは、この「道順」だけ
        │
        ├─ log      → /mnt/logs/<C>/logs/<S>/mid/current     (ルートFS・ビルド時に固定)
        ├─ current  → <LOG_ID>                               (EFS・全タスク共有・最後に起動したタスクが書き換える)
        └─ <LOG_ID>/server.log                               (実体。open の瞬間に決まる)
                 ↑
                fd  … 以後はこの「中身」を直接つかんで書く。current が変わっても行き先は変わらない
```

### 4-2. JBoss（jboss-logmanager）の日次ローテーションの手順

server.log を書いているのは jboss-logmanager の PeriodicRotatingFileHandler（EAP 7.4 相当の 2.1.18、EAP 8.x 相当の 2.1.19、最新の 3.x で手順は同一）。ローテーションはタイマーではなく「0 時以降に最初のログが来た瞬間」に、そのログを書く直前に行われる。

| 手順 | 処理 | ソース上の場所 | パスを辿るか |
|---|---|---|---|
| **1（起動時）** | new FileOutputStream(パス, append=true) でファイルを開く（無ければ作る） | FileHandler.setFile | 辿る（この瞬間の current） |
| **2（起動時）** | suffix（.yyyy-MM-dd）から周期＝日を決め、既存ファイルの最終更新時刻（無ければ現在時刻）から nextSuffix（例 .2026-09-16）と nextRollover（翌 0 時）を計算 | setSuffix → calcNextRollover | 最終更新時刻の取得で辿る |
| **3（毎レコード）** | レコード時刻 ≥ nextRollover ならローテーションしてから書く | preWrite | ― |
| **4（ローテーション①）** | 自分の fd を閉じる（setFileInternal(null)） | rollOver | 辿らない（自分の中身） |
| **5（ローテーション②）** | Files.move(パス, パス+nextSuffix, REPLACE_EXISTING)：同名があれば上書き | SuffixRotator.move | 辿る（★この瞬間の current） |
| **6（ローテーション③）** | 同じパスで開き直す（新規作成） | rollOver → setFileInternal(file) | 辿る（★この瞬間の current） |
| **7** | レコード時刻から次の nextSuffix／nextRollover を再計算 | calcNextRollover | ― |

**jboss-logmanager の rollOver（2.1.18〜main で同一。コメントは原文）**

```java
private void rollOver() {
    final File file = getFile();                  // 起動時に渡された「パス」 /opt/jboss-eap/standalone/log/server.log
    // first, close the original file (some OSes won't let you move/rename a file that is open)
    setFileInternal(null);                        // ① 自分の fd を閉じる
    // next, rotate it
    suffixRotator.rotate(..., file.toPath(), nextSuffix);   // ② Files.move(path, path + ".2026-09-16", REPLACE_EXISTING)
    // start new file
    setFileInternal(file);                        // ③ 同じ「パス」で開き直す
}
```

### 4-3. 「0 時」は JVM のタイムゾーンの 0 時

- ハンドラ作成時の TimeZone.getDefault()（-Duser.timezone、TZ 環境変数、OS 設定の順で決まる）で 0 時が決まる。ファイル名の日付も同じタイムゾーン。
- コンテナは既定で UTC のことが多い。その場合ローテーションは日本時間 9:00 に起き、日付も UTC になる。日本時間の 0 時で区切りたいなら TZ=Asia/Tokyo（または -Duser.timezone=Asia/Tokyo）を明示する。
- ローテーションはタイマーではなく、0 時以降に最初のログが出た瞬間に起きる。夜中にログが無ければ朝の最初のログで起きる。実機の再現（S1）では、旧タスクの「停止ログ」が引き金になった。

### 4-4. standalone.sh とログディレクトリ

- 既定では JBOSS_LOG_DIR=$JBOSS_BASE_DIR/log（＝/opt/jboss-eap/standalone/log。リンクのまま）とし、-Dorg.jboss.boot.log.file=$JBOSS_LOG_DIR/server.log を JVM に渡す。
- -Djboss.server.log.dir=\<dir\> を引数か JAVA_OPTS で渡すと、standalone.sh は JBOSS_LOG_DIR=$(readlink -m \<dir\>)（リンクを解決した実体パス）にする（ブートログと gc.log の出力先）。一方、JBoss 本体の jboss.server.log.dir（FILE ハンドラの relative-to）には、渡した \<dir\> が**リンクを解決しないまま**入る（ServerEnvironment は new File(値) をそのまま使う）。\<dir\> が current を経由するパスなら、実体パスへの固定にはならない。【2026-09-27 訂正。旧版は「JBoss 本体もこの値（解決後）になる」と書いていた。10-1 参照】
- JAVA_OPTS と起動引数の両方にあるときは、standalone.sh は「JAVA_OPTS → 起動引数」の順に読んで最後の値を JBOSS_LOG_DIR にし、JBoss 本体（org.jboss.as.server.Main）も起動引数の -D でシステムプロパティを上書きする。つまり**起動引数の値が勝つ**（WildFly Core 15.0.1〔EAP 7.4 系〕・18.1.2〔WildFly 26〕・main の standalone.sh と Main.java で確認）。
- JBOSS_LOG_DIR が環境変数で設定済みならそれを使う（未設定のときだけ既定値）。GC_LOG=true のときの gc.log も $JBOSS_LOG_DIR（JBoss EAP は standalone.conf の既定で GC_LOG=true。JAVA_OPTS に -Xlog:gc／-Xloggc があれば standalone.sh は自分の指定を足さない。10-2）。
- JVM が exit code 10（:shutdown(restart=true)）で終わると、standalone.sh は同じ変数のまま java を起動し直す（エントリポイントは再実行されない）。
- LAUNCH_JBOSS_IN_BACKGROUND=true のときだけ standalone.sh は SIGTERM を JVM に中継する（未設定だと PID 1 の sh が SIGTERM を受け取っても JVM に届かず、stopTimeout 後に SIGKILL になる）。

### 4-5. logging.properties の役割と「起動後に絶対パスへ書き換わる」性質

- JBoss は -Dlogging.configuration=file:…/logging.properties で、logging サブシステムが動き出す前のロギングを構成する。配布物の既定は handler.FILE.fileName=${org.jboss.boot.log.file:server.log}。
- 起動後、logging サブシステムは解決済みの絶対パスで logging.properties を書き直す（実機: handler.FILE.fileName=/opt/jboss-eap/standalone/log/server.log）。configuration を永続化していると、次回起動の最初の数行はこの（current 経由の）パスに書かれる。
- 本リポジトリは毎起動 seed から復元（CONFIG_SEED_MODE=overwrite）するので既定では影響しないが、修正版は current 経由・前回 LOG_ID のパスを今回の実体パスへ揃える処理も入れた。

### 4-6. EFS（NFSv4.1）上での意味

- rename は、別クライアント（別タスク）が開いているファイルのファイルハンドルを無効にしない → 改名された側は気付かずに書き続ける（今回の症状）。
- 上書き rename（REPLACE_EXISTING）で名前を失ったファイルは、誰も開いていなければ消える（前日分の消失）。開いている別クライアントがいる場合の扱いはサーバ実装に依存する（ESTALE など）。
- 複数のクライアントが同じファイルに O_APPEND で追記すると、NFS では追記が原子的でなく内容が壊れ得る（Linux の open(2) の注意書き）。修正前の実装で 2 つの JVM が同じ server.log に書く状態（0 時処理後や JVM 再起動後）は、この危険も抱える。
- EFS は close-to-open 整合性。current の張り替えは、他タスクからも属性キャッシュの有効期間（数秒〜数十秒）内に見えるようになる。0 時の時点では確実に見えている。

### 4-7. current の張り替え自体は原子的（問題は“張り替えた後”）

GNU coreutils の ln -sfn は「一時名でリンクを作成 → rename で current に置き換え」を行う（strace で確認: symlinkat("B", "CuQA6vbk") → renameat("CuQA6vbk", "current")）。current が一瞬消えて open が失敗することはない。問題は張り替えの瞬間ではなく、張り替えた後に他のタスクがパスで rename／再 open することにある。

---

## 5. ご質問への回答（4 つ）

> **やさしく言うと:** 旧タスクは『道順』で片付けて他人のノートを改名し、新タスクは『手に持ったノート』に書き続ける。再起動のしかたで、同じ机に戻るかどうかが変わります。

### Q1. 旧タスクの server.log は、どのようにログローテーションを行うのか

- 旧タスクの JBoss は、起動時に開いた自分の server.log（fd）に書き続けている。0 時（JVM のタイムゾーン）以降に最初のログを書こうとした瞬間にローテーションが始まる。
- ローテーションの 3 手順と、それぞれで実際に起きること:
  - ① 自分の fd（旧タスクのディレクトリの server.log）を閉じる。
  - ② パス /opt/jboss-eap/standalone/log/server.log を …/server.log.\<前日\> へ rename する。パスはその瞬間の current で解決されるので、改名されるのは current が指す新タスクの server.log（新タスクが書き込み中の現役ファイル）。
  - ③ 同じパスで開き直すので、新タスクのディレクトリに server.log が新規作成され、旧タスクの以後のログ（停止ログなど）はそこに書かれる。
- 結果: 旧タスク自身のディレクトリの server.log は一度も改名されず「server.log」のまま残る（中身は前日まで）。旧タスクの 0 時以降のログは新タスクのディレクトリに混入する。
- 改名後の日付は旧タスクの nextSuffix（旧タスクが起動した日、または前回ローテーションした日）。例: 旧タスクが 9/16 に起動していれば server.log.2026-09-16。
- 旧タスクが 0 時以降に 1 行もログを書かずに止まった（SIGKILL など）場合、ローテーションは起きない。

### Q2. 新タスクの server.log は、どのようにファイルが作成されて fd を取得するのか

- エントリポイント: mid/\<LOG_ID\> を mkdir（原子的）→ ln -sfn \<LOG_ID\> current（原子的に置き換え）→ exec standalone.sh。
- standalone.sh: -Dorg.jboss.boot.log.file=/opt/jboss-eap/standalone/log/server.log と -Dlogging.configuration=…/logging.properties を付けて java を起動。
- LogManager の初期化で logging.properties から PeriodicRotatingFileHandler(fileName, append=true) を作る → FileOutputStream が open(O_WRONLY|O_CREAT|O_APPEND) → カーネルが log → current → \<LOG_ID\> を辿って server.log を新規作成し fd を返す（fd は inode に結び付く）。
- setSuffix: ファイルの最終更新時刻（いま作ったので“いま”）から nextRollover＝次の 0 時。起動直後にローテーションは起きない。
- logging サブシステム起動後は standalone.xml の FILE ハンドラ（relative-to=jboss.server.log.dir、path=server.log）に引き継がれる。起動の途中で開き直されたとしても、その時点の current は自分を指しているので結果は同じ（実機でも、起動ログと起動後のログが同じファイルに入ることを確認）。
- 以後、他タスクが current を張り替えても fd は自分のファイルを指し続ける。ただし旧タスクがパスで rename すると「名前だけ」前日付になり、新タスクは気付かずに書き続ける（症状）。新タスク自身のローテーションは自分の nextRollover（起動日の翌 0 時）以降の最初のログ時なので、0 時後に起動した新タスクは翌日の 0 時まで前日付ファイルに書き続ける。

### Q3. JBoss EAP の起動時に再起動となった場合、server.log はどのようなローテーション動作をするのか

| 再起動の種類 | 何が起きるか | 修正前の server.log | 修正後の server.log | 根拠 |
|---|---|---|---|---|
| **ECS がタスクを入れ替える（ヘルスチェック失敗・デプロイ・スケール・AZ リバランス・Fargate 退役）** | 新しいコンテナで、エントリポイントから実行し直す。新しい LOG_ID（タスク ID 方式でも新しいタスク ID） | 新しいディレクトリに server.log を新規作成。起動直後のローテーションは無い。ただし current が張り替わるので、生き残っている他タスクの次の 0 時処理がこのディレクトリを荒らす。クラッシュループすると空に近いディレクトリが増え、current も張り替わり続ける | 新しいディレクトリに server.log を新規作成。他タスクの 0 時処理は各自のディレクトリ内で完結し、このディレクトリには触れない | 実機（S1・S2・S2r、修正前／修正後） |
| **同一タスク内のコンテナ再起動（ECS restartPolicy）** | エントリポイントから実行し直す（タスク ID は同じ） | random 方式: 新しい LOG_ID → 新規 server.log（前回のディレクトリの server.log は改名されずに残る）。taskid 方式: 同じディレクトリ → 既存 server.log を追記で開く → 最終更新が前回の 0 時境界より前なら、起動直後の最初のログで server.log.\<最終更新日\> に改名して新しい server.log を始める | 同左（どちらの方式でも、必ず自分のディレクトリ内で行われる） | ソース解析（setSuffix が既存ファイルの最終更新時刻から nextRollover を計算）とエントリポイントの分岐試験。0 時をまたぐ実機試験は未実施 |
| **JVM だけの再起動（:shutdown(restart=true) → exit code 10 → standalone.sh のループ）** | エントリポイントは再実行されない（current も張り替えない）。新しい JVM がログファイルを開き直す | 新しい JVM はその瞬間の current でパスを解決する → 後から別タスクが起動していれば、別タスクの server.log に追記してしまう（2 つの JVM が同じファイルに書く）。自分のディレクトリには戻れない | JBOSS_LOG_DIR と -Djboss.server.log.dir は standalone.sh の中で固定済みなので、自分のディレクトリの server.log を開く。同日なら追記、最終更新が前日以前なら起動直後に日付付きへ改名 | ソース解析（standalone.sh の再起動ループは変数を引き継ぐ）。実機試験は未実施 |
| **管理操作の :reload（JVM はそのまま）** | サーバのサービスを作り直す。JVM とログマネージャは同じ | FILE ハンドラが開き直されなければ影響なし。開き直される場合は JVM 再起動と同じく、その瞬間の current で解決される | 開き直されても同じ実体パスなので影響なし | ソース解析。開き直しの有無は実機未確認（修正後はどちらでも結果が同じ） |

### Q4. 起動ごとに、日付をまたぐタイミングで server.log のみとなるか、server.log-yyyy-MM-dd HH のようなファイルに書き出されてしまうか

- ファイル名は「server.log＋suffix」。既定の suffix は .yyyy-MM-dd なので、できるのは server.log.2026-09-16 の形だけ（区切りはドット、時刻 HH は付かない）。
- HH が付くのは suffix に HH を入れた場合だけ（毎時ローテーション: 例 .yyyy-MM-dd-HH → server.log.2026-09-16-23）。periodic-size-rotating-file-handler では server.log.2026-09-16.1 のように番号が付く。「server.log-yyyy-MM-dd HH」のような空白入りの名前は既定設定では作られない。
- 新しいディレクトリで起動した JVM: 起動直後は server.log だけ。日付付きファイルは「その JVM が 0 時をまたいで生き、0 時以降に最初のログを書いた瞬間」に 1 つだけできる。0 時の直前・直後に起動しても、起動しただけでは日付付きファイルはできない。
- 修正前の実装では、その日付付きファイルが「自分のディレクトリ」ではなく「current が指すディレクトリ」にでき、しかも他タスクの現役ファイルが日付付きにされる。起動したばかりの新タスクのディレクトリに、起動した覚えのない server.log.\<前日\> が現れ、そこへ当日のログが増え続けるのはこのため（実機で再現）。
- 同じディレクトリを再利用して起動した場合（タスク ID 方式＋コンテナ再起動、または修正後の JVM 再起動）: 既存 server.log の最終更新が前日以前なら、起動直後に server.log.\<最終更新日\> ができて新しい server.log が始まる。同日なら server.log に追記。
- 名前に付く日付は「閉じる期間の日付」。2 日間ログが無かったファイルが 9/17 にローテーションされると server.log.\<最後に書いた日\>（例 .2026-09-15）になり、ログの無かった日のファイルは作られない。

---

## 6. 動作イメージ（時系列とディレクトリの状態）

> **やさしく言うと:** 時計の順に『current がどこを指しているか』『だれがどのファイルに書いているか』を並べると、事故の瞬間がはっきり見えます。

### S1. ご報告のケース：新タスクが 0 時後に起動 → 旧タスクが停止（minimumHealthyPercent=100 / maximumPercent=200）

| 時刻（JVM） | 出来事 | current | A（旧）の書き込み先 | B（新）の書き込み先 |
|---|---|---|---|---|
| **9/16 10:00** | 旧タスク A 起動。nextRollover(A)=9/17 0:00、nextSuffix(A)=.2026-09-16 | A | A/server.log | ― |
| **9/17 0:00** | 0 時。A はログを書いていないのでまだ何も起きない（ローテーションは次のログ時） | A | A/server.log | ― |
| **9/17 0:03** | 新タスク B 起動 → ln -sfn B current。B は B/server.log を新規作成して開く。nextRollover(B)=9/18 0:00 | B | A/server.log | B/server.log |
| **9/17 0:05** | ローリングデプロイで A 停止 → A が停止ログを書く＝0 時以降の最初のレコード → A のローテーション発動 | B |  |  |
|  | ① A が自分の fd（A/server.log）を閉じる | B | （閉じた） | B/server.log |
|  | ② rename(…/log/server.log → …/log/server.log.2026-09-16)。current=B なので B の現役ファイルが改名される | B |  | B/server.log.2026-09-16（fd はそのまま） |
|  | ③ …/log/server.log を開き直す → B/server.log を新規作成。A の停止ログはここへ | B | B/server.log | B/server.log.2026-09-16 |
| **9/17 0:05〜** | A 終了。B は 9/17 のログを前日付ファイルに追記し続ける ← 症状 | B | ― | B/server.log.2026-09-16 |
| **9/18 0:00〜** | B の最初のローテーション: B/server.log（A の停止ログ）→ B/server.log.2026-09-17 に改名。B/server.log を新規作成 | B（別タスクが起動していればそちら） | ― | B/server.log |

**ディレクトリの状態**

```
【9/17 0:05 以降の EFS】                         【本来あるべき姿】
mid/                                              mid/
├── current -> B                                  ├── current -> B
├── A/                                            ├── A/
│   └── server.log          (A の 9/16 分・未改名) │   ├── server.log.2026-09-16  (A の 9/16 分)
└── B/                                            │   └── server.log             (A の停止ログ)
    ├── server.log.2026-09-16 (B の 9/17 分!)      └── B/
    └── server.log            (A の停止ログ!)          └── server.log             (B の 9/17 分)
```

**S1 の 0:05 以降のファイル**

| ディレクトリ | ファイル | 中身（修正前） | 本来あるべき姿（修正後） |
|---|---|---|---|
| **A/** | server.log | A の 9/16 分（改名されないまま） | A/server.log.2026-09-16（A の 9/16 分）と A/server.log（A の停止ログ） |
| **B/** | server.log.2026-09-16 | B の 9/17 分（前日付の名前で追記され続ける） | 存在しない |
| **B/** | server.log | A の停止ログ（他タスクのログが混入） | B の 9/17 分 |

### S2. 2 つのタスクが 0 時をまたいで稼働（A が先にログを書く）

| 時刻（JVM） | 出来事 | A の書き込み先 | B の書き込み先 | 失われるもの |
|---|---|---|---|---|
| **9/16 22:00** | A 起動（current→A） | A/server.log | ― |  |
| **9/16 23:30** | B 起動（current→B）。日中・夕方のデプロイやスケールアウトで 2 タスク以上が並走しても同じ | A/server.log | B/server.log |  |
| **9/17 0:00:05** | A がログ → A のローテーション: A の fd を閉じる → B/server.log（B の現役）を B/server.log.2026-09-16 に改名 → B/server.log を新規作成 | B/server.log（新規） | B/server.log.2026-09-16（fd） |  |
| **9/17 0:00:07** | B がログ → B のローテーション: B の fd を閉じる → B/server.log（A のファイル）を B/server.log.2026-09-16 に上書き改名（REPLACE_EXISTING）→ B/server.log を新規作成 | B/server.log.2026-09-16（fd） | B/server.log（新規） | B の 9/16 分が丸ごと消える |
| **以後** | A の 9/17 分は B/server.log.2026-09-16 へ、B の 9/17 分は B/server.log へ。A/server.log は A の 9/16 分のまま改名されない | B/server.log.2026-09-16 | B/server.log |  |

### S2r. 2 つのタスクが 0 時をまたいで稼働（B が先にログを書く）

| 時刻（JVM） | 出来事 | A の書き込み先 | B の書き込み先 | 失われるもの |
|---|---|---|---|---|
| **9/17 0:00:05** | B がログ → B のローテーション（B のディレクトリなので正しい）: B/server.log → B/server.log.2026-09-16、B/server.log を新規作成 | A/server.log | B/server.log（新規） |  |
| **9/17 0:00:07** | A がログ → A のローテーション: A の fd を閉じる → B/server.log（B の新しい現役）を B/server.log.2026-09-16 に上書き改名 → B/server.log を新規作成 | B/server.log（新規） | B/server.log.2026-09-16（fd） | B の 9/16 分が丸ごと消える |
| **以後** | B の 9/17 分は前日付ファイルへ（症状）、A の 9/17 分は B/server.log へ | B/server.log | B/server.log.2026-09-16 |  |

### S3. 日中・夕方の起動が夜に効いてくるケース

- desiredCount=2 で 15:00 にデプロイ → 新タスク B1・B2 が起動し、旧タスクは 15:05 に停止。この時点では問題なし（0 時をまたいでいない）。
- しかし B1 と B2 は並走したまま 0 時を迎える。current は後から起動した B2 を指しているので、0 時に B1 が B2 の server.log を改名する（S2／S2r 型）。これは毎晩起きる。
- desiredCount=1 でも、夕方のデプロイが失敗して新タスクが再起動を繰り返し、旧タスクが 0 時まで残った場合や、オートスケール・AZ リバランスでタスクが増えた場合は同じことが起きる。

### S4. 0 時をまたぐ失敗デプロイ（新タスクがクラッシュループ）

- 新タスクが起動のたびに current を張り替え、ヘルスチェックに失敗して止まる。旧タスクは minimumHealthyPercent=100 のため生き残る。
- 0 時に旧タスクがローテーションすると、改名と再 open は『最後に起動した（もう止まっているかもしれない）新タスク』のディレクトリで行われる。旧タスクの 0 時以降のログはすべてそのディレクトリへ書かれ、旧タスク自身のディレクトリには 1 行も増えない。
- サーキットブレーカー（rollback=true）で失敗デプロイを早く終わらせると、この状態の時間を短くできる（根本対策ではない）。

### 修正後（全ケース共通）

- 各 JBoss は -Djboss.server.log.dir=mid/\<自分の LOG_ID\>（実体パス）で起動する。rename も再 open も自分のディレクトリの中だけで行われ、current が誰を指していても関係ない。
- S1: A/server.log → A/server.log.2026-09-16、A の停止ログは A/server.log。B は B/server.log に 9/17 分を書き続ける。
- S2／S2r: A も B も自分のディレクトリで server.log.2026-09-16 を作る。上書きは起きず、何も消えない。
- current は「最後に起動したタスク」の目印として今までどおり張り替えられる（運用者・ログ収集の入口として残す）。

---

## 7. 実機検証（修正前のリポジトリそのまま と 修正後）

> **やさしく言うと:** 本物の WildFly（JBoss EAP の元になっているサーバ）を ECS と同じ条件で動かし、0 時をまたがせて、どのファイルに何が書かれたかを確かめました。

### 7-1. 検証の方法

| 項目 | 内容 |
|---|---|
| **目的** | 修正前のリポジトリの実装そのままで症状が起きること、修正後に起きないことを、本物の JBoss 系サーバで確かめる |
| **サーバ** | WildFly 26.1.3.Final（JBoss EAP 7.4 相当、jboss-logmanager 2.1.18、OpenJDK 11）と WildFly 41.0.1.Final（JBoss EAP 8.x 相当、jboss-logmanager 2.1.19、OpenJDK 25）。/opt/jboss-eap に配置し、リポジトリの Dockerfile（base → front、Service_Name=intra-web、Component_name=intra-web-front、STRICT_SEED=1）をそのまま使ってビルド |
| **ECS との対応** | --read-only＝readonlyRootFilesystem、--tmpfs で configuration／tmp／data＝タスクローカルの空ボリューム（ECS と同じく中身はコピーされない）、共有の Docker ボリューム /mnt/logs＝EFS、コンテナ A／B＝旧タスク／新タスク（別コンテナ・別 JVM・同じ共有ボリューム）、docker stop＝ローリングデプロイでの旧タスク停止（SIGTERM、LAUNCH_JBOSS_IN_BACKGROUND=true） |
| **0 時の作り方** | JVM のタイムゾーンだけを GMT±hh:mm にずらし、数分後が JVM にとっての 0 時になるようにした（ローテーションの判定もファイル名の日付も JVM のタイムゾーンで決まるため）。時計そのものは実時刻で、時刻の偽装はしていない |
| **ログの出し方** | 検証用 JSP（/ticker/log.jsp?who=…）で任意の時点に 1 行（TICK who=…）を出力。停止時は JBoss 自身の停止ログ（WFLYSRV0272／WFLYSRV0050） |
| **観察したもの** | ① /proc/\<java\>/fd：JVM が実際に握っているファイル（カーネルが解決した実パス）　② 共有ボリューム上の各ディレクトリの server.log* と、中の主要な行（起動 WFLYSRV0049／0025、停止 WFLYSRV0272／0050、TICK） |

### 7-2. 結果のまとめ

| シナリオ | 実装 | サーバ | 結果 | 確認できたこと |
|---|---|---|---|---|
| **S1（ご報告のケース）** | 修正前 | WildFly 26.1.3 | 再現 | 新タスク B の fd が server.log.2026-09-26 を指し、B の 9/27 のログ（起動完了後の TICK 3 件）が前日付ファイルへ。B/server.log には旧タスク A の停止ログ。A/server.log は改名されないまま |
| **S1（ご報告のケース）** | 修正前 | WildFly 41.0.1 | 再現 | WildFly 26.1.3 と同一の結果（EAP 8.x 相当でも同じ） |
| **S2（2 タスクが 0 時をまたぐ・A が先）** | 修正前 | WildFly 26.1.3 | 再現＋消失 | B の前日分（起動ログ・0 時前の TICK）がどのファイルにも残っていない。B/server.log.2026-09-26 の中身は A の 9/27 分 |
| **S2r（同・B が先）** | 修正前 | WildFly 26.1.3 | 再現＋消失 | B の前日分が消失。B は 9/27 分を server.log.2026-09-26 へ追記（fd で確認）。B/server.log の中身は A の 9/27 分 |
| **S1** | 修正後 | WildFly 26.1.3 | 解消 | A は自分のディレクトリで server.log.2026-09-26（9/26 分）と server.log（停止ログ）を作成。B の server.log に B の 9/27 分がすべて入り、fd も server.log のまま |
| **S2** | 修正後 | WildFly 26.1.3 | 解消 | A・B とも自分のディレクトリに server.log.2026-09-26（前日分）と server.log（当日分）。消失なし |
| **起動引数・fd・logging.properties** | 修正後 | WildFly 26.1.3／41.0.1 | 確認 | -Djboss.server.log.dir と -Dorg.jboss.boot.log.file が実体パス。fd（server.log・audit.log）も実体パス。起動後に書き直された logging.properties も実体パス |
| **エントリポイントの分岐（9 ケース＋冒頭検証）** | 修正後 | WildFly 26.1.3 | 確認 | 引数の挿入位置、明示指定の優先、pin=off、不正値の FATAL（current を触る前）、taskid のフォールバック、ラッパーの自己呼び出し防止、logging.properties の書き換え |
| **S2r・再起動系（:reload／JVM 再起動／コンテナ再起動）・WildFly 41 での修正後 S1・pin=off の再現** | 修正後／修正前 | ― | 未実施 | 検証中に PC の C: ドライブの空き容量が尽き、Docker が停止したため中止（5 章 Q3 はソース解析に基づく記述で、その旨を明記） |

### 7-3. 修正前・S1（WildFly 26.1.3）: ご報告の症状の再現

0 時後に起動した新タスク B が書いている server.log が、旧タスク A の停止ログ（0 時以降の最初のレコード）をきっかけに server.log.2026-09-26 へ改名され、B はそのまま前日付ファイルに書き続けた。B の fd の行き先が server.log → server.log.2026-09-26 に変わっている（名前だけが変わり、中身は同じ）。

**記録: scenario=S1 image=rot-old-front:wf26 tz=GMT+01:50 local-midnight=2026-09-27 00:00:00 extra=[]**

| 時刻（JVM） | 出来事（scenario.sh の記録） |
|---|---|
| 09-26 23:56:58 | START old-S1-wf26-A [efs-entrypoint] JBoss EAP log dir: mid/20260926220655-uy9x6wu8 |
| 09-26 23:58:10 | BOOTED old-S1-wf26-A (#1) |
| 09-26 23:58:15 | TICK old-S1-wf26-A who=A:before-midnight -\> ok A:before-midnight |
| 09-27 00:00:05 | ---- (0 時を通過: A はアイドルでログ未出力) ---- |
| 09-27 00:00:09 | START old-S1-wf26-B [efs-entrypoint] JBoss EAP log dir: mid/20260926221006-4vqd85c0 |
| 09-27 00:00:32 | BOOTED old-S1-wf26-B (#1) |
| 09-27 00:00:34 | TICK old-S1-wf26-B who=B:booted-after-midnight -\> ok B:booted-after-midnight |
| 09-27 00:00:35 | FD old-S1-wf26-B fd -\> mid/20260926221006-4vqd85c0/server.log |
| 09-27 00:00:35 | ---- rolling deploy: 旧タスク A を停止 (SIGTERM → 停止ログ = 0 時以降の最初のレコード) ---- |
| 09-27 00:00:38 | TICK old-S1-wf26-B who=B:after-A-stopped-1 -\> ok B:after-A-stopped-1 |
| 09-27 00:00:38 | TICK old-S1-wf26-B who=B:after-A-stopped-2 -\> ok B:after-A-stopped-2 |
| 09-27 00:00:39 | FD old-S1-wf26-B fd -\> mid/20260926221006-4vqd85c0/server.log.2026-09-26 |

**EFS（共有ボリューム）の最終状態: ディレクトリごとの server.log* と、中の主要な行**

```
current -> 20260926221006-4vqd85c0
[20260926220655-uy9x6wu8]
  server.log  (size=13593 bytes, inode=985569)
      2026-09-26 23:57:01,375  WFLYSRV0049: WildFly Full 26.1.3.Final (WildFly Core 18.1.2.Final) starting
      2026-09-26 23:57:37,251  WFLYSRV0025: WildFly Full 26.1.3.Final (WildFly Core 18.1.2.Final) started in 40567ms -
      2026-09-26 23:58:15,431  TICK who=A:before-midnight
[20260926221006-4vqd85c0]
  server.log  (size=2361 bytes, inode=980367)
      2026-09-27 00:00:36,224  WFLYSRV0272: Suspending server
      2026-09-27 00:00:36,470  WFLYSRV0050: WildFly Full 26.1.3.Final (WildFly Core 18.1.2.Final) stopped in 181ms
  server.log.2026-09-26  (size=13769 bytes, inode=985722)
      2026-09-27 00:00:11,054  WFLYSRV0049: WildFly Full 26.1.3.Final (WildFly Core 18.1.2.Final) starting
      2026-09-27 00:00:31,722  WFLYSRV0025: WildFly Full 26.1.3.Final (WildFly Core 18.1.2.Final) started in 24104ms -
      2026-09-27 00:00:34,724  TICK who=B:booted-after-midnight
      2026-09-27 00:00:37,859  TICK who=B:after-A-stopped-1
      2026-09-27 00:00:38,693  TICK who=B:after-A-stopped-2
```

### 7-4. 修正前・S1（WildFly 41.0.1）: EAP 8.x 相当でも同じ

WildFly 41.0.1（jboss-logmanager 2.1.19、JDK 25）でも同じ結果。ローテーション手順がバージョンをまたいで同一であることと整合する。

**記録: scenario=S1 image=rot-old-front:wf41 tz=GMT+01:50 local-midnight=2026-09-27 00:00:00 extra=[]**

| 時刻（JVM） | 出来事（scenario.sh の記録） |
|---|---|
| 09-26 23:57:12 | START old-S1-wf41-A [efs-entrypoint] JBoss EAP log dir: mid/20260926220709-fdjqqioy |
| 09-26 23:58:09 | BOOTED old-S1-wf41-A (#1) |
| 09-26 23:58:12 | TICK old-S1-wf41-A who=A:before-midnight -\> ok A:before-midnight |
| 09-27 00:00:05 | ---- (0 時を通過: A はアイドルでログ未出力) ---- |
| 09-27 00:00:09 | START old-S1-wf41-B [efs-entrypoint] JBoss EAP log dir: mid/20260926221006-gpgen4az |
| 09-27 00:00:29 | BOOTED old-S1-wf41-B (#1) |
| 09-27 00:00:32 | TICK old-S1-wf41-B who=B:booted-after-midnight -\> ok B:booted-after-midnight |
| 09-27 00:00:32 | FD old-S1-wf41-B fd -\> mid/20260926221006-gpgen4az/server.log |
| 09-27 00:00:33 | ---- rolling deploy: 旧タスク A を停止 (SIGTERM → 停止ログ = 0 時以降の最初のレコード) ---- |
| 09-27 00:00:35 | TICK old-S1-wf41-B who=B:after-A-stopped-1 -\> ok B:after-A-stopped-1 |
| 09-27 00:00:36 | TICK old-S1-wf41-B who=B:after-A-stopped-2 -\> ok B:after-A-stopped-2 |
| 09-27 00:00:36 | FD old-S1-wf41-B fd -\> mid/20260926221006-gpgen4az/server.log.2026-09-26 |

**EFS（共有ボリューム）の最終状態: ディレクトリごとの server.log* と、中の主要な行**

```
current -> 20260926221006-gpgen4az
[20260926220709-fdjqqioy]
  server.log  (size=18367 bytes, inode=985624)
      2026-09-26 23:57:21,991  WFLYSRV0049: WildFly 41.0.1.Final (WildFly Core 33.0.1.Final) starting
      2026-09-26 23:57:47,668  WFLYSRV0025: WildFly 41.0.1.Final (WildFly Core 33.0.1.Final) started in 36861ms - Star
      2026-09-26 23:58:12,640  TICK who=A:before-midnight
[20260926221006-gpgen4az]
  server.log  (size=2829 bytes, inode=985606)
      2026-09-27 00:00:33,574  WFLYSRV0272: Suspending server
      2026-09-27 00:00:33,817  WFLYSRV0050: WildFly 41.0.1.Final (WildFly Core 33.0.1.Final) stopped in 197ms
  server.log.2026-09-26  (size=18543 bytes, inode=985620)
      2026-09-27 00:00:10,926  WFLYSRV0049: WildFly 41.0.1.Final (WildFly Core 33.0.1.Final) starting
      2026-09-27 00:00:28,133  WFLYSRV0025: WildFly 41.0.1.Final (WildFly Core 33.0.1.Final) started in 20789ms - Star
      2026-09-27 00:00:32,290  TICK who=B:booted-after-midnight
      2026-09-27 00:00:35,340  TICK who=B:after-A-stopped-1
      2026-09-27 00:00:35,959  TICK who=B:after-A-stopped-2
```

### 7-5. 修正前・S2（2 タスクが 0 時をまたぐ・A が先にログ）: 前日分の消失

A のローテーションが B の現役 server.log を server.log.2026-09-26 に改名し、続く B のローテーションが B/server.log（A が作ったファイル）を同じ名前へ上書き改名した。その結果、B の起動ログと 0 時前の TICK はどのファイルにも残っていない。A/server.log は改名されずに残った。

**記録: scenario=S2 image=rot-old-front:wf26 tz=GMT+00:01 local-midnight=2026-09-27 00:00:00 extra=[]**

| 時刻（JVM） | 出来事（scenario.sh の記録） |
|---|---|
| 09-26 23:56:44 | START old-S2-wf26-A [efs-entrypoint] JBoss EAP log dir: mid/20260926235541-1u81lhd0 |
| 09-26 23:56:59 | BOOTED old-S2-wf26-A (#1) |
| 09-26 23:57:01 | TICK old-S2-wf26-A who=A:before-midnight -\> ok A:before-midnight |
| 09-26 23:57:05 | START old-S2-wf26-B [efs-entrypoint] JBoss EAP log dir: mid/20260926235602-zqg0rr97 |
| 09-26 23:57:21 | BOOTED old-S2-wf26-B (#1) |
| 09-26 23:57:22 | TICK old-S2-wf26-B who=B:before-midnight -\> ok B:before-midnight |
| 09-26 23:57:23 | FD old-S2-wf26-A fd -\> mid/20260926235541-1u81lhd0/server.log |
| 09-26 23:57:24 | FD old-S2-wf26-B fd -\> mid/20260926235602-zqg0rr97/server.log |
| 09-27 00:00:07 | ---- 0 時を通過 ---- |
| 09-27 00:00:07 | TICK old-S2-wf26-A who=A:after-midnight-1 -\> ok A:after-midnight-1 |
| 09-27 00:00:08 | TICK old-S2-wf26-B who=B:after-midnight-1 -\> ok B:after-midnight-1 |
| 09-27 00:00:08 | TICK old-S2-wf26-A who=A:after-midnight-2 -\> ok A:after-midnight-2 |
| 09-27 00:00:09 | TICK old-S2-wf26-B who=B:after-midnight-2 -\> ok B:after-midnight-2 |
| 09-27 00:00:09 | FD old-S2-wf26-A fd -\> mid/20260926235602-zqg0rr97/server.log.2026-09-26 |
| 09-27 00:00:10 | FD old-S2-wf26-B fd -\> mid/20260926235602-zqg0rr97/server.log |

**EFS（共有ボリューム）の最終状態: ディレクトリごとの server.log* と、中の主要な行**

```
current -> 20260926235602-zqg0rr97
[20260926235541-1u81lhd0]
  server.log  (size=13593 bytes, inode=986057)
      2026-09-26 23:56:45,475  WFLYSRV0049: WildFly Full 26.1.3.Final (WildFly Core 18.1.2.Final) starting
      2026-09-26 23:56:58,420  WFLYSRV0025: WildFly Full 26.1.3.Final (WildFly Core 18.1.2.Final) started in 15857ms -
      2026-09-26 23:57:01,691  TICK who=A:before-midnight
[20260926235602-zqg0rr97]
  server.log  (size=168 bytes, inode=986157)
      2026-09-27 00:00:08,103  TICK who=B:after-midnight-1
      2026-09-27 00:00:09,217  TICK who=B:after-midnight-2
  server.log.2026-09-26  (size=168 bytes, inode=986163)
      2026-09-27 00:00:07,542  TICK who=A:after-midnight-1
      2026-09-27 00:00:08,665  TICK who=A:after-midnight-2
```

### 7-6. 修正前・S2r（B が先にログ）: 消失＋前日付ファイルへの追記

B は自分のディレクトリで正しくローテーションしたが、直後の A のローテーションが B の新しい server.log を server.log.2026-09-26 へ上書き改名したため、B の前日分が消失し、B の 9/27 分は前日付ファイルへ（fd で確認）。

**記録: scenario=S2r image=rot-old-front:wf26 tz=GMT+00:01 local-midnight=2026-09-27 00:00:00 extra=[]**

| 時刻（JVM） | 出来事（scenario.sh の記録） |
|---|---|
| 09-26 23:56:44 | START old-S2r-wf26-A [efs-entrypoint] JBoss EAP log dir: mid/20260926235541-28dxbr21 |
| 09-26 23:56:59 | BOOTED old-S2r-wf26-A (#1) |
| 09-26 23:57:01 | TICK old-S2r-wf26-A who=A:before-midnight -\> ok A:before-midnight |
| 09-26 23:57:05 | START old-S2r-wf26-B [efs-entrypoint] JBoss EAP log dir: mid/20260926235602-u5ri0072 |
| 09-26 23:57:20 | BOOTED old-S2r-wf26-B (#1) |
| 09-26 23:57:22 | TICK old-S2r-wf26-B who=B:before-midnight -\> ok B:before-midnight |
| 09-26 23:57:23 | FD old-S2r-wf26-A fd -\> mid/20260926235541-28dxbr21/server.log |
| 09-26 23:57:23 | FD old-S2r-wf26-B fd -\> mid/20260926235602-u5ri0072/server.log |
| 09-27 00:00:06 | ---- 0 時を通過 ---- |
| 09-27 00:00:07 | TICK old-S2r-wf26-B who=B:after-midnight-1 -\> ok B:after-midnight-1 |
| 09-27 00:00:08 | TICK old-S2r-wf26-A who=A:after-midnight-1 -\> ok A:after-midnight-1 |
| 09-27 00:00:08 | TICK old-S2r-wf26-B who=B:after-midnight-2 -\> ok B:after-midnight-2 |
| 09-27 00:00:09 | TICK old-S2r-wf26-A who=A:after-midnight-2 -\> ok A:after-midnight-2 |
| 09-27 00:00:09 | FD old-S2r-wf26-A fd -\> mid/20260926235602-u5ri0072/server.log |
| 09-27 00:00:10 | FD old-S2r-wf26-B fd -\> mid/20260926235602-u5ri0072/server.log.2026-09-26 |

**EFS（共有ボリューム）の最終状態: ディレクトリごとの server.log* と、中の主要な行**

```
current -> 20260926235602-u5ri0072
[20260926235541-28dxbr21]
  server.log  (size=13592 bytes, inode=986056)
      2026-09-26 23:56:45,471  WFLYSRV0049: WildFly Full 26.1.3.Final (WildFly Core 18.1.2.Final) starting
      2026-09-26 23:56:58,411  WFLYSRV0025: WildFly Full 26.1.3.Final (WildFly Core 18.1.2.Final) started in 15848ms -
      2026-09-26 23:57:01,520  TICK who=A:before-midnight
[20260926235602-u5ri0072]
  server.log  (size=168 bytes, inode=986149)
      2026-09-27 00:00:07,954  TICK who=A:after-midnight-1
      2026-09-27 00:00:09,018  TICK who=A:after-midnight-2
  server.log.2026-09-26  (size=168 bytes, inode=986160)
      2026-09-27 00:00:07,430  TICK who=B:after-midnight-1
      2026-09-27 00:00:08,474  TICK who=B:after-midnight-2
```

### 7-7. 修正後・S1（WildFly 26.1.3）: 解消

A のローテーションは A 自身のディレクトリで完結（server.log → server.log.2026-09-26、停止ログは新しい server.log）。B のファイルには一切触れず、B の fd は最後まで server.log を指した。

**記録: scenario=S1 image=rot-new-front:wf26 tz=GMT-00:04 local-midnight=2026-09-27 00:00:00 extra=[]**

| 時刻（JVM） | 出来事（scenario.sh の記録） |
|---|---|
| 09-26 23:57:13 | START new-S1-wf26-A [efs-entrypoint] JBoss EAP log dir: mid/20260927000111-grn25mek (LOG_ID_SOURCE=random) [efs-entrypoint] log pin: JBoss は mid/20260927000111-grn25mek へ直接書き込みます (current は書き込み経路に使いません) |
| 09-26 23:57:21 | BOOTED new-S1-wf26-A (#1) |
| 09-26 23:57:22 | TICK new-S1-wf26-A who=A:before-midnight -\> ok A:before-midnight |
| 09-27 00:00:05 | ---- (0 時を通過: A はアイドルでログ未出力) ---- |
| 09-27 00:00:09 | START new-S1-wf26-B [efs-entrypoint] JBoss EAP log dir: mid/20260927000406-29i0j34g (LOG_ID_SOURCE=random) [efs-entrypoint] log pin: JBoss は mid/20260927000406-29i0j34g へ直接書き込みます (current は書き込み経路に使いません) |
| 09-27 00:00:17 | BOOTED new-S1-wf26-B (#1) |
| 09-27 00:00:18 | TICK new-S1-wf26-B who=B:booted-after-midnight -\> ok B:booted-after-midnight |
| 09-27 00:00:19 | FD new-S1-wf26-B fd -\> mid/20260927000406-29i0j34g/server.log |
| 09-27 00:00:19 | ---- rolling deploy: 旧タスク A を停止 (SIGTERM → 停止ログ = 0 時以降の最初のレコード) ---- |
| 09-27 00:00:21 | TICK new-S1-wf26-B who=B:after-A-stopped-1 -\> ok B:after-A-stopped-1 |
| 09-27 00:00:21 | TICK new-S1-wf26-B who=B:after-A-stopped-2 -\> ok B:after-A-stopped-2 |
| 09-27 00:00:22 | FD new-S1-wf26-B fd -\> mid/20260927000406-29i0j34g/server.log |

**EFS（共有ボリューム）の最終状態: ディレクトリごとの server.log* と、中の主要な行**

```
current -> 20260927000406-29i0j34g
[20260927000111-grn25mek]
  server.log  (size=2359 bytes, inode=791291)
      2026-09-27 00:00:19,771  WFLYSRV0272: Suspending server
      2026-09-27 00:00:19,883  WFLYSRV0050: WildFly Full 26.1.3.Final (WildFly Core 18.1.2.Final) stopped in 96ms
  server.log.2026-09-26  (size=13800 bytes, inode=986108)
      2026-09-26 23:57:13,226  WFLYSRV0049: WildFly Full 26.1.3.Final (WildFly Core 18.1.2.Final) starting
      2026-09-26 23:57:19,388  WFLYSRV0025: WildFly Full 26.1.3.Final (WildFly Core 18.1.2.Final) started in 7477ms -
      2026-09-26 23:57:22,773  TICK who=A:before-midnight
[20260927000406-29i0j34g]
  server.log  (size=13976 bytes, inode=986159)
      2026-09-27 00:00:08,868  WFLYSRV0049: WildFly Full 26.1.3.Final (WildFly Core 18.1.2.Final) starting
      2026-09-27 00:00:17,005  WFLYSRV0025: WildFly Full 26.1.3.Final (WildFly Core 18.1.2.Final) started in 9566ms -
      2026-09-27 00:00:18,636  TICK who=B:booted-after-midnight
      2026-09-27 00:00:21,065  TICK who=B:after-A-stopped-1
      2026-09-27 00:00:21,563  TICK who=B:after-A-stopped-2
```

### 7-8. 修正後・S2（WildFly 26.1.3）: 解消

A・B がそれぞれ自分のディレクトリで server.log.2026-09-26 を作り、当日分は各自の server.log へ。上書きも消失も起きない。current は後から起動した B を指したままだが、書き込みには影響しない。

**記録: scenario=S2 image=rot-new-front:wf26 tz=GMT-00:04 local-midnight=2026-09-27 00:00:00 extra=[]**

| 時刻（JVM） | 出来事（scenario.sh の記録） |
|---|---|
| 09-26 23:56:44 | START new-S2-wf26-A [efs-entrypoint] JBoss EAP log dir: mid/20260927000041-1y4q59rh (LOG_ID_SOURCE=random) [efs-entrypoint] log pin: JBoss は mid/20260927000041-1y4q59rh へ直接書き込みます (current は書き込み経路に使いません) |
| 09-26 23:56:51 | BOOTED new-S2-wf26-A (#1) |
| 09-26 23:56:53 | TICK new-S2-wf26-A who=A:before-midnight -\> ok A:before-midnight |
| 09-26 23:56:56 | START new-S2-wf26-B [efs-entrypoint] JBoss EAP log dir: mid/20260927000054-hj3kahao (LOG_ID_SOURCE=random) [efs-entrypoint] log pin: JBoss は mid/20260927000054-hj3kahao へ直接書き込みます (current は書き込み経路に使いません) |
| 09-26 23:57:04 | BOOTED new-S2-wf26-B (#1) |
| 09-26 23:57:05 | TICK new-S2-wf26-B who=B:before-midnight -\> ok B:before-midnight |
| 09-26 23:57:06 | FD new-S2-wf26-A fd -\> mid/20260927000041-1y4q59rh/server.log |
| 09-26 23:57:06 | FD new-S2-wf26-B fd -\> mid/20260927000054-hj3kahao/server.log |
| 09-27 00:00:06 | ---- 0 時を通過 ---- |
| 09-27 00:00:07 | TICK new-S2-wf26-A who=A:after-midnight-1 -\> ok A:after-midnight-1 |
| 09-27 00:00:08 | TICK new-S2-wf26-B who=B:after-midnight-1 -\> ok B:after-midnight-1 |
| 09-27 00:00:08 | TICK new-S2-wf26-A who=A:after-midnight-2 -\> ok A:after-midnight-2 |
| 09-27 00:00:09 | TICK new-S2-wf26-B who=B:after-midnight-2 -\> ok B:after-midnight-2 |
| 09-27 00:00:10 | FD new-S2-wf26-A fd -\> mid/20260927000041-1y4q59rh/server.log |
| 09-27 00:00:10 | FD new-S2-wf26-B fd -\> mid/20260927000054-hj3kahao/server.log |

**EFS（共有ボリューム）の最終状態: ディレクトリごとの server.log* と、中の主要な行**

```
current -> 20260927000054-hj3kahao
[20260927000041-1y4q59rh]
  server.log  (size=168 bytes, inode=986152)
      2026-09-27 00:00:07,449  TICK who=A:after-midnight-1
      2026-09-27 00:00:08,638  TICK who=A:after-midnight-2
  server.log.2026-09-26  (size=13800 bytes, inode=985996)
      2026-09-26 23:56:43,846  WFLYSRV0049: WildFly Full 26.1.3.Final (WildFly Core 18.1.2.Final) starting
      2026-09-26 23:56:49,925  WFLYSRV0025: WildFly Full 26.1.3.Final (WildFly Core 18.1.2.Final) started in 7354ms -
      2026-09-26 23:56:53,386  TICK who=A:before-midnight
[20260927000054-hj3kahao]
  server.log  (size=168 bytes, inode=986160)
      2026-09-27 00:00:07,996  TICK who=B:after-midnight-1
      2026-09-27 00:00:09,231  TICK who=B:after-midnight-2
  server.log.2026-09-26  (size=13801 bytes, inode=986044)
      2026-09-26 23:56:56,210  WFLYSRV0049: WildFly Full 26.1.3.Final (WildFly Core 18.1.2.Final) starting
      2026-09-26 23:57:02,367  WFLYSRV0025: WildFly Full 26.1.3.Final (WildFly Core 18.1.2.Final) started in 7388ms -
      2026-09-26 23:57:05,633  TICK who=B:before-midnight
```

### 7-9. 起動引数・fd・logging.properties の実測値（修正前と修正後）

**1 タスク起動時の実測（ECS と同条件）**

```
【修正前】WildFly 26.1.3
  JVM 引数: -Dorg.jboss.boot.log.file=/opt/jboss-eap/standalone/log/server.log      ← current 経由のパス
  fd 81   -> /mnt/logs/intra-web-front/logs/intra-web/mid/20260926220109-e9791z0b/server.log   (open の瞬間に解決された実体)
  起動後の logging.properties: handler.FILE.fileName=/opt/jboss-eap/standalone/log/server.log   (JBoss が絶対パスで書き直す)

【修正後】WildFly 26.1.3
  JVM 引数: -Dorg.jboss.boot.log.file=/mnt/logs/intra-web-front/logs/intra-web/mid/20260926231526-f63c1n73/server.log
  JVM 引数: -Djboss.server.log.dir=/mnt/logs/intra-web-front/logs/intra-web/mid/20260926231526-f63c1n73
  fd      -> /mnt/logs/intra-web-front/logs/intra-web/mid/20260926231526-f63c1n73/server.log
  fd      -> /mnt/logs/intra-web-front/logs/intra-web/mid/20260926231526-f63c1n73/audit.log   (Elytron の監査ログも実体パス)

【修正後】WildFly 41.0.1
  [efs-entrypoint] log pin: JBoss は /mnt/logs/intra-web-front/logs/intra-web/mid/20260926231418-ebbisg5u へ直接書き込みます (current は書き込み経路に使いません)
  [efs-entrypoint] preflight OK. starting: /opt/jboss-eap/bin/standalone.sh -Djboss.server.log.dir=/mnt/logs/intra-web-front/logs/intra-web/mid/20260926231418-ebbisg5u -b 0.0.0.0
  起動後の logging.properties: handler.FILE.fileName=/mnt/logs/intra-web-front/logs/intra-web/mid/20260926231418-ebbisg5u/server.log
```

### 7-10. エントリポイントの分岐の試験（JBoss を起動せず exec 直前の状態を確認）

| ケース | 期待する動作 | 結果 |
|---|---|---|
| **1. 既定（pin=on）＋CMD が standalone.sh 以外** | WARN を出し -D は付与しない。JBOSS_LOG_DIR は export | 期待どおり（JBOSS_LOG_DIR=…/mid/\<LOG_ID\>） |
| **2. 既定（pin=on）＋CMD=…/standalone.sh** | コマンド直後に -Djboss.server.log.dir=\<実体パス\> を挿入 | 期待どおり（ARGS: -Djboss.server.log.dir=…/mid/\<LOG_ID\> -b 0.0.0.0） |
| **3. -Djboss.server.log.dir を明示指定** | 明示指定を優先し pin しない（WARN） | 期待どおり（引数は変更なし） |
| **4. JBOSS_LOG_PIN=off** | 従来どおり current 経由（WARN） | 期待どおり（JBOSS_LOG_DIR 未設定） |
| **5. JBOSS_LOG_PIN=maybe（不正値）** | FATAL＋診断ダンプで停止 | 期待どおり。修正で current を張り替える前に停止するようにした |
| **6. LOG_ID_SOURCE=foo（不正値）** | FATAL＋診断ダンプで停止 | 期待どおり |
| **7. LOG_ID_SOURCE=taskid（メタデータ無し）** | WARN を出し random 方式にフォールバック | 期待どおり |
| **8. ラッパーの自己呼び出し** | FATAL で停止（無限 exec を防止） | 期待どおり |
| **9. logging.properties に current 経由・前回 LOG_ID のパスが残っている（CONFIG_SEED_MODE=skip）** | 今回の実体パスへ書き換え | 期待どおり（handler.FILE と追加ハンドラの両方） |

> **検証の限界:** 共有ストレージは EFS ではなく同一ホスト上の Docker ボリューム（ext4）で代用した。rename と fd の関係（名前だけが変わる・開いている側は書き続ける・上書きで名前を失ったファイルは消える）は NFS のファイルハンドルでも同じだが、NFS 固有の属性キャッシュや、別クライアントが開いているファイルを消した場合の ESTALE は再現していない。サーバは JBoss EAP 本体ではなくアップストリームの WildFly（ログ部分の jboss-logmanager・logging サブシステム・standalone.sh は同系統で、既定の FILE ハンドラ設定も同一）。0 時は JVM のタイムゾーンをずらして作った。S2r の修正後、:reload／JVM 再起動／コンテナ再起動、WildFly 41 での修正後、pin=off の再現は、PC のディスク容量不足で Docker が停止したため未実施。

---

## 8. 対処法（方式の比較と採用案）

> **やさしく言うと:** 一番よいのは『自分の机の住所を直接教える』こと。デプロイの時間をずらすのは、事故の回数を減らすだけで、なくすことはできません。

| 案 | 内容 | 効果 | タスク定義の変更 | 評価 |
|---|---|---|---|---|
| **A. 実体パスへの固定（pin）【採用・実装済み】** | エントリポイントが -Djboss.server.log.dir=mid/\<LOG_ID\> を standalone.sh に付け、JBOSS_LOG_DIR も同じ値にする。logging.properties に残った current 経由・前回 LOG_ID のパスも揃える | rename／再 open が常に自分のディレクトリで行われる。server.log・audit.log・（GC_LOG=true 時）gc.log・access_log.log（access-log の directory の既定 ${jboss.server.log.dir}）・relative-to=jboss.server.log.dir のハンドラすべてに効く（pin を素通りする明示の書き方は 10-2 で揃える）。JVM 再起動（exit 10）でも自分のディレクトリに戻る | 不要 | ◎ 根本対策 |
| **B. コンテナ専用リンク（3 段リンク）** | standalone/log → タスクローカルの書き込み可能ボリューム上のリンク → mid/\<LOG_ID\>。リンクがコンテナごとに独立する | A と同等。/opt/jboss-eap/standalone/log を ECS Exec で覗いたときに自分のログが見える | 必要（ボリューム追加） | ○ 代替案 |
| **C. 標準出力（JSON）＋ awslogs／FireLens** | server.log をやめ、CONSOLE ハンドラ（json-formatter）から CloudWatch Logs や S3 へ送る | ファイルのローテーション自体が無くなる。タスク単位の検索・保管は CloudWatch 側で行う（12-Factor の考え方） | 必要（ログ設定） | ○ 中長期の推奨 |
| **D. JBoss のローテーションを止める（file-handler）** | periodic-rotating をやめ、起動ごとのディレクトリを保管単位にする | rename は無くなるが、起動時の 1 回の open が current 経由だと並行起動の競合が残る。A と併用が前提 | 不要 | △ 単独では不十分 |
| **E. サイズ／起動時ローテーション（rotate-on-boot など）** | ローテーションの条件を変える | パスを共有している原因は変わらない | 不要 | × 効果なし |
| **F. suffix の変更（毎時など）** | ローテーションの周期を変える | 被害の単位が変わるだけ（毎時起きる） | 不要 | × 悪化し得る |
| **G. logrotate の copytruncate** | 外部ツールでコピー＆切り詰め | コンテナ・EFS では運用しにくく、コピー中のログが欠ける | 必要 | × 不向き |
| **H. デプロイ時刻・並走時間の調整** | 0 時帯を避ける、並走時間を縮める（9 章） | 発生確率が下がる | 一部必要 | △ 補助策 |

### 採用案 A を選んだ理由

- 原因（書き込み経路に共有の可変リンクがある）をそのまま取り除ける。
- JBoss 公式のシステムプロパティ jboss.server.log.dir と、standalone.sh が公式に解釈する JBOSS_LOG_DIR だけを使う。JBoss のバージョンアップに強い。
- タスク定義の変更が不要。イメージの再ビルドとデプロイだけで適用できる。
- 既存の 2 段リンク（standalone/log → current）と current の張り替えは残すので、運用手順やログ収集の入口は変わらない。
- 旧実装（ECS タスク ID 方式）も同じ本体に統合したので、どちらの方式でも同じ対策が必ず効く。

> **補足:** B（3 段リンク）は『ECS Exec で /opt/jboss-eap/standalone/log を見たら自分のログ』という見え方が欲しい場合に向きます。C（標準出力）はファイルを EFS に置く運用そのものを見直す中長期の選択肢です。A はどちらとも両立します。

---

## 9. ローリングデプロイ・ECS の設定（補助策と注意点）

> **やさしく言うと:** 並走する時間を短くし、0 時にかからないようにすると事故は減ります。ただし ECS は日中でも勝手にタスクを入れ替えるので、設定だけでは 0 にできません。

| 設定 | 推奨・方針 | 理由・効果 | 限界・注意 |
|---|---|---|---|
| **デプロイの時間帯** | JVM のタイムゾーンで 0 時の前後（例 23:30〜0:30）を避ける。CodePipeline／EventBridge Scheduler の実行時刻、変更管理ルールで制御 | S1・S4 型（0 時をまたぐ並走）を減らす | desiredCount≥2 や自動の入替には効かない |
| **minimumHealthyPercent／maximumPercent** | 無停止なら 100／200 のままでよい（修正後） | 新タスクを先に起動してから旧タスクを止めるので、並走は仕様上必ず起きる | 0／100 にすれば並走しないが停止時間が出る。修正前の緩和策としても非推奨 |
| **ALB ターゲットグループの登録解除の遅延（deregistration_delay、既定 300 秒）** | 長い接続が無ければ 30〜60 秒程度に短縮 | 旧タスクの生存時間（＝並走時間）を短くする | 長時間のリクエスト・WebSocket があると切れる |
| **ECS stopTimeout（Fargate 既定 30 秒、最大 120 秒）** | グレースフル停止に必要な長さに | 停止処理の上限時間。並走時間に加算される | 短すぎると停止ログやバッファが失われる |
| **デプロイサーキットブレーカー（rollback=true）** | 有効化。2026-07 から閾値（件数／割合）とカウント方式（連続／累積）を設定可能 | 失敗デプロイを早く終わらせ、S4 型（クラッシュループ中の current 張り替え）を短くする | 成功したデプロイの並走には関係しない |
| **Early Success Criteria（2026-09-04〜）** | 修正の適用前は使わない。使うなら sourceServiceRevisionCleanup=BLOCKING | DEFERRED は旧リビジョンのタスクをデプロイ完了後も最大 2 週間残し得る | 修正前の実装で DEFERRED を使うと 0 時のたびに確実に発生 |
| **ネイティブ Blue/Green（bakeTimeInMinutes）、Linear、Canary** | bake 中に 0 時をまたがない時間帯で実施（修正後は制約不要） | bake の間は Blue（旧）と Green（新）が並走する | 並走が長いほど 0 時にかかりやすい |
| **AZ リバランス（新規サービスは既定で有効、2025-09-05 から対象サービスで有効化）** | 可用性のため有効のままにし、根本対策で解決する | 日中でも自動でタスクを入れ替える → current が張り替わる | 無効化は可用性とのトレードオフ |
| **Fargate タスク退役の時間帯** | EC2 イベントウィンドウ（2025-12-18〜）で退役の時間帯を 0 時帯以外に | 退役は新旧の並走を伴うため、0 時にかからないようにできる | 指定しない場合は退役日以降の任意の時刻 |
| **コンテナ再起動ポリシー（restartPolicy、2024-08〜）** | 必要に応じて有効化 | taskid 方式では同じディレクトリを再利用し、起動直後のローテーション（前日以前の server.log を日付付きに）が正しく働く | random 方式では再起動ごとに新しいディレクトリ |
| **タイムゾーン（TZ=Asia/Tokyo または -Duser.timezone=Asia/Tokyo）** | 日本時間の 0 時で区切るなら明示する | 0 時の判定とファイル名の日付は JVM のタイムゾーン。コンテナ既定は UTC（JST 9:00 にローテーション） | 変更するとローテーション時刻が 9 時間ずれるので周知が必要 |
| **グレースフル停止（LAUNCH_JBOSS_IN_BACKGROUND=true）** | 設定する（公式 WildFly イメージは設定済み） | standalone.sh が SIGTERM を JVM に中継し、JBoss が停止処理と停止ログを書いてから終わる。未設定だと PID 1 の sh が SIGTERM を受けても JVM に届かず、stopTimeout 後に SIGKILL される | initProcessEnabled=true（tini）はゾンビ回収用で、単独では代わりにならない（前面実行の standalone.sh が先に終了し JVM は強制終了される）。修正前の実装では停止ログが 0 時以降のローテーションの引き金にもなった（修正後は無害） |
| **Fargate タスク退役の起動順序** | maximumPercent=200（既定）のままでよい | 公式: 既定では新タスクを起動して RUNNING を待ってから旧タスクを退役（＝並走）。maximumPercent=100 なら先に停止 | 退役待ち期間は既定 7 日（14 日に変更可）。イベントウィンドウで時間帯を指定可能 |

### 設定例

**サービスとターゲットグループ（AWS CLI）**

```bash
aws ecs update-service --cluster <cluster> --service <service> \
  --deployment-configuration '{
    "minimumHealthyPercent": 100,
    "maximumPercent": 200,
    "deploymentCircuitBreaker": { "enable": true, "rollback": true }
  }'

# 早期成功判定を使う場合は BLOCKING (DEFERRED は旧タスクを最大 2 週間残し得る)
#   "earlySuccessCriteria": { "enable": true, "healthyPercent": 100, "sourceServiceRevisionCleanup": "BLOCKING" }

aws elbv2 modify-target-group-attributes --target-group-arn <tg-arn> \
  --attributes Key=deregistration_delay.timeout_seconds,Value=60
```

**タスク定義（抜粋。LOG_ID_SOURCE と JBOSS_LOG_PIN は既定値なので省略可。LAUNCH_JBOSS_IN_BACKGROUND はベースイメージで設定済みなら不要）**

```json
"containerDefinitions": [{
  "name": "intra-web-front",
  "readonlyRootFilesystem": true,
  "stopTimeout": 60,
  "environment": [
    { "name": "TZ",                          "value": "Asia/Tokyo" },
    { "name": "LAUNCH_JBOSS_IN_BACKGROUND",  "value": "true" },
    { "name": "LOG_ID_SOURCE",               "value": "random" },
    { "name": "JBOSS_LOG_PIN",               "value": "on" }
  ]
}]
```

---

## 10. 実装内容（リポジトリの変更点）

> **やさしく言うと:** エントリポイントが JBoss に『あなたの机はここ』と実体の住所を渡すようにし、古いタスク ID 方式も同じ仕組みに入れました。

| ファイル | 変更内容 |
|---|---|
| **docker/base/entrypoint.sh** | ①「3-B. JBoss のログ出力先を実体パスへ固定（pin）」を追加: 自分のディレクトリを current を経由せず解決し、JBOSS_LOG_DIR を export、CMD が eap（本番の起動方式）か standalone.sh なら -Djboss.server.log.dir=\<実体パス\> を standalone.sh のコマンド直後に付ける、logging.properties に残った current 経由・前回 LOG_ID のパスを揃える。共有の置き場（standalone/log・mid/ 配下）を指す明示指定は pin で上書きする。②LOG_ID_SOURCE（random／taskid）を追加し、旧タスク ID 方式を統合（メタデータ v4 から TaskARN を取得・3 回まで再試行・英数字とハイフン以外は拒否・取得できなければ random にフォールバック）。③事前検証を「自分の実体ディレクトリに書けるか」に変更し、standalone/log が別タスクを指していても異常扱いしない（並行起動では正常）。④【2026-09-27 追記】最後に本番と同じ分岐（CMD が eap なら standalone.sh -b 0.0.0.0 -bmanagement 0.0.0.0 -c "${SERVER_CONFIG}" … ${JBOSS_SERVER_OPTS}、それ以外は exec "$@"）を置いた（10-1）。⑤【2026-09-28 追記】gc.log と access_log.log について、共有の置き場を指す明示指定（JAVA_OPTS・JAVA_TOOL_OPTIONS・JDK_JAVA_OPTIONS の -Xlog／-Xloggc のパス、standalone.xml の access-log の directory／relative-to）を実体パス・${jboss.server.log.dir} へ揃える。-Djboss.server.log.dir の判定も同じ関数（shared_log_rest）にまとめた（10-2）。 |
| **docker/base/entrypoint.taskid.sh** | 別実装をやめ、LOG_ID_SOURCE=taskid を既定にして efs-entrypoint.sh を呼ぶ互換ラッパーにした（設定復元・fail-fast・pin の移植漏れを構造的に無くす）。自分自身を呼ぶ誤設定は FATAL で停止 |
| **docker/base/Dockerfile** | efs-entrypoint.sh と efs-entrypoint-taskid.sh の両方をイメージに入れる（CRLF 除去も両方） |
| **docker/front/Dockerfile、docker/back/Dockerfile** | コメントを実態に合わせた（リンクは入口として残し、JBoss は実体パスへ書く）。リンクの作り方は変更なし |
| **docs/LOG_ROTATION.md（新規）** | 本書（Markdown 版） |
| **test/rotation/（新規・検証専用）** | 7 章の再現・回帰試験スクリプト（WildFly を使った疑似 EAP、S1／S2／S2r ほか）。JBOSS_LOG_PIN=on／off で修正後と旧挙動を比べられる。本番イメージには含めない。【2026-09-28 追記】検証用 WAR に、GC を起こす・GC ログを今すぐ回す gc.jsp を追加 |
| **test/local/（2026-09-27 追加・検証専用）** | Docker を使わない試験。【2026-09-28 追記】entrypoint_test.sh に gc.log・access-log の試験（[16]〜[17h]）、rotation_local.sh に GC_LOG=true（EAP の既定）・T_ACCESS_LOG・T_JAVA_OPTS_GC・T_EP と G1 シナリオ、gc.log・access_log の記録を追加（10-2 (5)） |
| **docs/DESIGN.md、REJECTED_ALTERNATIVES.md、TROUBLESHOOTING.md** | current の位置づけ、6 章 1 の評価の訂正、案 C（jboss.server.log.dir）を A'／A と組み合わせて採用、切り分け手順を追記 |

### 環境変数

| 変数 | 既定 | 意味 |
|---|---|---|
| **LOG_ID_SOURCE** | random | random: 起動時刻-ランダム8桁（ECS メタデータに依存しない）／taskid: ECS タスク ID（describe-tasks・CloudWatch と突合せしやすい。取得失敗時は random） |
| **JBOSS_LOG_PIN** | on | on: JBoss の書き込み先を mid/\<LOG_ID\> の実体パスへ固定／off: 従来どおり current 経由（切り分け・再現試験用。本番では使わない） |
| **JBOSS_LOG_DIR（エントリポイントが export）** | ― | standalone.sh が -Dorg.jboss.boot.log.file と gc.log の出力先に使う。CMD が eap／standalone.sh 以外のラッパーの場合は、ラッパーから -Djboss.server.log.dir="$JBOSS_LOG_DIR" を渡す |
| **CONFIG_SEED_MODE** | overwrite | 従来どおり |
| **SERVER_CONFIG**（2026-09-27 追記） | standalone.xml（base の ENV） | CMD=eap のとき standalone.sh -c に渡す設定ファイル名（本番の値に合わせる）。未設定なら current を触る前に FATAL |
| **EXTRASLB_TRUSTSTORE_PATH／_PASSWORD／_TYPE、JBOSS_SERVER_OPTS**（2026-09-27 追記） | TYPE だけ JKS（base の ENV）、他は空 | CMD=eap のとき本番と同じく -Djavax.net.ssl.truststore／trustStorePassword／trustStoreType と追加の引数（空白区切り）として渡す。パスワードは起動ログで **** に伏せる。TYPE が空だと WARN（10-1） |
| **JBOSS_CONFIG_FILE** | SERVER_CONFIG（それも無ければ standalone.xml） | 存在を確認する設定ファイル名 |

### タスク ID 方式（旧実装）への切り替え（再ビルド不要）

- 推奨: タスク定義の environment に LOG_ID_SOURCE=taskid を設定する。
- または: タスク定義の entryPoint を ["/usr/local/bin/efs-entrypoint-taskid.sh"] にする。【2026-09-27 追記】このときは command に ["eap"] も指定する（entryPoint を上書きすると Docker／ECS はイメージの CMD を引き継がない。起動コマンドが空だとエントリポイントは current を触る前に FATAL で止まる）。
- どちらでも configuration の復元・fail-fast・実体パスへの固定が必ず効く（旧ファイルで必要だった「復元ブロックの移植」は不要になった）。

### 修正後のエントリポイントの流れ

**docker/base/entrypoint.sh の処理順**

```
0. umask 002・診断ヘルパー
1. configuration の復元 (seed → configuration)            … 従来どおり
2. アプリログ用ディレクトリ作成                           … 従来どおり
3. LOG_ID の決定 (random: 起動時刻-ランダム8桁 / taskid: ECS タスク ID)
   mkdir mid/<LOG_ID> → ln -sfn <LOG_ID> mid/current     … current は「最後に起動したタスク」の目印
3-B. pin: LOG_OWN=$(cd mid/<LOG_ID> && pwd -P)            … current を経由しない実体パス
   export JBOSS_LOG_DIR=$LOG_OWN
   logging.properties の fileName を $LOG_OWN に揃える
   JAVA_OPTS 等の -Xlog／-Xloggc と standalone.xml の access-log が共有の置き場を指していれば揃える  … 2026-09-28 追記 (10-2)
   PIN_OPT=-Djboss.server.log.dir=$LOG_OWN                 … 共有の置き場を指す明示指定は上書き
4. 書き込み検証 ($LOG_OWN, tmp, data) → 5. pdf
6. 起動 (本番と同じ分岐。2026-09-27 追記)
   CMD=eap  → exec standalone.sh $PIN_OPT -b 0.0.0.0 -bmanagement 0.0.0.0 -c "$SERVER_CONFIG"
                   -Djavax.net.ssl.truststore=… -Djavax.net.ssl.trustStorePassword=…
                   -Djavax.net.ssl.trustStoreType=… $JBOSS_SERVER_OPTS
                                                          … rename も再 open も自分のディレクトリ
   それ以外 → exec "$@" (CMD が standalone.sh ならコマンド直後に $PIN_OPT)
```

### 起動ログ（CloudWatch）の例

**実機（WildFly 41.0.1）で取得**

```
[efs-entrypoint] configuration を復元しました (mode=overwrite, 12 エントリ)
[efs-entrypoint] JBoss EAP log dir: /mnt/logs/intra-web-front/logs/intra-web/mid/20260926231418-ebbisg5u (LOG_ID_SOURCE=random)
[efs-entrypoint] log pin: JBoss は /mnt/logs/intra-web-front/logs/intra-web/mid/20260926231418-ebbisg5u へ直接書き込みます (current は書き込み経路に使いません)
[efs-entrypoint] log -> /mnt/logs/intra-web-front/logs/intra-web/mid/20260926231418-ebbisg5u (書き込み可)
[efs-entrypoint] preflight OK. starting: /opt/jboss-eap/bin/standalone.sh -Djboss.server.log.dir=/mnt/logs/intra-web-front/logs/intra-web/mid/20260926231418-ebbisg5u -b 0.0.0.0
```

### 10-1. 本番の起動方式（CMD=eap）と、JAVA_OPTS の -Djboss.server.log.dir の扱い（2026-09-27 追記）

> **やさしく言うと:** 本番は「eap」という合言葉で JBoss を起動していました。しかも起動の前に「ログは /opt/jboss-eap/standalone/log に書いてね」というメモ（JAVA_OPTS）を渡していました。このメモの住所は、みんなで共有している案内板（current）を通る道順です。最初の修正は「メモがあるなら本人の希望だから」と遠慮して、正しい住所（pin）を渡すのをやめてしまうところでした。今回は「共有の案内板を通る道順のメモ」は本人の希望とは見なさず、正しい住所で上書きするようにしました。メモ自体は消すのがおすすめです。

**(1) 本番の起動方式に合わせた変更**

本番の entrypoint.sh は、最後に次の分岐で JBoss を起動する。

```sh
if [ "$1" = "eap" ]; then
    exec ${JBOSS_HOME}/bin/standalone.sh -b 0.0.0.0 -bmanagement 0.0.0.0 -c "${SERVER_CONFIG}" \
        -Djavax.net.ssl.truststore="${EXTRASLB_TRUSTSTORE_PATH}" \
        -Djavax.net.ssl.trustStorePassword="${EXTRASLB_TRUSTSTORE_PASSWORD}" \
        -Djavax.net.ssl.trustStoreType="${EXTRASLB_TRUSTSTORE_TYPE}" ${JBOSS_SERVER_OPTS}
else
    exec "$@"
fi
```

最初の版の実装は「CMD に standalone.sh を直接書く」前提で、pin も CMD が standalone.sh のときだけ付けていた。本番の CMD=eap では pin が付かない（WARN が出るだけ）ので、次のように直した。

| 項目 | 本番 | 本リポジトリ（修正後） |
|---|---|---|
| 分岐 | 最後に eap／それ以外 | 同じ（entrypoint.sh の 6 章）。eap の起動行を組み立ててから 1 か所で exec する |
| eap の起動行 | 上のとおり | 同じ引数・同じ順序。違いは**コマンド直後に -Djboss.server.log.dir=\<実体パス\>（pin）が付く**ことだけ |
| ${JBOSS_HOME} | 引用符なし | 引用符あり（値が同じなら結果も同じ） |
| ${JBOSS_SERVER_OPTS} | 引用符なし（空白で分割） | 同じ（値の中の引用符は解釈されない） |
| 未設定の変数 | 空の値のまま渡る | 同じ（set -u でも止まらないよう ${VAR:-} で空にする） |
| SERVER_CONFIG が未設定 | -c "" になり JBoss が起動に失敗 | current を触る前に FATAL で止める |
| 起動コマンドが空（entryPoint だけ上書きして command を付け忘れた） | exec "$@" が何もせず exit 0 で終わる | current を触る前に FATAL で止める |
| eap の後ろの引数 | 使わない | 使わない（WARN を出す） |
| 起動行のログ | 無し | preflight OK の行に実際の起動行を出す（パスワード類の値は ****） |
| front／back の CMD | （本番のイメージの定義による） | ["eap"] |

**(2) JAVA_OPTS の -Djboss.server.log.dir=${JBOSS_HOME}/standalone/log は何をしているか**

本番のエントリポイントは、pin の処理より前に JAVA_OPTS へこの指定を入れている。

| 読む側 | 何に使うか | この指定があるとどうなるか | 実機（WildFly 26.1.3、pin なし） |
|---|---|---|---|
| standalone.sh | JBOSS_LOG_DIR（ブートログ・gc.log の出力先） | readlink -m で解決した「その瞬間の current の先」になる | -Dorg.jboss.boot.log.file=mid/\<B の ID\>/server.log |
| JBoss 本体（ServerEnvironment） | jboss.server.log.dir（FILE ハンドラの relative-to、audit.log など） | リンクを解決しない /opt/jboss-eap/standalone/log のまま入る。**JBoss の既定値（jboss.server.base.dir/log）と同じ** | CLI の :resolve-expression が …/opt/jboss-eap/standalone/log を返した |
| standalone.conf | JAVA_OPTS が空のときだけ、既定の JAVA_OPTS（ヒープサイズなど）を入れる | JAVA_OPTS が空でなくなるので既定値は入らない | 「JAVA_OPTS already set in environment; overriding default settings with values: …」が出る |

→ **この指定は日付変更時の事故を防がない。** 日付変更時の rename と再 open は、JBoss 本体が /opt/jboss-eap/standalone/log（＝current 経由）のパス文字列で行う。本番と同じ構成（eap ＋ この指定、pin なし）で実機を動かすと、ご報告の症状がそのまま再現した（(5)）。

**(3) 最初の版の実装との関係（重要）**

最初の版は「-Djboss.server.log.dir が引数か JAVA_OPTS で明示されていれば、運用者の意図を優先して pin しない」だった。本番はこの指定を JAVA_OPTS に入れているので、**最初の版をそのまま本番へ入れると pin が一切効かず、修正が無効になる**（WARN が 2 行出るだけ）。そこで判定を次のように変えた。

| -Djboss.server.log.dir の値 | 例 | 扱い |
|---|---|---|
| イメージに焼いた入口リンク（その配下を含む。引用符・末尾の / は無視） | ${JBOSS_HOME}/standalone/log | **pin で上書き**（note 行に出どころと値を出す） |
| 実体が mid/ の配下になるパス | …/mid/current、…/mid/\<他タスクの ID\> | **pin で上書き** |
| それ以外 | /var/log/jboss、存在しないパス | 運用者の指定として尊重する（pin しない。WARN を出す） |

上書きのしかた:

- JAVA_OPTS の値は書き換えない。standalone.sh は「JAVA_OPTS → 起動引数」の順に読んで最後の値を JBOSS_LOG_DIR にし、JBoss 本体（org.jboss.as.server.Main）も起動引数の -D でシステムプロパティを上書きする。したがって**起動引数の pin が勝つ**（WildFly Core 15.0.1〔EAP 7.4 系〕・18.1.2〔WildFly 26〕・main のソースで確認し、実機でも確認した。(5)）。
- 起動引数（CMD や JBOSS_SERVER_OPTS）にある共有の指定は取り除く。起動引数の中では後ろの指定が勝つため、残すと pin より優先されてしまう。

**(4) この指定は削除すべきか、残したまま動かすべきか**

| 案 | 内容 | 良い点 | 注意点 | 評価 |
|---|---|---|---|---|
| 1. 本番の JAVA_OPTS から削除する | ログの出力先は pin だけで決める | JVM 引数の -Djboss.server.log.dir が 1 つになり、ps や ECS Exec で見える値が実際の出力先と一致する。削除する値は既定値と同じなので、pin を切った（JBOSS_LOG_PIN=off）ときの動きも変わらない | 削除して JAVA_OPTS が空になると、standalone.conf の既定の JAVA_OPTS（ヒープサイズ・Metaspace など）が効き始める。削除の前に確認が必要（下記） | **◎ 推奨** |
| 2. 残したままにする | エントリポイントが pin で上書きする（今回の実装がこの状態でも動く） | 本番の JAVA_OPTS に触らずに修正を入れられる（段階的に移行できる） | JVM 引数に値が 2 つ並ぶ（前はリンクのパス、後ろが実体パス）ので紛らわしい。調査のときに「リンクのパスに書いている」と読み違えやすい | ○ 移行期間は可 |
| 3. エントリポイントが JAVA_OPTS の値を書き換える | JAVA_OPTS の中の値を実体パスへ置き換える | JVM 引数の値が 1 つにそろう | JAVA_OPTS は引用符なども入る自由な文字列で、機械的な置き換えは他の指定を壊す恐れがある。起動引数で確実に上書きできるので必要ない | × 採用しない |

**結論:** 実装は「残したままでも動く」ようにした（案 2 の状態でも事故は起きないことを (5) で確認）。そのうえで、**本番の JAVA_OPTS からは削除することを推奨する（案 1）**。

削除の手順:

1. 修正したエントリポイントのイメージをデプロイする（この時点では JAVA_OPTS はそのまま）。CloudWatch に log pin 行と note 行が出ること、ECS Exec で見た fd が mid/\<自分の LOG_ID\>/server.log であることを確かめる（11 章）。
2. 次のリリースで JAVA_OPTS から -Djboss.server.log.dir を削除する。その前に、今の起動ログにある standalone.conf の行を確認する。
   - 「JAVA_OPTS already set in environment; overriding default settings with values: …」の値が -Djboss.server.log.dir だけ → 削除すると JAVA_OPTS が空になり、standalone.conf の既定値が入るようになる（ヒープサイズなどが変わる）。今の動きを保つなら、必要な値（-Xmx など）を JAVA_OPTS に明示してから消す。
   - 他の指定もある → 削除しても standalone.conf の扱いは変わらない。
   - 参考: WildFly Core 15.0.1 の standalone.conf の既定は -Xms64m -Xmx512m -XX:MetaspaceSize=96M -XX:MaxMetaspaceSize=256m -Djava.net.preferIPv4Stack=true -Djboss.modules.system.pkgs=… -Djava.awt.headless=true。JBoss EAP の値は、製品の bin/standalone.conf で確認する。
3. 削除した後は note 行が出なくなり、JVM 引数の -Djboss.server.log.dir は実体パスの 1 つだけになる。

**(5) 実機確認（WildFly 26.1.3 ≒ EAP 7.4、Temurin JRE 11.0.32.1、2026-09-27）**

test/local/rotation_local.sh の S1（A が 0 時をまたいで稼働 → 0 時後に B が起動 → A を SIGTERM で停止）を、本番と同じ起動方式（T_CMD=eap）で実行した。「jboss.server.log.dir」の列は、JBoss 本体に CLI（:resolve-expression）で問い合わせた実際の値。

| 構成 | jboss.server.log.dir | JVM 引数 | A 停止後の B の fd | mid/ の最終状態 | 判定 |
|---|---|---|---|---|---|
| eap ＋ JAVA_OPTS に指定あり ＋ pin あり（今回の実装・案 2） | A・B とも mid/\<自分の ID\> | -Djboss.server.log.dir が 2 つ（前: JAVA_OPTS 由来のリンクのパス、後: pin）。-Dorg.jboss.boot.log.file=mid/\<B\>/server.log | server.log のまま | A: server.log.2026-09-26（9/26 の起動・TICK）と server.log（停止ログ）。B: server.log（9/27 の起動・TICK すべて） | **解消** |
| eap ＋ 指定なし ＋ pin あり（案 1＝推奨） | A・B とも mid/\<自分の ID\> | -Djboss.server.log.dir は pin の 1 つだけ。-Dorg.jboss.boot.log.file=mid/\<B\>/server.log | server.log のまま | A: server.log.2026-09-26（9/26 の起動・TICK）と server.log（停止ログ）。B: server.log（9/27 の起動・TICK すべて） | **解消** |
| eap ＋ JAVA_OPTS に指定あり ＋ pin なし（本番の現状） | A・B とも …/opt/jboss-eap/standalone/log（リンクのまま） | -Djboss.server.log.dir=…/standalone/log の 1 つ。-Dorg.jboss.boot.log.file=mid/\<B\>/server.log | **server.log.2026-09-26** | A: server.log（9/26 分のまま改名されない）。B: server.log（**A の停止ログ**）と server.log.2026-09-26（**B の 9/27 分すべて**） | **再現** |

**(6) 起動行の javax.net.ssl.* について（本修正の対象外・本番で要確認）**

起動行は本番のものをそのまま使っているが、実機で次のことが分かった（WildFly 26.1.3 ＋ JRE 11。JDK の cacerts は JKS 形式・CA 118 件）。

| ケース | 起動 | javax.net.ssl.trustStore（JVM が読む名前） | JVM 既定の TrustManager |
|---|---|---|---|
| 本番と同じ綴り（小文字の truststore）、パスワード changeit、型 JKS | 正常 | null（小文字の truststore は別の名前のプロパティとして入るだけ） | CA 118 件＝**JDK の cacerts のまま（独自のトラストストアは使われない）** |
| 同上で、パスワードが changeit 以外 | **エラー付き（WFLYSRV0026）・アプリが 404** | null | 失敗: Keystore was tampered with, or password was incorrect（本番のパスワードが cacerts に使われるため） |
| 大文字の trustStore も渡した場合 | 正常 | 独自のトラストストア | CA 1 件＝独自のトラストストア |
| EXTRASLB_* が未設定（空の値） | **エラー付き・アプリが 404** | null | 失敗: KeyStore " not found"（型が空のため） |

- Java のシステムプロパティは大文字と小文字を区別する。JSSE が読むのは javax.net.ssl.trustStore で、-Djavax.net.ssl.truststore は使われない。本番の行がこのとおりなら、**EXTRASLB_TRUSTSTORE_PATH の独自トラストストアは使われておらず**、パスワードと型だけが JDK の cacerts に対して使われている。
- パスワードが cacerts と合わない、または型が空だと、JVM 既定の TrustManager を作れない。WildFly 26 では HTTPS 用の SSL コンテキスト（applicationSSC）が起動に失敗し、それに依存する Web のサービスも止まってアプリが 404 になった。JBoss の構成によっては起動時には失敗せず、アプリが JVM 既定の SSLContext で外部へ HTTPS 接続するときに初めて失敗する（EAP 7.4 の実機では未確認）。
- 本リポジトリの対応: 綴りは本番のままにした。勝手に直すと、今まで使われていなかった独自トラストストアが急に使われ始め、cacerts にしか無い CA の接続先へ TLS で接続できなくなる恐れがあるため。EXTRASLB_TRUSTSTORE_TYPE が空のときは WARN を出し、base の Dockerfile に既定値 JKS を置いた（JDK 9 以降の JKS 型は、keystore.type.compat=true の既定により PKCS12 形式の cacerts も読める）。
- **本番で確認してほしいこと:** (a) 実際の起動行が trustStore（大文字 S）か truststore（小文字）か。(b) 小文字なら、独自トラストストアが必要な接続先へ本当に接続できているか（cacerts の CA だけで足りているのか）。(c) EXTRASLB_TRUSTSTORE_PASSWORD が changeit 以外なら、起動ログの ERROR（SSL コンテキスト）や、外部への HTTPS 接続のエラーが出ていないか。直す場合は -Djavax.net.ssl.trustStore に変え、独自トラストストアに必要な CA（cacerts から引き継ぐ分を含む）がそろっていることを確かめてから切り替える。

### 10-2. gc.log と access_log.log にも同じ対策が要るか（2026-09-28 追記）

> **やさしく言うと:** ノートを片付ける係は、server.log のほかにも 2 人いました。GC ログ係（gc.log）とアクセスログ係（access_log.log）です。2 人とも片付けのときは案内板（current）を見て道順でノートを探すので、server.log と同じ事故が起きます。いつもの書き方なら、server.log のために教えた「本当の住所（pin）」が 2 人にもそのまま効きます。ただし「この道順で行け」と直接書いたメモ（JAVA_OPTS の -Xlog や standalone.xml の directory）を持たせていると、住所を教えても効きません。そこで、そのメモの道順も本当の住所へ書き換えるようにしました。

調査報告書は `JBossEAP_gclog_accesslog_rotation_検討.md`／`.xlsx`（このリポジトリを管理しているフォルダの直下）。ここでは要点と実装を書く。

**(1) 結論**

| 対象 | だれが・いつ・どうやって片付けるか | 本番の現状（pin なし。JAVA_OPTS に -Djboss.server.log.dir=${JBOSS_HOME}/standalone/log） | 2026-09-27 までの実装（pin あり） | 追加実装 |
|---|---|---|---|---|
| **gc.log** | JVM（HotSpot）が、自分の書いた量が filesize（EAP の既定 3MB）に達するたびに「閉じる → パス名で gc.log.N を削除 → パス名で gc.log を gc.log.N へ rename → パス名で開き直す」。0 時とは関係なく起きる | **GC ログの明示が無ければ起きない（偶然）**。standalone.sh が JAVA_OPTS の -Djboss.server.log.dir を readlink -m で解決し、起動した瞬間の current の先（＝自分の mid/\<ID\>）を -Xlog の file= に入れるため（実機で確認）。この JAVA_OPTS の指定を消して pin も無いと起きる。**【2026-09-29 確認】本番の JAVA_OPTS には -Xlog／-Xloggc の明示があるので、この偶然は働かない**（standalone.sh は自分の指定を作らない）。出力先が standalone/log の下なら**起きる**（下の gc.log の表の最終行。実機の「pin あり＋明示」〔2026-09-27 版〕と同じ条件で再現済み） | 起きない（JBOSS_LOG_DIR と pin から、実体パスの file= ができる。実機で確認） | **本番には必要**（2026-09-29 確認: JAVA_OPTS に明示あり）。JAVA_OPTS（や JAVA_TOOL_OPTIONS／JDK_JAVA_OPTIONS）で -Xlog／-Xloggc の出力先を共有の置き場に明示していると、pin があっても起きる（実機で再現。他タスクの gc.log を削除する）。→ そのパス部分だけを実体パスへ書き換える |
| **access_log.log** | Undertow が、日付が変わった（JVM のタイムゾーン）後の最初のリクエストで「閉じる → パス名で access_log.log を access_log.\<日付\>.log へ rename（同名があれば -1、-2 …）→ パス名で開き直す」。ファイルは最初のリクエストのときに初めて開く | **起きる（server.log と同じ症状）**。directory の既定 ${jboss.server.log.dir} が /opt/jboss-eap/standalone/log（リンクのまま）になるため。さらに「最初のリクエストで開く」ので、起動後にまだリクエストを受けていないタスクは、別タスクが起動した後だと日付に関係なく他タスクの access_log.log に書き始める（どちらも実機で再現） | 起きない（directory が既定・${jboss.server.log.dir}…・relative-to="jboss.server.log.dir" なら。実機で確認） | **本番では働かない（備え）**。本番の access-log には directory の指定が無い（2026-09-29 確認）ので、pin だけで直る。directory を絶対パス（/opt/jboss-eap/standalone/log）や ${jboss.server.base.dir}/log、relative-to="jboss.server.base.dir" などで書いていると、pin があっても起きる（実機で再現）。→ directory を ${jboss.server.log.dir}\<その下\> へ書き換える |

**まとめ:** 既定の書き方なら、2026-09-27 までの実装（pin）で gc.log も access_log.log も自分のディレクトリに出る。本番の現状（pin なし）では、access_log.log に server.log と同じ事故が起きている。gc.log は、JAVA_OPTS に GC ログの明示が無ければ JAVA_OPTS の -Djboss.server.log.dir のおかげで偶然起きないが、**本番には明示がある（2026-09-29 確認）ので、その出力先が standalone/log の下なら起きる**。pin を素通りする「明示の書き方」は、エントリポイントがそれも実体パスへ揃える（本番の gc.log はこれで直る。本番の access-log は directory の指定が無いので pin だけで直る）。

**(2) gc.log の仕組み**

- **出すかどうか**: JBoss EAP の bin/standalone.conf は「GC_LOG が未設定なら true」にする（EAP 7.4.25 の配布物〔Red Hat の Maven リポジトリの wildfly-ee-galleon-pack 7.4.25.GA-redhat-00001〕と、EAP 8.0／8.1 のコア〔wildfly-core-galleon-pack 21.0.20／27.1.15.Final-redhat-00001〕で確認）。Red Hat の文書も「standalone サーバでは GC ログが既定で有効。GC_LOG=false で無効。3MB ずつ最大 5 ファイルで回す」と説明している。アップストリームの WildFly はこの行がコメントで、既定では出さない。

```sh
# JBoss EAP 7.4 の bin/standalone.conf の末尾
# enable garbage collection logging if not set in environment differently
if [ "x$GC_LOG" = "x" ]; then
   GC_LOG="true"
else
   echo "GC_LOG set in environment to $GC_LOG"
fi
```

- **出し方**: standalone.sh（EAP 7.4.25 のものは WildFly Core 15.0.46 と同一）は、JAVA_OPTS に GC ログの指定が無いときだけ、前回の gc.log\* を backupgc.log\* へ退避してから次の指定を足す。JAVA_OPTS に -Xlog:gc か -Xloggc があれば、**自分の指定は足さずに JAVA_OPTS の指定をそのまま使う**。

```sh
NO_GC_LOG_ROTATE=`echo $JAVA_OPTS | $GREP "\-Xlog\:\?gc"`       # -Xlog:gc / -Xloggc があれば足さない
if [ "x$NO_GC_LOG_ROTATE" = "x" ]; then
    mv -f "$JBOSS_LOG_DIR/gc.log" "$JBOSS_LOG_DIR/backupgc.log"    # gc.log.0〜4 も同様に退避
    # JDK 9 以降
    TMP_PARAM="-Xlog:gc*:file=\"$JBOSS_LOG_DIR/gc.log\":time,uptimemillis:filecount=5,filesize=3M"
    # JDK 8: -verbose:gc -Xloggc:"$JBOSS_LOG_DIR/gc.log" … -XX:+UseGCLogFileRotation -XX:NumberOfGCLogFiles=5 -XX:GCLogFileSize=3M
```

- **JBOSS_LOG_DIR の決まり方**（4-4 と同じ）: -Djboss.server.log.dir が JAVA_OPTS か起動引数にあれば、最後のものを readlink -m で解決した値。無ければ環境変数 JBOSS_LOG_DIR。それも無ければ $JBOSS_BASE_DIR/log（リンクのまま＝current 経由）。

| 構成 | -Xlog の file= | ローテーションの行き先 |
|---|---|---|
| pin あり（2026-09-27 からの実装） | mid/\<自分の ID\>/gc.log（実体パス） | 自分のディレクトリ |
| 本番の現状（pin なし、JAVA_OPTS に -Djboss.server.log.dir=…/standalone/log） | mid/\<起動した瞬間の current の先\>/gc.log（readlink -m で解決済み） | 自分のディレクトリ（起動のその瞬間に別タスクが current を張り替えた場合だけ他タスク） |
| pin なし、JAVA_OPTS の指定も無し | /opt/jboss-eap/standalone/log/gc.log（リンクのまま） | その瞬間の current の先（最後に起動したタスク） |
| JAVA_OPTS に -Xlog:gc*:file=/opt/jboss-eap/standalone/log/gc.log などを明示（pin の有無に関係なく） | 明示したまま（standalone.sh は自分の指定を足さない） | その瞬間の current の先 |

> **【2026-09-29 確認】** 本番の JAVA_OPTS には -Xlog／-Xloggc の明示があるので、本番の現状は表の**最終行**にあたる（2 行目の「偶然」は働かない）。本番の JVM（ubi8/openjdk-11）では、-Xloggc も -Xlog と同じ統合ロギングに置き換えられ、filecount／filesize を書かなければ 5 ファイル × 20MB で回す（JDK 11 の arguments.cpp〔-Xloggc の処理〕と logFileOutput.hpp〔DefaultFileCount＝5、DefaultFileSize＝20M〕で確認）。JVM の起動時にも、同じ名前のファイルがあればパス名で gc.log.N へ退避する。

- **JVM のローテーションの手順**（HotSpot の LogFileOutput。JDK 11u と 21u で同じ）:

```cpp
void LogFileOutput::rotate() {
  fclose(_stream);                                // ① 自分のファイルを閉じる
  archive();                                      // ② 下の 2 つ
  _stream = os::fopen(_file_name, FileOpenMode);  // ③ 同じ「パス名」で開き直す（追記モード）
  _current_size = 0; increment_file_count();      //    次は gc.log.(N+1)。5 番目の次は 0 に戻る
}
void LogFileOutput::archive() {                   // _archive_name = "<file>.<N>"
  remove(_archive_name);                          // ②-1 同じ番号の古いファイルを「パス名で」削除
  rename(_file_name, _archive_name);              // ②-2 gc.log を gc.log.N へ「パス名で」改名
}
```

- きっかけは、その JVM が書いた量（JVM ごとの数え方。ファイルの実際の大きさではない）が filesize に達したとき。JVM の起動時にも、既存の gc.log があれば gc.log.N へ退避する（JVM だけの再起動＝exit 10 でも起きる）。
- パスが current を辿ると: A が回すと、B の現役 gc.log が gc.log.N に改名され（B は気付かず書き続ける）、A は B のディレクトリに新しい gc.log を作って書く。続いて B が回すと、B は自分が書いていたファイル（いまの名前は gc.log.N）を ②-1 で**パス名で削除してしまう**。B の GC ログはどのファイルにも残らない（実機で確認）。
- 0 時とは関係なく、各 JVM が 3MB 書くたびに起きる。並走するタスクが 2 つ以上あれば、日中でも起きる。

**(3) access_log.log の仕組み**

- **設定**（EAP 7.4.25 の undertow サブシステム〔wildfly-undertow 7.4.25.GA-redhat-00001〕。WildFly の main も同じ）: /subsystem=undertow/server=\*/host=\*/setting=access-log の既定値は directory=${jboss.server.log.dir}、relative-to=なし、prefix=access_log.、suffix=log、rotate=true、pattern=common、use-server-log=false。ファイル名は access_log.log、改名後は access_log.2026-09-27.log。
- **出力先の解決**: AccessLogService は PathManager.resolveRelativePathEntry(directory, relative-to) の結果を Paths.get() するだけで、シンボリックリンクは解決しない。relative-to を付けると「その path の値 + / + directory」になる。jboss.server.log.dir の値は ServerEnvironment が new File(値) のまま使う（4-4・10-1）。→ pin なしでは /opt/jboss-eap/standalone/log/access_log.log（current 経由）。
- **Undertow の DefaultAccessLogReceiver**（EAP 7.4.25 の undertow-core 2.2.40.SP3。main では書き込みの流れが整理されたが、ローテーションの手順は同じ）:

```java
private void writeMessage(final List<String> messages) {
    if (System.currentTimeMillis() > changeOverPoint) {   // 日付が変わった後の最初の書き込み
        doRotate();
    }
    if (writer == null) {                                  // 最初の 1 件目、または改名の直後
        writer = Files.newBufferedWriter(defaultLogFile, UTF_8, APPEND, CREATE);   // ③ パス名で開く
    }
    ...                                                    // 書いて flush
}
private void doRotate() {
    writer.close(); writer = null;                         // ① 自分のファイルを閉じる
    if (!Files.exists(defaultLogFile)) return;             //    パス名で存在確認
    Path newFile = outputDirectory.resolve(logBaseName + currentDateString + "." + logNameSuffix);
    int count = 0;
    while (Files.exists(newFile)) {                        //    同名があれば -1、-2 …（上書きはしない）
        ++count;
        newFile = outputDirectory.resolve(logBaseName + currentDateString + "-" + count + "." + logNameSuffix);
    }
    Files.move(defaultLogFile, newFile);                   // ② パス名で改名
    ... calculateChangeOverPoint();                        //    次の 0 時（JVM の既定のタイムゾーン）
}
```

- server.log との違い: ① 上書き（REPLACE_EXISTING）をしないので、丸ごと消える事故は起きない。代わりに access_log.\<日付\>-1.log のような番号付きの名前ができる。② ファイルを開くのは起動時ではなく最初のリクエストのとき。③ ALB のヘルスチェックも 1 件として書かれるので、ローテーションはほぼ 0 時ちょうどに全タスクで起きる（server.log の「0 時以降の最初のログ」より起きやすい）。
- パスが current を辿ると（S2r：B が先に書く）: B は自分のファイルを正しく access_log.\<前日\>.log に改名して新しい access_log.log を開く。続く A のローテーションが、その B の新しい現役ファイルを access_log.\<前日\>-1.log に改名し、B は当日分をそこへ書き続ける（server.log と同じ症状）。A の当日分は B のディレクトリの access_log.log へ。A 自身の access_log.log は改名されずに残る（実機で確認）。
- 「最初のリクエストで開く」ため、0 時と関係なく、起動後にまだリクエストを受けていないタスクが、別タスクの起動後に初めてリクエストを受けると、そのタスクの access_log.log を開いて書き始める。2 つの JVM が同じファイルに追記することになる（NFS では追記が原子的でない。4-6）。

**(4) 追加実装（entrypoint.sh の 3-B）**

pin を適用するとき（JBOSS_LOG_PIN=on で、mid/ の外を指す -Djboss.server.log.dir の明示が無いとき）に次を行う。対象は、共有の置き場（イメージに焼いた ${JBOSS_HOME}/standalone/log とその下、mid/ とその下。実在するものは物理パスでも判定）を指す指定だけ。

| 対象 | 見る場所 | 書き換えるもの | 書き換えないもの |
|---|---|---|---|
| gc.log | JAVA_OPTS・JAVA_TOOL_OPTIONS・JDK_JAVA_OPTIONS の各字句。-Xlog:\<対象\>:[file=]\<パス\>[:…] と -Xloggc:\<パス\>（引用符付きも） | パス部分だけを ${LOG_OWN}\<共有の置き場より下の残り\>/\<ファイル名\> へ。字句の他の部分と、値全体の他の部分は 1 文字も変えない。下のディレクトリは作る。note 行を出す | 全タスクで共有する EFS 上の場所（EFS_LOG_DIR の直下など）→ WARN のみ。相対パス・stdout／stderr・mid/ の外 → 何もしない。$JBOSS_HOME・${JBOSS_HOME} のような変数を文字のまま含むパス（standalone.sh が起動時に eval で展開するので、JVM には本物のパスが届く）も、エントリポイントでは判定できないので何もしない（note も WARN も出ない。本番の値がこの形なら、エントリポイントかタスク定義で展開済みのパスに直す） |
| gc.log | イメージの standalone.conf（RUN_CONF があればそれ） | ―（読み取り専用のルート FS 上にあり、書き換えられない） | コメント以外の行で -Xlog を含み、standalone/log か /mid/ を含むもの → WARN（$JBOSS_LOG_DIR/gc.log を使う書き方に直す） |
| access_log.log | ${CONF_DIR}/${JBOSS_CONFIG_FILE}（CMD=eap なら SERVER_CONFIG のファイル）の \<access-log …\> 要素（1 行に収まっているもの） | directory が絶対パス・${jboss.server.base.dir}…・${jboss.home.dir}…、または relative-to="jboss.server.base.dir"／"jboss.home.dir" で、共有の置き場を指すもの → directory="${jboss.server.log.dir}\<その下\>" にし、relative-to を外す。note 行を出す | 式（${env.X} など）・全タスク共有の EFS・属性が複数行・relative-to だけで directory が無い → WARN のみ。use-server-log="true"、relative-to="jboss.server.log.dir"／"jboss.server.data.dir" など、既定・${jboss.server.log.dir}… → 何もしない |

- JAVA_OPTS を書き換えるのは、10-1 (4) で「採用しない」とした案 3 と同じ種類の方法だが、GC ログの指定は JVM のオプションなので、-Djboss.server.log.dir のように起動引数で上書きすることができない。そのため、字句の中のパス部分だけを置き換える最小限の書き換えにした。
- standalone.xml は、毎起動 seed から復元される作業用のコピー（CONFIG_SEED_MODE=overwrite）を書き換える。seed（イメージ）は変えない。CONFIG_SEED_MODE=missing／skip で持ち越した standalone.xml でも、2 回目以降は書き換え済みなので何もしない。
- 起動ログの例（本番と同じ CMD=eap・JAVA_OPTS に -Djboss.server.log.dir と -Xlog の明示・access-log の directory が絶対パスの場合。実機）:

```
[efs-entrypoint] log pin: JBoss は /mnt/logs/…/mid/<ID> へ直接書き込みます (current は書き込み経路に使いません)
[efs-entrypoint] note: 共有の置き場 (current 経由) を指す -Djboss.server.log.dir の指定 (JAVA_OPTS: /opt/jboss-eap/standalone/log) は pin で上書きします (docs/LOG_ROTATION.md 10-1)
[efs-entrypoint] note: 共有の置き場を指す GC ログの指定 (JAVA_OPTS: /opt/jboss-eap/standalone/log/gc.log) を /mnt/logs/…/mid/<ID> へ書き換えました (docs/LOG_ROTATION.md 10-2)
[efs-entrypoint] note: access-log (standalone.xml 466 行目) の出力先 directory=/opt/jboss-eap/standalone/log は共有の置き場を指すため、directory=${jboss.server.log.dir} (= /mnt/logs/…/mid/<ID>) に書き換えました (docs/LOG_ROTATION.md 10-2)
```

**(5) 実機確認（WildFly 26.1.3 ≒ EAP 7.4、Temurin JRE 11.0.32.1、2026-09-28）**

test/local/rotation_local.sh に、EAP と同じ GC_LOG=true、access-log の有効化（T_ACCESS_LOG）、GC ログの明示（T_JAVA_OPTS_GC）、GC ログを今すぐ回す検証用 JSP（jcmd の VM.log rotate と同じ処理）、G1 シナリオを足して確かめた。「2026-09-27 版」は修正前（pin はあるが gc.log・access_log.log の書き換えが無い）のエントリポイント。

| シナリオ | 構成 | エントリポイント | 結果 | 確認できたこと |
|---|---|---|---|---|
| G1（0 時と無関係。A 起動 → B 起動 → A が初めてリクエストを受ける → A・B の GC ログを順に回す） | pin なし・JAVA_OPTS の指定なし | ― | 再現 | A は最初のリクエストで B の access_log.log を開き、2 つの JVM が同じファイルに書いた。A が GC ログを回すと B の現役 gc.log が gc.log.0 に改名され、続いて B が回すと B は自分の GC ログ（266 行）を削除した（どこにも残らない）。A の gc.log は A のディレクトリで改名されないまま |
| G1 | 本番の現状（CMD=eap、JAVA_OPTS に -Djboss.server.log.dir、pin なし） | 2026-09-27 版 | gc.log は問題なし・access_log.log は再現 | -Xlog の file= は standalone.sh が解決した mid/\<自分\>/gc.log で、GC ログは各自のディレクトリで回った。access_log.log は A が B のファイルを開いた |
| G1 | pin あり（既定の書き方） | 2026-09-27 版 | 問題なし | gc.log・access_log.log とも各自のディレクトリ。gc.log.0（回す前）と gc.log（回した後）がそろう |
| G1 | pin あり＋JAVA_OPTS に -Xlog:gc*:file=\<JBOSS_HOME\>/standalone/log/gc.log＋access-log の directory が絶対パス（本番と同じ CMD=eap・JAVA_OPTS） | 2026-09-27 版 | 再現 | pin があっても -Xlog は明示のまま（standalone.sh は自分の指定を足さない）で、B の gc.log が改名され、続いて B 自身の GC ログ（276 行）が削除された。access_log.log も A が B のファイルを開いた |
| G1 | 同上 | 今回の版 | 解消 | note 行が 2 つ（GC ログ・access-log）。-Xlog の file= が mid/\<自分\>/gc.log に、standalone.xml の directory が ${jboss.server.log.dir} になり、どちらも各自のディレクトリ |
| G1 | pin あり＋-Xlog の明示＋access-log が relative-to="jboss.server.base.dir" directory="log" | 今回の版 | 解消 | relative-to を外して directory=${jboss.server.log.dir} に書き換え。各自のディレクトリ |
| S2r（A・B が 0 時をまたぐ。B が先にリクエスト） | pin なし・JAVA_OPTS の指定なし | ― | 再現 | B の当日分が access_log.2026-09-27-1.log へ（fd で確認）。A の当日分は B のディレクトリの access_log.log。A の access_log.log は改名されないまま。server.log も同時に再現（B の前日分が消失） |
| S2r | 本番の現状（CMD=eap、JAVA_OPTS に -Djboss.server.log.dir、pin なし） | 2026-09-27 版 | 再現 | 上と同じ結果（本番の現状で access_log.log にも server.log と同じ症状が起きる） |
| S2r | pin あり＋-Xlog の明示＋access-log の directory が絶対パス（本番と同じ CMD=eap・JAVA_OPTS） | 2026-09-27 版 | access_log.log は再現 | server.log は pin で解消しているが、access_log.log は上と同じ（B の当日分が access_log.2026-09-27-1.log へ、A の当日分は B のディレクトリへ） |
| S2r | 同上 | 今回の版 | 解消 | A・B とも自分のディレクトリに access_log.2026-09-27.log（前日分）と access_log.log（当日分）。fd も各自の access_log.log のまま |

WildFly 41.0.1（≒ EAP 8.x）での実機確認は、作業 PC の C: ドライブの空きが 2.7GB まで減った（Windows の pagefile.sys が 9.9GB に拡張された）ため見送った。ソースでは、JDK 21u の LogFileOutput のローテーション手順は JDK 11u と同じ、EAP 8.0／8.1 の standalone.conf（GC_LOG の既定 true）は EAP 7.4 と同じ、standalone.sh の GC ログの部分も実質同じ（正規表現の書き方と -d32／-d64 の扱いだけが違い、「JAVA_OPTS に GC ログの指定があれば足さない」「-Xlog:gc*:file=$JBOSS_LOG_DIR/gc.log … filecount=5,filesize=3M」は同じ）、Undertow の main と WildFly の main の access-log の既定値・改名の手順も同じであることを確認した。

**(6) 確認方法**

```sh
# ECS Exec: JVM が握っている gc.log・access_log.log と、GC ログの起動引数
for p in /proc/[0-9]*; do
  case "$(readlink $p/exe 2>/dev/null)" in
    */java) ls -l $p/fd | grep -E 'gc\.log|access_log'           # mid/<自分の LOG_ID>/ の下であること
            tr '\0' '\n' < $p/cmdline | grep -E '^-Xlog|^-Xloggc' ;;  # file= が実体パスであること
  esac
done
# access-log の設定 (directory が ${jboss.server.log.dir} か、未設定=既定であること)
/opt/jboss-eap/bin/jboss-cli.sh -c --command='/subsystem=undertow/server=default-server/host=default-host/setting=access-log:read-resource'
```

- すでに名前と中身がずれた access_log の洗い出し: `access_log.YYYY-MM-DD[-N].log` の名前の日付と、1 行目の `[27/Sep/2026:…]` の日付を比べる（11 章の server.log の洗い出しと同じ考え方）。

**(7) 運用上の注意**

- JBOSS_LOG_PIN=off のまま、本番の JAVA_OPTS から -Djboss.server.log.dir を消さない。gc.log が current 経由になり、GC ログの改名・削除が始まる（pin=off は切り分け専用）。pin=on（既定）なら、消しても gc.log は実体パスのまま。
- ログ収集ツールの対象は mid/\*/gc.log\*・mid/\*/access_log\* にする（current は他タスクの起動で切り替わる）。
- 同じ理由で、logging サブシステムに自分で足したファイルハンドラも、path を /opt/jboss-eap/standalone/log/… の絶対パスや relative-to="jboss.server.base.dir" + path="log/…" で書いていると current 経由になる。relative-to="jboss.server.log.dir" で書けば pin に乗る（エントリポイントは確認しない。standalone.xml を grep して確かめる）。
- アプリのログ（/webapp/…/logs → EFS の \<Service_Name\> 直下）は、mid/ のような「タスクごとのディレクトリ」が無く、全タスクが同じ場所に書く。アプリがタスク固有でないファイル名で日付ローテーションしていると、同じ種類の事故が起きる（JBoss の設定ではないので本書の対象外。アプリのログ設定を確認すること）。

---

## 11. 確認手順・移行手順・運用

> **やさしく言うと:** 直ったかどうかは『JBoss がどのファイルを手に持っているか』を見れば一目で分かります。

### 修正が効いているかの確認

```bash
# 1) CloudWatch (awslogs) に次の行が出ていること
[efs-entrypoint] log pin: JBoss は /mnt/logs/.../mid/<LOG_ID> へ直接書き込みます
[efs-entrypoint] preflight OK. starting: /opt/jboss-eap/bin/standalone.sh -Djboss.server.log.dir=/mnt/logs/.../mid/<LOG_ID> ...

# 2) ECS Exec で JVM が実際に握っているファイルと起動引数を見る
aws ecs execute-command --cluster <c> --task <t> --container <name> --interactive --command /bin/sh
for p in /proc/[0-9]*; do
  case "$(readlink $p/exe 2>/dev/null)" in
    */java) ls -l $p/fd | grep -E '\.log'                                   # fd -> .../mid/<自分の LOG_ID>/server.log (gc.log・access_log.log も同じディレクトリ)
            tr '\0' '\n' < $p/cmdline | grep -E 'log.dir|boot.log.file' ;;  # どちらも実体パスであること
  esac
done
grep fileName /opt/jboss-eap/standalone/configuration/logging.properties      # 実体パスであること
```

### 移行手順

1. base → front／back の順にイメージを再ビルドする（CI では STRICT_SEED=1）。
2. 日中にデプロイする（修正前のタスクは current 経由で rename するため、0 時をまたいで新旧が並走しないようにする）。
3. 0 時（JVM のタイムゾーン）までに、修正前のリビジョンのタスクがすべて停止したことを確認する（aws ecs describe-services の deployments で旧リビジョンの runningCount=0）。
4. 翌朝、各 mid/\<LOG_ID\>/ に server.log.\<前日\> と server.log が揃い、中身の日付と名前が一致していることを確認する。

### すでに壊れたファイルの見つけ方（名前の日付と中身の最初の日付が違うもの）

```bash
cd /mnt/logs/<Component_name>/logs/<Service_Name>/mid
for f in */server.log.????-??-??; do
  name_date=${f##*.}
  first=$(grep -m1 -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' "$f")
  [ -n "$first" ] && [ "$first" != "$name_date" ] && echo "MISMATCH $f (名前=$name_date, 先頭行=$first)"
done
```

### 運用上の注意

- current は「最後に起動したタスク」の目印。特定タスクのログを見るときは current ではなく mid/\<LOG_ID\>（CloudWatch の preflight 行や ECS Exec の fd で確認）を使う。
- ECS Exec で /opt/jboss-eap/standalone/log を覗くと、自分ではなく最後に起動したタスクのディレクトリが見えることがある（リンクがビルド時固定のため）。
- mid/ 配下は起動ごとに増える。EFS のライフサイクル管理か定期削除で世代管理する（ディレクトリ名の先頭が起動時刻なので並べ替えやすい）。
- ログ収集ツールが mid/current/server.log を読んでいる場合は、mid/*/server.log を対象にする（current は切り替わるため）。

---

## 12. 用語集

> **やさしく言うと:** むずかしい言葉を、ひとことで言い換えます。

| 用語 | ひとことで | もう少し詳しく |
|---|---|---|
| **ファイルディスクリプタ（fd）** | 手に持っているノート | open で得る番号。中身（inode）を直接指し、名前が変わっても同じ中身に書き続ける |
| **inode／NFS ファイルハンドル** | ノートそのもの | ファイルの中身と属性の実体。名前とは別に管理される |
| **パス（ファイル名）** | ノートの名札・道順 | ディレクトリを辿って中身に行き着くための名前。rename で付け替えられる |
| **シンボリックリンク** | 案内板 | 別のパスへの道順を書いた小さなファイル。辿るのは使う瞬間 |
| **current** | 教室に 1 枚の案内板 | EFS 上で全タスクが共有するリンク。最後に起動したタスクが自分のディレクトリへ張り替える |
| **rename** | 名札の付け替え | 中身はそのまま名前だけ変える。同名があれば置き換える（REPLACE_EXISTING） |
| **ログローテーション** | ノートの片付けと交換 | 一定の周期（既定は日）でログファイルを日付付きの名前にして新しいファイルに切り替える |
| **periodic-rotating-file-handler** | 日付でノートを替える係 | JBoss の server.log を書くハンドラ。suffix の書式から周期を決める |
| **suffix** | 日付シールの書式 | 既定 .yyyy-MM-dd。HH を含めると毎時ローテーション |
| **EFS** | みんなの教室 | AWS のマネージド NFS。複数タスクから同時に使える共有ディスク |
| **readonlyRootFilesystem** | 教室の壁に書けない決まり | コンテナのルート FS を読み取り専用にする ECS の設定。リンクはビルド時にしか作れない |
| **ローリングデプロイ** | 少しずつ入れ替える引っ越し | 新しいタスクを起動してから古いタスクを止める。100／200 なら新旧が一時的に並走する |
| **minimumHealthyPercent／maximumPercent** | 最低何人残すか／最大何人まで増やすか | デプロイ中のタスク数の下限と上限（desiredCount に対する割合） |
| **タスクメタデータエンドポイント v4** | タスクの名簿 | コンテナ内から TaskARN（タスク ID）などを取得できる HTTP エンドポイント |
| **pin（固定）** | 住所を直接教える | 本対策。JBoss の書き込み先を current 経由ではなく実体パスに固定すること |

---

## 13. 参考資料（一次情報）

> **やさしく言うと:** 調べるときに見た、元の資料の一覧です。

| 分類 | 資料 | URL |
|---|---|---|
| **ソース** | jboss-logmanager PeriodicRotatingFileHandler（main） | https://github.com/jboss-logging/jboss-logmanager/blob/main/src/main/java/org/jboss/logmanager/handlers/PeriodicRotatingFileHandler.java |
| **ソース** | jboss-logmanager SuffixRotator（Files.move REPLACE_EXISTING） | https://github.com/jboss-logging/jboss-logmanager/blob/main/src/main/java/org/jboss/logmanager/handlers/SuffixRotator.java |
| **ソース** | jboss-logmanager 2.1.19.Final（EAP 7.4／8.x 世代） | https://github.com/jboss-logging/jboss-logmanager/tree/2.1.19.Final |
| **ソース** | WildFly Core standalone.sh（JBOSS_LOG_DIR・readlink -m・exit 10 の再起動ループ） | https://github.com/wildfly/wildfly-core/blob/main/core-feature-pack/galleon-common/src/main/resources/packages/bin.standalone/content/bin/standalone.sh |
| **Red Hat** | JBoss EAP 8.0 Configuration Guide — Logging with JBoss EAP | https://docs.redhat.com/en/documentation/red_hat_jboss_enterprise_application_platform/8.0/html/configuration_guide/logging-with-jboss-eap_default |
| **Red Hat** | JBoss EAP 7.4 Configuration Guide — Logging with JBoss EAP | https://docs.redhat.com/en/documentation/red_hat_jboss_enterprise_application_platform/7.4/html/configuration_guide/logging_with_jboss_eap |
| **AWS** | Deploy Amazon ECS services by replacing tasks（rolling update） | https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-type-ecs.html |
| **AWS** | Complete Amazon ECS rolling deployments early with early success criteria | https://docs.aws.amazon.com/AmazonECS/latest/developerguide/early-success-criteria.html |
| **AWS** | Amazon ECS introduces Early Success Criteria（2026-09） | https://aws.amazon.com/about-aws/whats-new/2026/09/amazon-ecs-deployments-early-success/ |
| **AWS** | Amazon ECS now supports configurable deployment circuit breaker settings（2026-07） | https://aws.amazon.com/about-aws/whats-new/2026/07/amazon-ecs-circuit-breaker-settings/ |
| **AWS** | ECS Deployment Circuit Breaker GA（2020-12） | https://aws.amazon.com/about-aws/whats-new/2020/12/amazon-ecs-announces-the-general-availability-of-ecs-deployment-circuit-breaker/ |
| **AWS** | Amazon ECS enables built-in blue/green deployments（2025-07） | https://aws.amazon.com/about-aws/whats-new/2025/07/amazon-ecs-built-in-blue-green-deployments/ |
| **AWS** | Amazon ECS now supports built-in Linear and Canary deployments（2025-10） | https://aws.amazon.com/about-aws/whats-new/2025/10/amazon-ecs-built-in-linear-canary-deployments |
| **AWS** | Balancing an Amazon ECS service across Availability Zones（AZ リバランス） | https://docs.aws.amazon.com/AmazonECS/latest/developerguide/service-rebalancing.html |
| **AWS** | Amazon ECS provides the ability to restart containers without requiring a task relaunch（2024-08） | https://aws.amazon.com/about-aws/whats-new/2024/08/amazon-ecs-restart-containers-task-relaunch |
| **AWS** | Task retirement and maintenance for AWS Fargate | https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-maintenance.html |
| **AWS** | Amazon ECS weekly event windows for Fargate task retirements（2025-12） | https://aws.amazon.com/about-aws/whats-new/2025/12/ecs-weekly-windows-scheduling-task-retirements-fargate |
| **AWS** | AWS Fargate launches Platform Version 1.4（EFS 対応・メタデータ v4、2020-04） | https://aws.amazon.com/about-aws/whats-new/2020/04/aws-fargate-launches-platform-version-14 |
| **AWS** | How Amazon EFS works（NFSv4.0／4.1） | https://docs.aws.amazon.com/efs/latest/ug/how-it-works.html |
| **Linux** | open(2) man page（O_APPEND と NFS の注意） | https://man7.org/linux/man-pages/man2/open.2.html |
| **考え方** | The Twelve-Factor App — XI. Logs | https://12factor.net/logs |
| **ソース（10-2）** | OpenJDK HotSpot LogFileOutput（-Xlog のファイル出力とローテーション。jdk11u） | https://github.com/openjdk/jdk11u/blob/master/src/hotspot/share/logging/logFileOutput.cpp |
| **ソース（10-2）** | OpenJDK HotSpot LogFileOutput（jdk21u） | https://github.com/openjdk/jdk21u/blob/master/src/hotspot/share/logging/logFileOutput.cpp |
| **ソース（10-2）** | Undertow DefaultAccessLogReceiver（アクセスログのローテーション） | https://github.com/undertow-io/undertow/blob/main/core/src/main/java/io/undertow/server/handlers/accesslog/DefaultAccessLogReceiver.java |
| **ソース（10-2）** | WildFly undertow サブシステム AccessLogDefinition（directory の既定 ${jboss.server.log.dir} など） | https://github.com/wildfly/wildfly/blob/main/undertow/src/main/java/org/wildfly/extension/undertow/AccessLogDefinition.java |
| **配布物（10-2）** | JBoss EAP 7.4 の feature pack（bin/standalone.conf の GC_LOG 既定 true。wildfly-ee-galleon-pack 7.4.25.GA-redhat-00001） | https://maven.repository.redhat.com/ga/org/jboss/eap/wildfly-ee-galleon-pack/ |
| **配布物（10-2）** | JBoss EAP のソース（undertow-core 2.2.40.SP3・wildfly-undertow 7.4.25.GA・wildfly-server 15.0.46 の -sources.jar） | https://maven.repository.redhat.com/ga/ |
| **Red Hat（10-2）** | JBoss EAP 7.4 Configuration Guide — Garbage Collection Logging（既定で有効・GC_LOG=false で無効・3MB×5） | https://docs.redhat.com/en/documentation/red_hat_jboss_enterprise_application_platform/7.4/html/configuration_guide/logging_with_jboss_eap |
| **Red Hat（10-2）** | JBoss EAP 7.4 Performance Tuning Guide — Enabling garbage collection logging | https://docs.redhat.com/en/documentation/red_hat_jboss_enterprise_application_platform/7.4/html/performance_tuning_guide/diagnosing_performance_issues |
