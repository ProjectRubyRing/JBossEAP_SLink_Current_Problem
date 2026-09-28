# JBoss EAP の gc.log と access_log.log にも server.log と同じ対策が要るか — current リンクとローテーションの検討・実機検証・追加実装

| 項目 | 内容 |
|---|---|
| 対象 | ECS_EFS_Dockerfile_Symboliclink_lite（このフォルダで管理している実装。2026-09-27 に server.log の対策〔実体パスへの固定＝pin〕を入れた版。コミット 5e7343c） |
| ご依頼 | server.log に対する実装と同じように、gc.log と Undertow の access_log.log についても実装の追加が必要かを検討し、必要なら実装する |
| 前提構成 | /opt/jboss-eap/standalone/log → /mnt/logs/\<Component_name\>/logs/\<Service_Name\>/mid/current → mid/\<LOG_ID\>（current は全タスク共有で、起動のたびに張り替わる） |
| 結論（一文） | gc.log も access_log.log も server.log と同じ「閉じる → パス名で改名 → パス名で開き直す」でローテーションするので、パスが current を通ると同じ事故が起きる。既定の書き方なら 2026-09-27 の pin で直っている。pin を素通りする明示の書き方（JAVA_OPTS の -Xlog、standalone.xml の access-log の directory）に備えて、エントリポイントがそれも実体パスへ揃えるようにした。本番の JAVA_OPTS には -Xlog／-Xloggc の明示がある（2026-09-29 確認）ので、本番の gc.log にはこの追加が必要（本番の access-log は directory の指定が無いので pin だけで直る） |
| 本番の現状への影響 | access_log.log: server.log と同じ症状が起きている（本番と同じ構成で実機再現）。gc.log: 本番の JAVA_OPTS には -Xlog／-Xloggc の明示がある（2026-09-29 確認）ので、出力先が standalone/log（リンク）の下なら、容量ローテーションのたびに起き得る（明示が無い構成なら、JAVA_OPTS の -Djboss.server.log.dir を standalone.sh が実体パスに解決するため偶然起きない） |
| 検証環境 | WSL（Ubuntu 22.04）で Docker を使わず、WildFly 26.1.3.Final（JBoss EAP 7.4 相当。Undertow 2.2.19、WildFly Core 18.1.2）と Temurin JRE 11.0.32.1 を「ECS タスク相当」の 2 プロセスで起動（共有ディレクトリ＝EFS 役）。ソースは JBoss EAP 7.4.25／8.0／8.1 の配布物と -sources.jar（Red Hat の Maven リポジトリ）、OpenJDK・Undertow・WildFly の GitHub で確認 |
| 作成日 | 2026-09-28 |
| 更新 | 2026-09-29: 本番の設定の確認結果（JAVA_OPTS に -Xlog／-Xloggc の明示あり、access-log の directory の指定なし）を 1 章・3 章・6 章・8 章・9 章・11 章に反映。9-2 の対処の記号を A〜G からア〜キに変更（GitHub の main にあるコンテナ専用リンク方式を「案 B」と呼んでいるため）。pin 方式の一式は、元リポジトリ ProjectRubyRing/ECS_EFS_Dockerfile_Symboliclink_lite の pin_method/ にも置いた（JBossEAP_serverlog_rotation_修正箇所まとめ.md の 14 章） |
| フォント・配色 | Meiryo UI、モノトーン（黒・グレー・白） |

## 目次

- [1. 結論（まずここだけ読めば分かる）](#1-結論まずここだけ読めば分かる) — ノートを片付ける係は server.log のほかにも 2 人いて、同じ事故を起こします。いつもの書き方なら、きのう教えた『本当の住所』がそのまま効きます。
- [2. 小学生にもわかる説明（教室のたとえ話の続き）](#2-小学生にもわかる説明教室のたとえ話の続き) — 日記係・お掃除記録係・受付係の 3 人とも、片付けのときだけ案内板を見て道順でノートを探します。
- [3. 登場の歴史と背景](#3-登場の歴史と背景) — お掃除の記録も来客名簿も、昔から『たまったら名前を変えて新しくする』やり方。コンテナで案内板を共有して初めてぶつかりました。
- [4. 動作原理 — gc.log（JVM の GC ログ）](#4-動作原理--gclogjvm-の-gc-ログ) — ノートが 3MB でいっぱいになるたびに『同じ番号の古いノートを捨てる → 番号シールを貼る → 新しいノート』。どれも道順で探します。
- [5. 動作原理 — access_log.log（Undertow のアクセスログ）](#5-動作原理--access_loglogundertow-のアクセスログ) — 最初のお客さんで名簿を開き、日付が変わって最初のお客さんで『昨日のシールを貼って新しい名簿』。探すのは道順です。
- [6. 本番の構成ではどうなるか（影響の整理）](#6-本番の構成ではどうなるか影響の整理) — 本番では受付係はもう事故を起こしています。お掃除記録係も、自分の道順メモ（-Xlog の明示）を持っているので、道順が案内板を通るなら事故を起こします。
- [7. 動作イメージ（時系列とディレクトリの状態）](#7-動作イメージ時系列とディレクトリの状態) — 時計の順に『だれがどのファイルに書いているか』を並べると、ノートが消える瞬間が見えます。
- [8. 実機検証](#8-実機検証) — 本物の WildFly を 2 つ並べて、GC ログを回し、0 時をまたがせて、どのファイルに何が書かれたかを確かめました。
- [9. 追加実装が必要か（判断）と対処の比較](#9-追加実装が必要か判断と対処の比較) — いつもの書き方なら追加は要りません。でも本番のお掃除記録係は『道順メモ』（-Xlog の明示）を持っていたので、メモを書き直す仕組みが本番にも必要でした。
- [10. 実装内容（リポジトリの変更点）](#10-実装内容リポジトリの変更点) — 朝の準備係（エントリポイント）が、係の道順メモを読んで、案内板を通る道順なら本当の住所に書き直します。
- [11. 確認手順・移行手順・運用](#11-確認手順移行手順運用) — JVM が手に持っているファイルと、起動ログの note 行を見れば、直ったかどうかが分かります。
- [12. 用語集](#12-用語集) — むずかしい言葉を、ひとことで言い換えます。
- [13. 参考資料（一次情報）](#13-参考資料一次情報) — 調べるときに見た、元の資料の一覧です。

---

## 1. 結論（まずここだけ読めば分かる）

> **やさしく言うと:** ノートを片付ける係は server.log のほかにも 2 人いて、同じ事故を起こします。いつもの書き方なら、きのう教えた『本当の住所』がそのまま効きます。住所を無視する『道順メモ』を持っている係のために、メモも書き直すようにしました。

| 項目 | 内容 |
|---|---|
| **gc.log とは** | JVM がガベージコレクション（使わなくなったメモリのお掃除）の記録を書くファイル。JBoss EAP は bin/standalone.conf の既定で GC_LOG=true にし、standalone.sh が -Xlog:gc\*:file=$JBOSS_LOG_DIR/gc.log:…:filecount=5,filesize=3M を JVM に渡す（アップストリームの WildFly は既定で出さない） |
| **gc.log の片付け方** | JVM（HotSpot）が、自分の書いた量が 3MB に達するたびに「閉じる → パス名で gc.log.N を削除 → パス名で gc.log を gc.log.N へ改名 → パス名で開き直す」。JVM の起動時にも既存の gc.log を gc.log.N へ退避する。0 時とは関係なく、いつでも起きる |
| **gc.log で起きること** | パスが current を通ると、A の片付けが B の現役 gc.log を gc.log.N に改名し（B は気付かずに書き続ける）、続く B の片付けは、B が書いていたファイル（いまの名前は gc.log.N）をパス名で削除する。**B の GC ログが丸ごと消える**（実機で確認） |
| **access_log.log とは** | Undertow（JBoss EAP 7 以降の Web サーバ）が、受けた HTTP リクエストを 1 行ずつ書くファイル。standalone.xml の access-log 設定で有効にする。既定の置き場所は ${jboss.server.log.dir}、名前は access_log.log |
| **access_log.log の片付け方** | Undertow が、日付が変わった（JVM のタイムゾーン）後の最初のリクエストで「閉じる → パス名で access_log.log を access_log.\<日付\>.log に改名（同じ名前があれば -1、-2 …）→ パス名で開き直す」。ファイルは起動時ではなく、最初のリクエストのときに初めて開く |
| **access_log.log で起きること** | server.log と同じ症状。新タスクの当日分が access_log.\<前日\>.log や access_log.\<前日\>-1.log という前日付の名前のファイルに書かれ続け、旧タスクの当日分は新タスクのディレクトリに混ざり、旧タスク自身のファイルは改名されない（実機で確認）。上書きはしないので丸ごと消えることはない。さらに「最初のリクエストで開く」ため、0 時と関係なく、別タスクの起動後に初めてリクエストを受けたタスクは、そのタスクのファイルに書き始める（2 つの JVM が同じファイルに追記） |
| **本番の現状（pin なし）** | **access_log.log は起きている**（directory の既定 ${jboss.server.log.dir} がリンクのまま＝current 経由。本番と同じ構成で再現。本番の access-log は directory の指定なし＝この既定のまま〔2026-09-29 確認〕）。**gc.log も起き得る**（2026-09-29 更新）: 本番の JAVA_OPTS には -Xlog／-Xloggc の明示がある。明示があると standalone.sh は自分の指定を作らず、明示のパスをそのまま JVM に渡すので、出力先が standalone/log（リンク）の下なら、容量ローテーションのたびに current を辿る（実機の「pin あり＋明示」〔8-5〕と同じ条件）。明示が無い構成なら、JAVA_OPTS の -Djboss.server.log.dir=${JBOSS_HOME}/standalone/log を standalone.sh が readlink -m で実体パスに解決し、その値で -Xlog を作るので起きない（偶然） |
| **2026-09-27 の実装（pin）の効き目** | 既定の書き方なら、どちらも直っている。gc.log は JBOSS_LOG_DIR と pin から実体パスの -Xlog ができ、access-log の directory ${jboss.server.log.dir} も pin の値（実体パス）になる（実機で確認） |
| **pin が効かない書き方** | ① JAVA_OPTS（や JAVA_TOOL_OPTIONS／JDK_JAVA_OPTIONS）に -Xlog:gc\*:file=/opt/jboss-eap/standalone/log/gc.log のような GC ログの明示がある（standalone.sh は自分の指定を足さず、これをそのまま使う）。② standalone.xml の access-log の directory が /opt/jboss-eap/standalone/log などの絶対パス、${jboss.server.base.dir}/log、relative-to="jboss.server.base.dir" + directory="log" など。どちらも pin があっても事故が起きる（実機で再現） |
| **追加実装（実装済み）** | エントリポイントが pin を適用するときに、① の GC ログのパス部分を mid/\<LOG_ID\> の実体パスへ、② の access-log の directory を ${jboss.server.log.dir}（＝pin の値）へ書き換える。対象は「共有の置き場（standalone/log・mid/ 配下）を指すもの」だけで、書き換えたら起動ログに note 行を出す。判定できない書き方や、全タスクで共有する EFS の場所を指すものには WARN を出す。**本番の gc.log にはこの追加が必要**（明示がある）。本番の access-log には書き換える対象が無い（directory の指定が無いので pin だけで直る） |
| **修正の効果（実機）** | ①② の書き方でも、GC ログの片付けと 0 時の access_log.log の片付けが各自のディレクトリの中だけで行われ、他タスクのファイルに一切触れないことを確認した |
| **本番の確認結果（2026-09-29）と残りの確認** | (a) JAVA_OPTS の -Xlog／-Xloggc の明示: **あり**。(b) seed の standalone.xml の access-log の directory: **指定なし**（既定の ${jboss.server.log.dir}）。(c) GC_LOG: 明示がある本番では、値に関係なく gc.log が出る（GC_LOG は standalone.sh が自分の指定を足すかどうかだけを決める）。**残りの確認:** (a) の正確な値（出力先が standalone/log の下か、$JBOSS_HOME などの変数を文字のまま書いていないか）と、設定している場所（エントリポイント／タスク定義／bin/standalone.conf）。修正版のイメージで起動したときに GC ログの note 行が出れば、書き換えが効いている（11 章） |

> **移行時の注意:** 修正前のイメージのタスクは、修正後のタスクと並んでいる間も current 経由で access_log.log を改名します（server.log と同じ）。切り替えのデプロイは日中に行い、0 時（JVM のタイムゾーン）までに修正前のタスクがすべて止まったことを確認してください。desiredCount が 2 以上なら、本番の access_log.log の事故は毎晩起きているはずです（6 章。11-4 の洗い出しで確かめられます）。gc.log も、明示の出力先が standalone/log の下なら、GC ログが filesize に達するたびに（0 時と無関係に）起き得ます。

---

## 2. 小学生にもわかる説明（教室のたとえ話の続き）

> **やさしく言うと:** 日記係・お掃除記録係・受付係の 3 人とも、片付けのときだけ入口の案内板を見て道順でノートを探します。いつもの係には、きのう渡した本当の住所が効きます。道順メモを持っている係には、メモを書き直してあげます。

### 登場人物（たとえ → 本物）

| たとえ | 本物 | ひとこと |
|---|---|---|
| **教室** | EFS（みんなで使う共有ディスク） | 全タスクが同じ教室を使う |
| **机** | mid/\<起動時刻-ランダム8桁\> などのディレクトリ | タスク（JBoss）ごとに 1 つ |
| **入口の案内板「いまの当番はこの机」** | current シンボリックリンク | 教室に 1 枚。最後に来た子が書き換える |
| **日記係** | server.log を書く JBoss の係 | 夜 0 時に日記を片付ける（きのう直した） |
| **お掃除記録係** | gc.log を書く JVM | 体の中のお掃除（ガベージコレクション）の記録を書く。ノートが 3MB でいっぱいになるたびに片付ける |
| **お掃除ノートの番号シール** | gc.log.0〜gc.log.4 | いっぱいになったノートに順に貼る。5 冊で 1 周して、また 0 番から |
| **受付係** | access_log.log を書く Undertow | お客さん（HTTP リクエスト）が来るたびに、来客名簿に 1 行書く |
| **来客名簿の日付シール** | access_log.2026-09-27.log のような名前 | 日付が変わって最初のお客さんが来たら貼る。同じシールがあれば「-1」を足す |
| **本当の住所** | pin（-Djboss.server.log.dir・JBOSS_LOG_DIR＝mid/\<LOG_ID\> の実体パス） | きのう、係に渡すようにしたもの |
| **道順メモ** | JAVA_OPTS の -Xlog、standalone.xml の access-log の directory | 「案内板を見て行け」と書いてある古いメモ。持っていると、住所よりメモを使ってしまう |
| **朝の準備係** | エントリポイント（efs-entrypoint.sh） | 係に住所を渡し、道順メモを書き直す |

### お話

1. きのう、日記係（server.log）には「あなたの机はここ」と本当の住所を渡しました。夜中に片付けても、よその子の日記に触らなくなりました。では、ほかの係はどうでしょう。
2. お掃除記録係（gc.log）は、ノートが 3MB でいっぱいになると片付けます。手順は「同じ番号シールの古いノートを捨てる → いま書いているノートに番号シールを貼る → 新しいノートを出す」。このとき、案内板を見て机を探します。
3. 生徒 A のお掃除記録係が片付けを始めました。案内板はもう B の机を指しているので、B の係が書いている最中のノートに「0 番」のシールを貼ってしまいます。B の係は、手に持ったノートにそのまま書き続けます。
4. しばらくして、B のお掃除記録係もノートがいっぱいになりました。B の係の頭の中では「次は 0 番」。まず「0 番のシールの古いノートを捨てる」…。それは、B の係がさっきまで書いていたノートです！ B のお掃除の記録は丸ごとゴミ箱へ行ってしまいました。
5. 受付係（access_log.log）は、日付が変わって最初のお客さんが来たときに片付けます。手順は「いまの名簿に昨日の日付シールを貼る → 新しい名簿を出す」。同じシールの名簿がもうあれば「昨日-1」のように番号を足すので、捨てることはしません。でも、案内板を見て探すと、よその子の名簿にシールを貼ってしまい、その子は今日のお客さんを「昨日-1」の名簿に書き続けます。日記係のときと同じ症状です。
6. 受付係には、もうひとつくせがあります。最初のお客さんが来るまで名簿を開きません。朝、A が教室に来て、まだお客さんが来ないうちに B が来て案内板を書き換えると、A の最初のお客さんは B の机の名簿に書かれてしまいます。0 時でなくても起きます。
7. どうすればいい？ いつもの係なら、きのう渡した本当の住所を使ってくれます（お掃除記録係は standalone.sh が JBOSS_LOG_DIR から、受付係は ${jboss.server.log.dir} から場所を決めるので）。困るのは、係が「案内板を見て行け」という道順メモを別に持っている場合です。そのときは住所を渡しても、道順メモのほうを使ってしまいます。
8. そこで、朝の準備係（エントリポイント）が、係の道順メモを見て「案内板を通る道順」なら本当の住所に書き直すようにしました。書き直したら「書き直しました」と黒板（起動ログの note 行）に書きます。読めないメモや、教室みんなで 1 冊を使うような場所を指すメモは、書き直さずに「確かめてね」（WARN）と書きます。

> **3 つのポイント:** ① 3 人の係はみんな「片付けのときだけ、道順でノートを探し直す」。② いつもの係は、きのう渡した本当の住所を使う（追加は要らない）。③ 道順メモを持っている係には、メモを書き直してあげる（今回の追加）。

---

## 3. 登場の歴史と背景

> **やさしく言うと:** お掃除の記録も来客名簿も、ずっと昔から『ファイルに書いて、たまったら名前を変えて新しくする』やり方でした。コンテナの時代に『みんなで 1 枚の案内板』を使ったことで、きのうの日記と同じようにぶつかりました。

| 年 | 出来事 | 本件との関係 |
|---|---|---|
| **1959〜1960** | John McCarthy が Lisp でガベージコレクション（GC）を考案 | 使わなくなったメモリを自動で片付ける仕組み。gc.log はこの「お掃除」の記録 |
| **1993〜1995** | NCSA HTTPd と Apache HTTP Server の Common Log Format（%h %l %u %t "%r" %s %b） | Undertow の access-log の既定 pattern="common" はこの形式 |
| **1990 年代** | logrotate・rotatelogs など、ログを日付やサイズで切り替える道具 | 「改名して新しいファイルを開く」ローテーションが定番に |
| **1996〜2002** | Java の -verbose:gc、JDK 1.4 ごろの -Xloggc:\<file\> | GC の記録をファイルへ書けるように |
| **2001** | Tomcat 4（Catalina）の AccessLogValve（日付でファイルを切り替える） | Java のアプリケーションサーバの中で、アクセスログを日付でローテーションする形が定着 |
| **2011-11** | JDK の GC ログのローテーション（-XX:+UseGCLogFileRotation・NumberOfGCLogFiles・GCLogFileSize。JDK-6941923。7u2・6u34 にも入る） | 「サイズで番号付きの名前に回す」。JDK 8 の gc.log.0.current などの名前はこれ |
| **2014-02** | WildFly 8 で Web サーバが Undertow に。access-log は undertow サブシステムの setting になる | access_log.log・access_log.\<日付\>.log の名前と、日付変更後の最初のリクエストでのローテーション |
| **2016** | JBoss EAP 7.0（Undertow を採用） | EAP の access_log.log はここから |
| **2017-09** | JDK 9 の統合ログ（JEP 158 Unified JVM Logging・JEP 271 Unified GC Logging）。-Xlog:gc\*:file=…:filecount=N,filesize=M（既定は 5 ファイル × 20MB） | gc.log → gc.log.0〜4 の名前。「閉じる → 同じ番号を削除 → 改名 → 開き直す」の手順 |
| **2018-09** | JDK 11（LTS） | 本番のベースイメージ（ubi8/openjdk-11）。standalone.sh は -Xlog の形で GC ログを出す |
| **2021-07** | JBoss EAP 7.4（WildFly Core 15・Undertow 2.2）。bin/standalone.conf の既定で GC_LOG=true、3MB × 5 ファイル | 本番の構成。gc.log は既定で出る |
| **2024-02／2025** | JBoss EAP 8.0／8.1（Undertow 2.3。GC_LOG の既定と GC ログの出し方は同じ） | 同じ仕組みが続いている |
| **2026-09-27** | 本リポジトリで server.log の対策（pin）を実装 | JBOSS_LOG_DIR と -Djboss.server.log.dir を実体パスに。gc.log・access_log.log の既定の書き方にも効いていた |
| **2026-09-28** | 本書。gc.log と access_log.log を検討し、pin を素通りする明示の書き方への追加実装 | ― |

### なぜ見落とされやすいのか

- **gc.log** は 3MB ごとにしか片付けないので、GC の少ない JVM では何日も片付けない。事故はまれで、しかも GC ログはふだん誰も見ないため、消えても気付きにくい。障害の調査で GC ログが必要になったときに「無い」と分かる種類の事故。
- **access_log.log** は、server.log と同じ時刻（0 時）に同じ症状が出るが、アクセスログは集計ツールなど別の仕組みで読まれていることが多く、「前日付のファイルに当日分が入っている」ことに気付きにくい。ALB のヘルスチェックが 0 時直後に必ず来るので、server.log より確実に起きる。
- 本番の JAVA_OPTS にある -Djboss.server.log.dir=${JBOSS_HOME}/standalone/log は、server.log には効かない（JBoss 本体はリンクのまま使う）が、**GC ログの明示が無い構成なら、gc.log だけは偶然守っていた**（standalone.sh が readlink -m で実体に解決して -Xlog を作るため。ただし JAVA_OPTS に -Xlog／-Xloggc の明示があると standalone.sh は自分の指定を作らないので、この偶然は働かない。**本番には明示がある**〔2026-09-29 確認〕）。2026-09-27 の報告書で「この指定は削除を推奨」としたので、pin を入れずに削除だけすると gc.log の事故が始まる（pin を入れてから削除すれば問題ない）。

---

## 4. 動作原理 — gc.log（JVM の GC ログ）

> **やさしく言うと:** お掃除記録係は、ノートが 3MB でいっぱいになるたびに『同じ番号の古いノートを捨てる → 番号シールを貼る → 新しいノートを出す』。捨てるのもシールを貼るのも、新しいノートを出すのも、道順でノートを探します。

### 4-1. だれが gc.log を出すのか（JBoss EAP の既定）

- JBoss EAP の bin/standalone.conf は「GC_LOG が未設定なら true」にする。EAP 7.4.25 の配布物（Red Hat の Maven リポジトリの wildfly-ee-galleon-pack 7.4.25.GA-redhat-00001）と、EAP 8.0／8.1 のコア（wildfly-core-galleon-pack 21.0.20／27.1.15.Final-redhat-00001）で確認した。アップストリームの WildFly はこの行がコメントで、既定では GC ログを出さない。
- Red Hat の文書（EAP 7.4 Configuration Guide）も「standalone サーバでは、IBM の JDK を除き GC ログが既定で有効。GC_LOG=false で無効。1 ファイル 3MB、最大 5 ファイルで回す」と説明している。

**JBoss EAP 7.4 の bin/standalone.conf の末尾**

```sh
# enable garbage collection logging if not set in environment differently
if [ "x$GC_LOG" = "x" ]; then
   GC_LOG="true"
else
   echo "GC_LOG set in environment to $GC_LOG"
fi
```

### 4-2. standalone.sh が付ける指定

standalone.sh（EAP 7.4.25 のものは WildFly Core 15.0.46 と同一）は、JAVA_OPTS に GC ログの指定が無いときだけ、前回の gc.log\* を backupgc.log\* へ退避してから、JVM に GC ログの指定を足す。JAVA_OPTS に -Xlog:gc か -Xloggc があれば、**自分の指定は足さずに JAVA_OPTS の指定をそのまま使う**。

**standalone.sh の GC ログの部分（EAP 7.4.25。要点）**

```sh
if [ "$GC_LOG" = "true" ]; then
    mkdir -p $JBOSS_LOG_DIR
    NO_GC_LOG_ROTATE=`echo $JAVA_OPTS | $GREP "\-Xlog\:\?gc"`      # -Xlog:gc / -Xloggc があれば何もしない
    if [ "x$NO_GC_LOG_ROTATE" = "x" ]; then
        mv -f "$JBOSS_LOG_DIR/gc.log" "$JBOSS_LOG_DIR/backupgc.log"   # gc.log.0〜4・gc.log.*.current も同様
        ...
        # JDK 9 以降 (モジュール式の JDK)
        TMP_PARAM="-Xlog:gc*:file=\"$JBOSS_LOG_DIR/gc.log\":time,uptimemillis:filecount=5,filesize=3M"
        # JDK 8
        TMP_PARAM="-verbose:gc -Xloggc:\"$JBOSS_LOG_DIR/gc.log\" -XX:+PrintGCDetails -XX:+PrintGCDateStamps -XX:+UseGCLogFileRotation -XX:NumberOfGCLogFiles=5 -XX:GCLogFileSize=3M -XX:-TraceClassUnloading"
        ...
        PREPEND_JAVA_OPTS="$PREPEND_JAVA_OPTS $TMP_PARAM"
    fi
fi
```

JBOSS_LOG_DIR の決まり方は server.log のブートログと同じ。

| 条件 | JBOSS_LOG_DIR | gc.log のパス |
|---|---|---|
| -Djboss.server.log.dir が JAVA_OPTS か起動引数にある | 最後のものを readlink -m で解決した値（リンクを辿った実体パス） | 実体パス（起動した瞬間の解決結果） |
| 無いが、環境変数 JBOSS_LOG_DIR がある | 環境変数の値（そのまま） | その値 |
| どちらも無い | $JBOSS_BASE_DIR/log（＝/opt/jboss-eap/standalone/log。リンクのまま） | current 経由 |

### 4-3. JVM のローテーションの手順（HotSpot の LogFileOutput）

JDK 11u と 21u のソースで手順は同じ。きっかけは、その JVM が書いた量（JVM ごとの数え方。ファイルの実際の大きさではない）が filesize に達したとき。

| 手順 | 処理 | ソース上の場所 | パスを辿るか |
|---|---|---|---|
| **1（起動時）** | ファイルがあれば、空いている番号（無ければいちばん古い番号）の gc.log.N へ退避してから、gc.log を開く（追記モード） | LogFileOutput::initialize → next_file_number → archive | 辿る（この瞬間の current） |
| **2（毎回）** | 1 行書くたびに書いた量を足し、filesize 以上ならローテーション | LogFileOutput::write → should_rotate | ― |
| **3（ローテーション①）** | 自分のファイルを閉じる | rotate → fclose | 辿らない（自分の中身） |
| **4（ローテーション②）** | 同じ番号の古いファイル gc.log.N を**削除** | archive → remove(_archive_name) | 辿る（★この瞬間の current） |
| **5（ローテーション③）** | gc.log を gc.log.N へ**改名** | archive → rename(_file_name, _archive_name) | 辿る（★この瞬間の current） |
| **6（ローテーション④）** | 同じパスで開き直す | rotate → os::fopen(_file_name) | 辿る（★この瞬間の current） |
| **7** | 番号を 1 つ進める（5 番目の次は 0 に戻る） | increment_file_count | ― |

**HotSpot の rotate／archive（jdk11u。コメントは要約）**

```cpp
void LogFileOutput::rotate() {
  fclose(_stream);                                 // ① 自分のファイルを閉じる
  archive();                                       // ②③ 下の 2 行
  _stream = os::fopen(_file_name, FileOpenMode);   // ④ 同じ「パス名」で開き直す
  _current_size = 0;
  increment_file_count();                          //    次は gc.log.(N+1)
}

void LogFileOutput::archive() {                    // _archive_name = "<_file_name>.<N>"
  remove(_archive_name);                           // ② 同じ番号の古いファイルを「パス名で」削除
  rename(_file_name, _archive_name);               // ③ gc.log を gc.log.N へ「パス名で」改名
}
```

### 4-4. パスが current を辿ると何が起きるか

| 順 | 出来事 | A の書き込み先 | B の書き込み先 | 失われるもの |
|---|---|---|---|---|
| **1** | A 起動（current→A）。A は A/gc.log を開く | A/gc.log | ― |  |
| **2** | B 起動（current→B）。B は B/gc.log を開く | A/gc.log | B/gc.log |  |
| **3** | A が 3MB 書いてローテーション: A/gc.log を閉じる → B/gc.log.0 を削除（まだ無い）→ **B の現役 gc.log を B/gc.log.0 に改名** → B/gc.log を新しく作る | B/gc.log（新） | B/gc.log.0（fd のまま） |  |
| **4** | B が 3MB 書いてローテーション: B のファイル（いまの名前は B/gc.log.0）を閉じる → **B/gc.log.0 を削除** → B/gc.log（A のファイル）を B/gc.log.0 に改名 → B/gc.log を新しく作る | B/gc.log.0（fd のまま） | B/gc.log（新） | **B の最初の 3MB がどこにも残らない** |
| **以後** | A の gc.log（A/gc.log）は一度も改名されない。A と B の片付けが互いのファイルを改名・削除し続ける | ― | ― | 片付けのたびに誰かの記録が消え得る |

### 4-5. JDK 8 の場合

JDK 8 では gc.log.0.current に書き、3MB で gc.log.0 に改名して gc.log.1.current を新しく開く（"w" モード＝中身を空にして開く）。これもすべてパス名で行うので、パスが current を辿ると、他タスクの現役ファイルを改名したり、他タスクが書いている gc.log.N.current を空にしたりする。本番は JDK 11 なので本書の実機検証は JDK 11 で行った。

### 4-6. 起動時・JVM だけの再起動

- 起動時、standalone.sh は $JBOSS_LOG_DIR の gc.log\* を backupgc.log\* へ mv する。pin あり・random 方式なら新しい空のディレクトリなので何も起きない。taskid 方式でコンテナが再起動した場合は、自分のディレクトリで前回分を backupgc.log\* に退避する。
- JVM だけの再起動（:shutdown(restart=true) → exit 10）では standalone.sh の退避は行われず、新しい JVM が起動時に既存の gc.log を gc.log.N へ退避する（手順 1）。パスが current を辿ると、他タスクの gc.log を退避してしまう。pin あり（実体パス）なら自分のディレクトリで行われる。

---

## 5. 動作原理 — access_log.log（Undertow のアクセスログ）

> **やさしく言うと:** 受付係は、最初のお客さんが来たときに名簿を開き、日付が変わって最初のお客さんが来たときに『昨日のシールを貼って新しい名簿』。同じシールがあれば -1 を足します。名簿を探すのは、やっぱり道順です。

### 5-1. 設定と既定値

EAP 7.4.25 の undertow サブシステム（wildfly-undertow 7.4.25.GA-redhat-00001 の AccessLogDefinition）。WildFly の main でも同じ。

| 属性 | 既定値 | 意味 |
|---|---|---|
| **directory** | ${jboss.server.log.dir}（式） | 置き場所 |
| **relative-to** | なし | 付けると「その path の値 + / + directory」 |
| **prefix** | access_log. | ファイル名の前半 |
| **suffix** | log | ファイル名の後半（access_log. + log = access_log.log） |
| **rotate** | true | 日付でローテーションする |
| **pattern** | common | Common Log Format（%h %l %u %t "%r" %s %b） |
| **use-server-log** | false | true なら server.log（JBoss のログ）へ書く |
| **worker** | default | 書き込みを行うスレッドの集まり（XNIO worker） |

有効にする操作の例（JBoss CLI）。directory を付けなければ既定の ${jboss.server.log.dir} になる。

```
/subsystem=undertow/server=default-server/host=default-host/setting=access-log:add(pattern=common)
```

### 5-2. 出力先の決まり方

- AccessLogService は、PathManager.resolveRelativePathEntry(directory, relative-to) の結果を Paths.get() するだけで、シンボリックリンクは解決しない。
- jboss.server.log.dir の値は、ServerEnvironment が new File(値) のまま使う（-Djboss.server.log.dir が無ければ jboss.server.base.dir/log＝/opt/jboss-eap/standalone/log）。2026-09-27 の報告書 10-1 と同じ。
- したがって pin なしでは /opt/jboss-eap/standalone/log/access_log.log（current 経由）。pin あり（-Djboss.server.log.dir=mid/\<LOG_ID\> の実体パス）なら、既定の directory はその実体パスになる。

### 5-3. Undertow のローテーションの手順（DefaultAccessLogReceiver）

EAP 7.4.25 の undertow-core 2.2.40.SP3 で確認。Undertow の main では書き込みの流れが整理されたが、ローテーションの手順（パス名での存在確認・改名・開き直し）は同じ。

| 手順 | 処理 | ソース上の場所 | パスを辿るか |
|---|---|---|---|
| **1（起動時）** | 次の 0 時（JVM の既定のタイムゾーン）を計算。ファイルが既にあれば、その最終更新日を「今のファイルの日付」にする | calculateChangeOverPoint | 辿る（存在確認と最終更新時刻） |
| **2（最初のリクエスト）** | 既存のファイルが前日以前のものなら、まずローテーション。そのあと access_log.log を追記モードで開く（**遅延 open**） | run → writeMessage → Files.newBufferedWriter | 辿る（★この瞬間の current） |
| **3（毎リクエスト）** | 日付が変わっていれば（現在時刻 \> 次の 0 時）ローテーションしてから書く | writeMessage | ― |
| **4（ローテーション①）** | 自分のファイルを閉じる | doRotate → writer.close | 辿らない（自分の中身） |
| **5（ローテーション②）** | access_log.log があるか確認。改名先 access_log.\<日付\>.log が既にあれば -1、-2 … を付ける | doRotate → Files.exists | 辿る（★この瞬間の current） |
| **6（ローテーション③）** | access_log.log を改名（上書きはしない） | doRotate → Files.move | 辿る（★この瞬間の current） |
| **7（次の書き込み）** | 同じパスで開き直す | writeMessage → Files.newBufferedWriter | 辿る（★この瞬間の current） |

**DefaultAccessLogReceiver（undertow-core 2.2.40.SP3。要点）**

```java
private void writeMessage(final List<String> messages) {
    if (System.currentTimeMillis() > changeOverPoint) {   // 日付が変わった後の最初の書き込み
        doRotate();
    }
    if (writer == null) {                                  // 最初の 1 件目、または改名の直後
        writer = Files.newBufferedWriter(defaultLogFile, UTF_8, APPEND, CREATE);   // パス名で開く
    }
    ...                                                    // 書いて flush
}

private void doRotate() {
    writer.close(); writer = null;                         // 自分のファイルを閉じる
    if (!Files.exists(defaultLogFile)) return;             // パス名で存在確認
    Path newFile = outputDirectory.resolve(logBaseName + currentDateString + "." + logNameSuffix);
    int count = 0;
    while (Files.exists(newFile)) {                        // 同名があれば -1, -2 …（上書きしない）
        ++count;
        newFile = outputDirectory.resolve(logBaseName + currentDateString + "-" + count + "." + logNameSuffix);
    }
    Files.move(defaultLogFile, newFile);                   // パス名で改名
    ... calculateChangeOverPoint();                        // 次の 0 時と、次の日付
}
```

### 5-4. server.log との違い

| 項目 | server.log（jboss-logmanager） | access_log.log（Undertow） |
|---|---|---|
| **片付ける時** | 0 時以降の最初のログの直前 | 0 時以降の最初のリクエストの書き込みの直前（ALB のヘルスチェックも 1 件なので、ほぼ 0 時ちょうど） |
| **改名先** | server.log.\<日付\>。同名があれば**上書き**（REPLACE_EXISTING） | access_log.\<日付\>.log。同名があれば **-1、-2 … を付ける**（上書きしない） |
| **丸ごと消えるか** | 消える（2 回目の改名が前日分を上書き） | 消えない（代わりに番号付きのファイルが増える） |
| **ファイルを開く時** | 起動時（ブートログ） | **最初のリクエスト**（遅延 open） |
| **日付の決め方** | 起動時や前回のローテーション時に決めた nextSuffix | 前回の計算時点の日付（ファイルがあればその最終更新日） |
| **タイムゾーン** | JVM の既定 | JVM の既定（Calendar.getInstance()） |

### 5-5. パスが current を辿ると何が起きるか（0 時）

B が先にリクエストを受けた場合（S2r。実機で確認）:

| 順 | 出来事 | A の書き込み先 | B の書き込み先 |
|---|---|---|---|
| **1** | 0 時前: A・B とも自分の access_log.log に書いている | A/access_log.log | B/access_log.log |
| **2** | 0 時後、B に最初のリクエスト: B が自分のファイルを閉じ、B/access_log.log を B/access_log.\<前日\>.log に改名（正しい）→ B/access_log.log を開く | A/access_log.log | B/access_log.log（新） |
| **3** | A に最初のリクエスト: A が自分のファイルを閉じる → パス名で改名 → current は B なので、**B の新しい現役ファイルが B/access_log.\<前日\>-1.log に改名**される → A は B/access_log.log を新しく作って書く | B/access_log.log（新） | B/access_log.\<前日\>-1.log（fd のまま） |
| **以後** | B の当日分は「前日-1」の名前のファイルへ（server.log と同じ症状）。A の当日分は B のディレクトリへ。A/access_log.log は改名されない | B/access_log.log | B/access_log.\<前日\>-1.log |

A が先の場合は、A が B の現役ファイルを B/access_log.\<前日\>.log に改名し、続く B の片付けが A の新しいファイルを -1 に改名する。どちらの順でも、誰かの当日分が他人のディレクトリの前日付のファイルに書かれる。

### 5-6. 遅延 open が生む、0 時と関係ない混入

- access_log.log は最初のリクエストで初めて開く。起動してまだリクエストを受けていないタスク A は、別のタスク B が起動して current を張り替えた後に初めてリクエストを受けると、パス名で B/access_log.log を開いてしまう。
- 以後 A と B は同じファイルに追記する。EFS（NFS）では、複数のクライアントの追記は原子的でなく、行が混ざったり壊れたりし得る（Linux の open(2) の注意書き）。
- 起動が重なるローリングデプロイ（desiredCount≥2 で新タスクが続けて起動する）や、ALB に登録されるまでリクエストが来ない時間があると起きる。:reload で access-log のサービスが作り直された場合も、次のリクエストで開き直す。
- 実機（G1 シナリオ）で、A の fd が B のディレクトリの access_log.log を指し、1 つのファイルに A と B のリクエストが交互に並ぶことを確認した。

---

## 6. 本番の構成ではどうなるか（影響の整理）

> **やさしく言うと:** 本番では、受付係はもう事故を起こしています。お掃除記録係は、古いメモ（JAVA_OPTS の -Djboss.server.log.dir）のおかげで助かる場合もあります。でも本番の係は自分の道順メモ（-Xlog の明示）を持っているので、その道順が案内板を通るなら事故を起こします（2026-09-29 確認）。

### 6-1. 構成ごとの結果

| 構成 | gc.log | access_log.log | 根拠 |
|---|---|---|---|
| **本番の現状**（2026-09-29 確認。pin なし。CMD=eap、JAVA_OPTS に -Djboss.server.log.dir=${JBOSS_HOME}/standalone/log と **-Xlog／-Xloggc の明示**、access-log の directory の指定なし） | **起きる**（明示の出力先が standalone/log の下なら。standalone.sh は自分の指定を作らない） | **起きる** | gc.log: 実機の「pin あり＋明示」（8-5。pin は明示の -Xlog に影響しないので同じ条件）。access_log.log: 実機（G1・S2r） |
| 上の構成から GC ログの明示だけを除いたもの | 起きない（偶然。standalone.sh が readlink -m で実体に解決） | **起きる** | 実機（G1・S2r） |
| 本番の現状から JAVA_OPTS の指定だけ削除（pin なし） | **起きる** | **起きる** | 実機（G1 の pin なし） |
| 修正版（pin あり）・既定の書き方 | 起きない | 起きない | 実機（G1） |
| 修正版（pin あり）＋ JAVA_OPTS の -Xlog 明示／access-log の directory が絶対パス・base.dir 基準 | 2026-09-27 版: **起きる**／今回の版: 起きない | 2026-09-27 版: **起きる**／今回の版: 起きない | 実機（G1・S2r） |
| JBOSS_LOG_PIN=off（切り分け専用） | JAVA_OPTS の指定あり: 起きない／なし: 起きる | 起きる | 実機（G1・S2r） |

### 6-2. どれくらいの頻度で起きるか

| 対象 | 起きる条件 | 頻度の目安 |
|---|---|---|
| **access_log.log（0 時）** | 自分より後に別タスクが起動した（current が自分を指していない）タスクが、0 時をまたいで動いている | desiredCount が 2 以上なら**毎晩**（ALB のヘルスチェックで 0 時直後に必ず片付けが走る）。1 でも、0 時をまたぐローリングデプロイ・失敗デプロイの再試行・AZ リバランス・Fargate 退役などで並走すれば起きる |
| **access_log.log（遅延 open）** | 起動後まだリクエストを受けていないうちに、別タスクが起動した | 複数タスクが続けて起動するデプロイのたびに起き得る（0 時と無関係） |
| **gc.log** | パスが current を経由していて、並走する JVM が GC ログを filesize 分書いた（EAP の既定は 3MB。-Xlog に filesize を書かない場合と、JDK 11 の -Xloggc は 20MB） | GC の量しだい（数時間〜数日に 1 回）。0 時と無関係に、日中でも起きる。本番は JAVA_OPTS に GC ログの明示があるので、出力先が standalone/log の下なら起きる（明示が無ければ、JAVA_OPTS の -Djboss.server.log.dir のおかげで起きない） |

### 6-3. 本番の JAVA_OPTS の -Djboss.server.log.dir を削除するときの注意

- 2026-09-27 の報告書 10-1 では「pin を入れたうえで、JAVA_OPTS の -Djboss.server.log.dir は削除を推奨」とした。**pin（JBOSS_LOG_PIN=on、既定）が入っていれば、削除しても gc.log は実体パスのまま**（エントリポイントが JBOSS_LOG_DIR と -Djboss.server.log.dir を実体パスで渡すため）。
- 逆に、pin の無いイメージ（修正前）のまま、あるいは JBOSS_LOG_PIN=off で、この指定だけを削除すると、gc.log が current 経由になり、GC ログの改名・削除が始まる。削除は「修正版をデプロイした後」に行うこと（10-1 の手順どおり）。なお、本番のように GC ログの明示がある構成では、この指定の有無にかかわらず、明示の出力先が standalone/log の下なら修正前から current 経由になっている（修正版では明示のパスも書き換わる）。

---

## 7. 動作イメージ（時系列とディレクトリの状態）

> **やさしく言うと:** 時計の順に『だれがどのファイルに書いているか』を並べると、ノートが消える瞬間と、名前が間違う瞬間が見えます。

### 7-1. gc.log: 2 つのタスクが並走中に GC ログを回す（パスが current 経由）

```
【A と B が起動した直後】                 【A が回した後】                         【続いて B が回した後】
mid/                                      mid/                                      mid/
├── current -> B                          ├── current -> B                          ├── current -> B
├── A/                                    ├── A/                                    ├── A/
│   └── gc.log   (A が書いている)          │   └── gc.log   (A の前半・改名されない)  │   └── gc.log   (A の前半)
└── B/                                    └── B/                                    └── B/
    └── gc.log   (B が書いている)              ├── gc.log.0 (B が書き続けている!)         ├── gc.log.0 (A の後半! A が書き続ける)
                                              └── gc.log   (A が書いている!)             └── gc.log   (B の後半)
                                                                                      ※ B の前半 (gc.log.0 だったもの) は B 自身が削除
```

**修正後（pin・今回の書き換え）**: どの時点でも、A は A/ の中だけで gc.log → gc.log.0 → …、B は B/ の中だけで同じことを行う。

### 7-2. access_log.log: 2 つのタスクが 0 時をまたぐ（B が先にリクエスト）

```
【0 時の後の EFS（修正前・本番の現状）】                 【本来あるべき姿（修正後）】
mid/                                                      mid/
├── current -> B                                          ├── current -> B
├── A/                                                    ├── A/
│   └── access_log.log              (A の前日分・未改名)   │   ├── access_log.2026-09-27.log  (A の前日分)
└── B/                                                    │   └── access_log.log             (A の当日分)
    ├── access_log.2026-09-27.log   (B の前日分)          └── B/
    ├── access_log.2026-09-27-1.log (B の当日分!)             ├── access_log.2026-09-27.log  (B の前日分)
    └── access_log.log              (A の当日分!)             └── access_log.log             (B の当日分)
```

### 7-3. access_log.log: 起動直後の遅延 open（0 時と無関係）

| 時刻 | 出来事 | current | A の access_log | B の access_log |
|---|---|---|---|---|
| **10:00** | A 起動（まだリクエストを受けていない＝ファイルを開いていない） | A | （未オープン） | ― |
| **10:01** | B 起動 → current を B へ。B が最初のリクエストで B/access_log.log を開く | B | （未オープン） | B/access_log.log |
| **10:02** | A が最初のリクエストを受ける → パス名で開く → current は B なので **B/access_log.log** を開く | B | B/access_log.log（B と同じファイル） | B/access_log.log |
| **以後** | A と B が同じファイルに追記。A/ には access_log.log ができない | B | B/access_log.log | B/access_log.log |

---

## 8. 実機検証

> **やさしく言うと:** 本物の WildFly（JBoss EAP の元になっているサーバ）を 2 つ並べて、GC ログを回したり、0 時をまたがせたりして、どのファイルに何が書かれたかを確かめました。

### 8-1. 検証の方法

| 項目 | 内容 |
|---|---|
| **目的** | ① 本番の現状・修正前（2026-09-27 版）で gc.log／access_log.log の事故が起きるか、② 2026-09-27 版の pin がどこまで効いているか、③ 今回の追加実装で直るかを、本物の JBoss 系サーバで確かめる |
| **サーバ** | WildFly 26.1.3.Final（JBoss EAP 7.4 相当。WildFly Core 18.1.2、Undertow 2.2.19、jboss-logmanager 2.1.18）、Temurin JRE 11.0.32.1。WSL（Ubuntu 22.04）の ext4 上で Docker を使わずに実行（test/local/rotation_local.sh） |
| **ECS との対応** | タスク A／B＝別プロセス（entrypoint.sh → standalone.sh → java）、EFS＝シナリオごとの共有ディレクトリ、タスクローカルの空ボリューム＝タスクごとの configuration／tmp／data、イメージに焼いたリンク＝standalone/log → …/mid/current、ECS の停止＝SIGTERM |
| **EAP に合わせた点** | GC_LOG=true（EAP の standalone.conf の既定。WildFly は既定で無効）、本番と同じ CMD=eap と JAVA_OPTS の -Djboss.server.log.dir（T_CMD=eap・T_JAVA_OPTS_LOG_DIR=1） |
| **access-log** | seed の standalone.xml の default-host に \<access-log/\> を足した（T_ACCESS_LOG=default）。明示の書き方として directory="\<JBOSS_HOME\>/standalone/log"（literal）と relative-to="jboss.server.base.dir" directory="log"（basedir）も試した |
| **GC ログの明示** | JAVA_OPTS に -Xlog:gc\*:file=\<JBOSS_HOME\>/standalone/log/gc.log:time,uptimemillis:filecount=5,filesize=3M（T_JAVA_OPTS_GC=1） |
| **GC ログを回す方法** | 検証用 JSP（/ticker/gc.jsp?op=rotate）から DiagnosticCommand MBean の vmLog rotate を呼ぶ（jcmd \<pid\> VM.log rotate と同じ。3MB に達したときと同じ LogFileOutput::rotate() が動く）。op=gc で System.gc() を 3 回 |
| **0 時の作り方** | JVM のタイムゾーンだけを GMT±hh:mm にずらし、数分後が JVM にとっての 0 時になるようにした（時計は実時刻） |
| **観察したもの** | ① /proc/\<java\>/fd：JVM が実際に握っているファイル、② 各ディレクトリの gc.log\*（中身を書いた JVM を、各行の「時刻 − 稼働時間 ＝ JVM の起動時刻」から A／B と判定）と access_log\*（記録されたリクエストの who=／op=）、③ JVM の起動引数の -Xlog |
| **比べたエントリポイント** | 「2026-09-27 版」＝コミット 5e7343c（pin はあるが gc.log・access-log の書き換えは無い）。「今回の版」＝本書の実装 |

### 8-2. 結果のまとめ

| シナリオ | 構成 | エントリポイント | 結果 | 確認できたこと |
|---|---|---|---|---|
| **G1**（A 起動 → B 起動 → A が初めてリクエスト → A・B の GC ログを順に回す） | pin なし・JAVA_OPTS の指定なし | 2026-09-27 版（pin=off） | **再現** | A は最初のリクエストで B の access_log.log を開いた（2 つの JVM が同じファイルへ）。A が回すと B の現役 gc.log が gc.log.0 に改名され、続いて B が回すと B は自分の GC ログ（266 行）を削除した。A の gc.log は改名されないまま |
| **G1** | 本番の現状（CMD=eap、JAVA_OPTS に -Djboss.server.log.dir、pin なし） | 2026-09-27 版（pin=off） | gc.log は問題なし・access_log.log は**再現** | -Xlog の file= は standalone.sh が解決した mid/\<自分\>/gc.log で、GC ログは各自のディレクトリで回った。access_log.log は A が B のファイルを開いた |
| **G1** | pin あり（既定の書き方） | 2026-09-27 版 | 問題なし | gc.log・access_log.log とも各自のディレクトリ。gc.log.0（回す前）と gc.log（回した後）がそろう |
| **G1** | pin あり＋JAVA_OPTS に -Xlog の明示＋access-log の directory が絶対パス（本番と同じ CMD=eap・JAVA_OPTS） | 2026-09-27 版 | **再現** | pin があっても -Xlog は明示のまま（standalone.sh は自分の指定を足さない）。B の gc.log が改名され、続いて B 自身の GC ログ（276 行）が削除された。access_log.log も A が B のファイルを開いた |
| **G1** | 同上 | 今回の版 | **解消** | note 行が 2 つ（GC ログ・access-log）。-Xlog の file= が mid/\<自分\>/gc.log に、standalone.xml の directory が ${jboss.server.log.dir} になり、どちらも各自のディレクトリ |
| **G1** | pin あり＋-Xlog の明示＋access-log が relative-to="jboss.server.base.dir" directory="log" | 今回の版 | **解消** | relative-to を外して directory=${jboss.server.log.dir} に書き換え。各自のディレクトリ |
| **S2r**（A・B が 0 時をまたぐ。B が先にリクエスト） | pin なし・JAVA_OPTS の指定なし | 2026-09-27 版（pin=off） | **再現** | B の当日分が access_log.2026-09-27-1.log へ（fd で確認）。A の当日分は B のディレクトリの access_log.log。A の access_log.log は改名されない。server.log も同時に再現（B の前日分が消失） |
| **S2r** | 本番の現状（CMD=eap、JAVA_OPTS に -Djboss.server.log.dir、pin なし） | 2026-09-27 版（pin=off） | **再現** | 上と同じ（本番の現状で、access_log.log にも server.log と同じ症状が起きる） |
| **S2r** | pin あり＋-Xlog の明示＋access-log の directory が絶対パス（本番と同じ CMD=eap・JAVA_OPTS） | 2026-09-27 版 | access_log.log は**再現** | server.log は pin で解消しているが、access_log.log は上と同じ |
| **S2r** | 同上 | 今回の版 | **解消** | A・B とも自分のディレクトリに access_log.2026-09-27.log（前日分）と access_log.log（当日分）。fd も各自の access_log.log のまま |

> **「本番の現状」の意味（2026-09-29 追記）:** この表の「本番の現状」は、CMD=eap で JAVA_OPTS に -Djboss.server.log.dir がある構成を、**GC ログの明示なし**で動かしたもの。本番の JAVA_OPTS には -Xlog／-Xloggc の明示がある（2026-09-29 確認）ので、本番の gc.log は 4 行目（pin あり＋明示・2026-09-27 版＝**再現**）と同じ側にあたる。明示があると、pin の有無にかかわらず standalone.sh は自分の指定を作らず、明示のパスがそのまま使われるため。本番の access-log は directory の指定なし＝T_ACCESS_LOG=default と同じ。

### 8-3. G1・pin なし（修正前の挙動）: GC ログの消失と access_log.log の混入

**記録（抜粋）: scenario=G1 extra=[JBOSS_LOG_PIN=off T_ACCESS_LOG=default]**

| 時刻（JVM） | 出来事（rotation_local.sh の記録） |
|---|---|
| 23:44:56 | START A（mid/…-07o6mlwo）。A は起動したが、まだリクエストを受けていない |
| 23:45:14 | START B（mid/…-0c3bsf71）。current は B |
| 23:45:37 | TICK B who=B:first |
| 23:45:39 | TICK A who=A:first-after-B-started（A が初めてリクエストを受ける） |
| 23:45:41 | FD A → mid/…-07o6mlwo/gc.log、**mid/…-0c3bsf71/access_log.log**（B のファイル）、mid/…-07o6mlwo/server.log |
| 23:45:41 | ARGV A -Xlog:gc\*:file=…/A/opt/jboss-eap/standalone/log/gc.log:…（リンクのまま＝current 経由） |
| 23:45:43 | GCOP A op=rotate（A の GC ログを回す） |
| 23:45:44 | FD A → **mid/…-0c3bsf71/gc.log**（B のディレクトリの新しいファイル）／FD B → **mid/…-0c3bsf71/gc.log.0**（B の現役ファイルが改名された） |
| 23:45:44 | GCOP B op=rotate（B の GC ログを回す） |
| 23:45:46 | FD A → mid/…-0c3bsf71/gc.log.0（A のファイルが B によって改名された）／FD B → mid/…-0c3bsf71/gc.log |

**最終状態**

```
current -> 20260928041112-0c3bsf71 (B)
[20260928041054-07o6mlwo] (A)
  gc.log         (24572 bytes, 266 行, 書いた JVM: A)     ← A の前半。一度も改名されない
  (access_log.log は無い)
[20260928041112-0c3bsf71] (B)
  gc.log         ( 3608 bytes,  42 行, 書いた JVM: B)     ← B の後半
  gc.log.0       ( 7211 bytes,  84 行, 書いた JVM: A)     ← A の後半 (B のディレクトリに!)
  access_log.log (994 bytes)                              ← A と B のリクエストが 1 つのファイルに
      who=B:first / who=A:first-after-B-started / op=gc (A) / op=gc (B) / op=rotate … / who=A:last / who=B:last
  ※ B の前半 (24621 bytes, 266 行) はどのファイルにも残っていない (B 自身の remove(gc.log.0) で削除)
```

### 8-4. G1・本番の現状: gc.log は偶然守られ、access_log.log は混入

> **2026-09-29 追記:** この試験は GC ログの明示が無い構成。本番には明示があるので、本番の gc.log は次の 8-5 と同じく**再現する側**にあたる（pin の有無は明示の -Xlog に影響しない）。

**記録（抜粋）: scenario=G1 extra=[2026-09-27 版 T_CMD=eap T_JAVA_OPTS_LOG_DIR=1 JBOSS_LOG_PIN=off T_ACCESS_LOG=default]**

| 時刻（JVM） | 出来事 |
|---|---|
| 23:45:11 | FD A → mid/…-yv3q9jhd/gc.log、mid/…-yv3q9jhd/server.log、**mid/…-ddoq4ey0/access_log.log**（B のファイル） |
| 23:45:12 | ARGV A -Xlog:gc\*:file=**mid/…-yv3q9jhd/gc.log**（standalone.sh が JAVA_OPTS の -Djboss.server.log.dir を readlink -m で実体に解決した値）、-Djboss.server.log.dir=…/A/opt/jboss-eap/standalone/log（JBoss 本体はリンクのまま） |
| 23:45:13〜15 | A・B の GC ログを回す → A は A/ の中で gc.log.0 と gc.log、B は B/ の中で gc.log.0 と gc.log。**GC ログは問題なし** |
| 最終 | B/access_log.log に A と B のリクエストが混在。A/ に access_log.log は無い |

### 8-5. G1・2026-09-27 版＋明示の書き方: pin があっても直らない

**記録（抜粋）: scenario=G1 extra=[2026-09-27 版 T_CMD=eap T_JAVA_OPTS_LOG_DIR=1 T_JAVA_OPTS_GC=1 T_ACCESS_LOG=literal]**

| 時刻（JVM） | 出来事 |
|---|---|
| 23:44:31 | START A: log pin 行・note 行（-Djboss.server.log.dir の上書き）は出るが、GC ログと access-log には何もしない |
| 23:45:12 | ARGV A -Djboss.server.log.dir=…/standalone/log、**-Xlog:gc\*:file=…/A/opt/jboss-eap/standalone/log/gc.log**（明示のまま）、-Dorg.jboss.boot.log.file=mid/\<A\>/server.log、-Djboss.server.log.dir=mid/\<A\>（pin） |
| 23:45:11 | FD A → mid/\<A\>/gc.log、**mid/\<B\>/access_log.log**、mid/\<A\>/server.log（server.log は pin で自分のディレクトリ） |
| 23:45:14 | A の GC ログを回した後: FD A → mid/\<B\>/gc.log、FD B → mid/\<B\>/gc.log.0 |
| 最終 | B/gc.log（42 行・B）、B/gc.log.0（84 行・A）、A/gc.log（276 行・A、未改名）。B の前半 276 行は消失。B/access_log.log に A と B が混在 |

### 8-6. G1・今回の版＋明示の書き方: 解消

**記録（抜粋）: scenario=G1 extra=[T_CMD=eap T_JAVA_OPTS_LOG_DIR=1 T_JAVA_OPTS_GC=1 T_ACCESS_LOG=literal]**

```
[efs-entrypoint] log pin: JBoss は mid/20260928041952-jf1eqr34 へ直接書き込みます (current は書き込み経路に使いません)
[efs-entrypoint] note: 共有の置き場 (current 経由) を指す -Djboss.server.log.dir の指定 (JAVA_OPTS: …/A/opt/jboss-eap/standalone/log) は pin で上書きします (docs/LOG_ROTATION.md 10-1)
[efs-entrypoint] note: 共有の置き場を指す GC ログの指定 (JAVA_OPTS: …/A/opt/jboss-eap/standalone/log/gc.log) を mid/20260928041952-jf1eqr34 へ書き換えました (docs/LOG_ROTATION.md 10-2)
[efs-entrypoint] note: access-log (standalone.xml 466 行目) の出力先 directory=…/A/opt/jboss-eap/standalone/log は共有の置き場を指すため、directory=${jboss.server.log.dir} (= mid/20260928041952-jf1eqr34) に書き換えました (docs/LOG_ROTATION.md 10-2)

ARGV A -Xlog:gc*:file=mid/20260928041952-jf1eqr34/gc.log:time,uptimemillis:filecount=5,filesize=3M   ← 実体パス
FD   A -> mid/20260928041952-jf1eqr34/access_log.log                                                   ← 自分のディレクトリ

最終状態
[20260928041952-jf1eqr34] (A)   gc.log (84 行・A) / gc.log.0 (270 行・A) / access_log.log (A のリクエストだけ)
[20260928042021-yt0ddjdl] (B)   gc.log (42 行・B) / gc.log.0 (282 行・B) / access_log.log (B のリクエストだけ)
```

### 8-7. S2r・本番の現状: 0 時の access_log.log（server.log と同じ症状）

**記録（抜粋）: scenario=S2r extra=[2026-09-27 版 T_CMD=eap T_JAVA_OPTS_LOG_DIR=1 JBOSS_LOG_PIN=off T_ACCESS_LOG=default]**

| 時刻（JVM） | 出来事 |
|---|---|
| 23:56:56 | TICK A who=A:before-midnight |
| 23:57:11 | TICK B who=B:before-midnight。FD A → mid/\<A\>/access_log.log、FD B → mid/\<B\>/access_log.log |
| 00:00:05 | ---- 0 時を通過 ---- TICK B who=B:after-midnight-1（B が先に片付け＝自分のファイルを正しく改名） |
| 00:00:05 | TICK A who=A:after-midnight-1（A の片付けが B の新しい現役ファイルを改名） |
| 00:00:06 | FD A → **mid/\<B\>/access_log.log**／FD B → **mid/\<B\>/access_log.2026-09-27-1.log** |

**最終状態**

```
current -> 20260928042256-njf3epmg (B)
[20260928042240-2opfuxh5] (A)
  access_log.log               who=A:before-midnight                         ← 改名されないまま
[20260928042256-njf3epmg] (B)
  access_log.2026-09-27.log    who=B:before-midnight                         ← B の前日分 (正しい)
  access_log.2026-09-27-1.log  who=B:after-midnight-1, who=B:after-midnight-2 ← B の当日分が前日付の名前に!
  access_log.log               who=A:after-midnight-1, who=A:after-midnight-2 ← A の当日分が B のディレクトリに!
  server.log.2026-09-27        TICK B:after-midnight-1, -2                    ← server.log も同じ症状 (B の前日分は消失)
  server.log                   TICK A:after-midnight-1, -2
```

### 8-8. S2r・今回の版＋明示の書き方: 解消

**記録（抜粋）: scenario=S2r extra=[T_CMD=eap T_JAVA_OPTS_LOG_DIR=1 T_JAVA_OPTS_GC=1 T_ACCESS_LOG=literal]**

```
00:00:06 | FD A -> mid/20260928042940-0rdv1jmr/access_log.log      ← 0 時の後も自分のディレクトリ
00:00:06 | FD B -> mid/20260928042952-8p233s0o/access_log.log

[20260928042940-0rdv1jmr] (A)
  access_log.2026-09-27.log   who=A:before-midnight
  access_log.log              who=A:after-midnight-1, who=A:after-midnight-2
[20260928042952-8p233s0o] (B)
  access_log.2026-09-27.log   who=B:before-midnight
  access_log.log              who=B:after-midnight-1, who=B:after-midnight-2
```

同じ構成を 2026-09-27 版で動かすと（8-2 の表の 9 行目）、server.log は pin で解消しているのに、access_log.log は 8-7 と同じ結果になった。

### 8-9. 単体試験（エントリポイントの分岐）

test/local/entrypoint_test.sh に gc.log・access-log の試験（[16]〜[17h]、1 シェルあたり 35 項目）を足し、dash・bash --posix・busybox sh の 3 種類で **PASS=333 FAIL=0**（2026-09-27 の 228 項目から増加。既存の項目もすべて合格）。

### 8-10. 検証の限界

- 共有ストレージは EFS ではなく WSL の ext4（rename と fd の関係は NFS でも同じ。NFS 固有の属性キャッシュや、別クライアントが消したファイルの ESTALE は再現していない）。readonlyRootFilesystem（--read-only）は再現していない（Docker 版の試験で確認済みの構成と同じエントリポイント）。
- サーバは JBoss EAP 本体ではなくアップストリームの WildFly 26.1.3（GC ログの出し方は EAP 7.4 の standalone.sh と同一、access-log の既定値と Undertow のローテーション手順も EAP 7.4.25 のソースと同じであることを確認）。GC_LOG=true は環境変数で与えた（EAP では standalone.conf の既定）。
- GC ログのローテーションは、3MB を実際に書く代わりに VM.log rotate で起こした（同じ rotate() が動く）。容量で自然に回るまで待つ試験はしていない。
- WildFly 41.0.1（≒ EAP 8.x、JDK 21）での実機確認は、作業 PC の C: ドライブの空きが 2.7GB まで減った（Windows の pagefile.sys が 9.9GB に拡張された）ため見送った。ソースでは JDK 21u の LogFileOutput、EAP 8.0／8.1 の standalone.conf・standalone.sh、Undertow・WildFly の main が同じ手順・既定値であることを確認した。

---

## 9. 追加実装が必要か（判断）と対処の比較

> **やさしく言うと:** いつもの書き方なら追加は要りません。でも本番のお掃除記録係は『道順メモ』（-Xlog の明示）を持っていたので、メモを書き直す仕組みが本番にも必要でした。

### 9-1. 判断

| 対象 | いつもの書き方（既定） | 明示の書き方 | 判断 |
|---|---|---|---|
| **gc.log** | 2026-09-27 の pin で直っている（standalone.sh が $JBOSS_LOG_DIR/gc.log を使う） | JAVA_OPTS 等の -Xlog／-Xloggc が共有の置き場を指すと直らない（実機で再現） | **追加実装が必要**。本番の JAVA_OPTS には明示がある（2026-09-29 確認）ので、備えではなく本番に必要な対策になった |
| **access_log.log** | 2026-09-27 の pin で直っている（directory の既定 ${jboss.server.log.dir}） | directory が絶対パス・${jboss.server.base.dir}/log・relative-to=jboss.server.base.dir 等だと直らない（実機で再現） | 本番は directory の指定なし（2026-09-29 確認）なので **pin だけで直る**。追加実装の access-log の部分は本番では何もしない（note 行も出ない）が、directory を書いたときの備えとして残す |
| **本番の現状** | access_log.log は今も事故が起きている。gc.log も、明示の出力先が standalone/log の下なら起きている | ― | 修正版（pin と今回の追加）のデプロイで両方とも直る |

### 9-2. 対処の比較

> 記号のア〜キは、この表の中だけのもの（2026-09-29 に A〜G から変更。GitHub の main にあるコンテナ専用リンク方式を「案 B」と呼んでいるので、取り違えないようにした）。

| 対処 | 内容 | 効果 | 評価 |
|---|---|---|---|
| **ア. 何もしない（2026-09-27 の pin のまま）** | 既定の書き方は pin で直る | 明示の書き方があると直らない。本番には GC ログの明示があるので、本番の gc.log は直らない（2026-09-29 確認） | × |
| **イ. エントリポイントが明示の書き方も実体パスへ揃える【採用・実装済み】** | JAVA_OPTS 等の -Xlog／-Xloggc のパス部分と、standalone.xml の access-log の directory を書き換える | 本番の書き方を知らなくても効く。書き換えたら note 行で分かる。タスク定義もイメージの seed も変えない | ◎ |
| **ウ. WARN だけ出す** | 共有の置き場を指す指定を見つけたら警告 | 事故は続く | ○（判定できない書き方にだけ使う） |
| **エ. イメージの設定を直す** | 本番のエントリポイント・standalone.conf・seed の standalone.xml で、GC ログは $JBOSS_LOG_DIR、access-log は directory 省略か ${jboss.server.log.dir} にする | 最も素直。イと併用すると note 行が消える | ○（イと併用を推奨） |
| **オ. ファイルにしない** | GC ログを標準出力へ（-Xlog:gc\*:stdout）、アクセスログを console-access-log（EAP 7.4 以降）や use-server-log="true" で server.log へ | ファイルのローテーション自体が無くなる／server.log にまとまる | ○（中長期。CloudWatch で見る運用に合う） |
| **カ. 出すのをやめる** | GC_LOG=false、access-log を消す | 調査に必要な記録を失う | × |
| **キ. 回し方を変える** | filesize を大きく、rotate=false | 回数が減るだけ。rotate=false でも遅延 open の混入は残り、gc.log は起動時の退避が残る | × |

### 9-3. 対処イを選んだ理由

- server.log の対策（2026-09-27）と同じ考え方: 「共有の置き場を指す指定は、運用者の意図した出力先ではない」と見なして実体パスへ揃える（-Djboss.server.log.dir の扱いと同じ）。mid/ の外を指す指定は運用者の意図として尊重する。
- JVM のオプション（-Xlog）は、-Djboss.server.log.dir のように起動引数で上書きすることができない（standalone.sh の起動引数は JBoss 本体に渡り、JVM のオプションにならない）。そのため JAVA_OPTS を書き換えるが、字句の中のパス部分だけにとどめ、他の部分は 1 文字も変えない（2026-09-27 の報告書 10-1 (4) で「JAVA_OPTS の書き換えは採用しない」としたのは、起動引数で確実に上書きできる -Djboss.server.log.dir についての判断）。
- standalone.xml は毎起動 seed から復元される作業用のコピーなので、書き換えてもイメージや他のタスクに影響しない。
- 書き換えたら note 行を出すので、「本番にこの書き方があったこと」が CloudWatch で分かり、エ（イメージを直す）につなげられる。

---

## 10. 実装内容（リポジトリの変更点）

> **やさしく言うと:** 朝の準備係（エントリポイント）が、係の道順メモを読んで、案内板を通る道順なら本当の住所に書き直します。書き直したら黒板に書きます。

### 10-1. 変更したファイル

| ファイル | 変更内容 |
|---|---|
| **docker/base/entrypoint.sh** | 3-B（pin）で、pin を適用するときに ① JAVA_OPTS・JAVA_TOOL_OPTIONS・JDK_JAVA_OPTIONS の GC ログの指定のパス部分を実体パスへ、② ${CONF_DIR}/${JBOSS_CONFIG_FILE} の access-log の directory を ${jboss.server.log.dir} へ書き換える。イメージの standalone.conf の GC ログの指定は WARN。「共有の置き場か」の判定を 1 つの関数（shared_log_rest）にまとめ、-Djboss.server.log.dir の判定（is_shared_log_dir）もそれを使うようにした |
| **docs/LOG_ROTATION.md** | 10-2 を新設（本書の要点）。1 章・4-4・8 章・10 章・11 章・13 章に参照と注記 |
| **docs/DESIGN.md・docs/TROUBLESHOOTING.md** | 3 章の pin の説明に gc.log・access_log.log、7 章に確認方法と note／WARN の読み方、8 章のチェックリストに 2 項目 |
| **test/local/entrypoint_test.sh** | 試験 [16]〜[17h] を追加（1 シェルあたり 35 項目。3 シェルで 333 項目） |
| **test/local/rotation_local.sh** | GC_LOG=true（EAP の既定）、T_ACCESS_LOG・T_JAVA_OPTS_GC・T_EP、G1 シナリオ、gc.log・access_log の記録（FD・スナップショット・起動引数） |
| **test/rotation/fake-eap/make_ticker_war.py** | 検証用 WAR に gc.jsp（GC を起こす・GC ログを今すぐ回す）を追加 |
| **test/local/README.md・test/rotation/README.md** | 試験項目・使い方・2026-09-28 の結果 |

### 10-2. 書き換えの判定ルール

**共有の置き場**とは、イメージに焼いた ${JBOSS_HOME}/standalone/log（→ mid/current）とその下、mid/ とその下（current・他タスク・前回起動のディレクトリ）。実在するディレクトリは物理パスでも判定する（別の綴りや、EFS 側がシンボリックリンク経由のとき）。

| 対象 | 見る場所 | 書き換えるもの | 書き換えないもの |
|---|---|---|---|
| **gc.log** | JAVA_OPTS・JAVA_TOOL_OPTIONS・JDK_JAVA_OPTIONS の空白区切りの各字句。-Xlog:\<対象\>:[file=]\<パス\>[:…] と -Xloggc:\<パス\>（引用符付きも） | 共有の置き場を指すパス → ${LOG_OWN}\<共有の置き場より下の残り\>/\<ファイル名\>。字句の他の部分と値全体の他の部分は 1 文字も変えない。下のディレクトリは作る。note 行 | 全タスク共有の EFS（EFS_LOG_DIR の直下など）→ WARN のみ。相対パス・stdout／stderr・mid/ の外 → 何もしない |
| **gc.log** | イメージの standalone.conf（RUN_CONF があればそれ） | ―（読み取り専用。書き換えられない） | コメント以外の行で -Xlog を含み、standalone/log か /mid/ を含む → WARN |
| **access_log.log** | ${CONF_DIR}/${JBOSS_CONFIG_FILE}（CMD=eap なら SERVER_CONFIG）の \<access-log …\> 要素（1 行に収まっているもの） | directory が絶対パス・${jboss.server.base.dir}…・${jboss.home.dir}…、または relative-to="jboss.server.base.dir"／"jboss.home.dir" で、共有の置き場を指す → directory="${jboss.server.log.dir}\<下\>"、relative-to を外す。note 行 | 式（${env.X} など）・全タスク共有の EFS・属性が複数行・relative-to だけ → WARN のみ。use-server-log="true"・relative-to="jboss.server.log.dir"／"jboss.server.data.dir"・既定・${jboss.server.log.dir}… → 何もしない |

| 書き方の例 | 判定 | 書き換え後 |
|---|---|---|
| -Xlog:gc\*:file=/opt/jboss-eap/standalone/log/gc.log:time:filecount=5,filesize=3M | 共有 | -Xlog:gc\*:file=/mnt/logs/…/mid/\<ID\>/gc.log:time:filecount=5,filesize=3M |
| -Xlog:gc\*:file="/opt/jboss-eap/standalone/log/gc.log":… | 共有 | 引用符はそのまま、中のパスだけ実体パス |
| '-Xloggc:/opt/jboss-eap/standalone/log/gc.log' | 共有 | '-Xloggc:/mnt/logs/…/mid/\<ID\>/gc.log' |
| -Xlog:safepoint:/mnt/logs/…/mid/current/sp.log | 共有 | -Xlog:safepoint:/mnt/logs/…/mid/\<ID\>/sp.log |
| -Xlog:gc\*:file=/opt/jboss-eap/standalone/log/gc/heap.log | 共有 | …/mid/\<ID\>/gc/heap.log（gc/ を作る） |
| -Xlog:gc\*:file=/var/log/gc.log・-Xlog:gc:file=gc.log・-Xlog:gc\*:stdout | 対象外 | そのまま |
| -Xlog:gc\*:file=/mnt/logs/\<C\>/logs/\<S\>/gc.log | 全タスク共有の EFS | そのまま（WARN） |
| \<access-log/\>・directory="${jboss.server.log.dir}"・relative-to="jboss.server.log.dir" | pin 済み | そのまま |
| \<access-log directory="/opt/jboss-eap/standalone/log"/\> | 共有 | directory="${jboss.server.log.dir}" |
| \<access-log relative-to="jboss.server.base.dir" directory="log"/\> | 共有 | directory="${jboss.server.log.dir}"（relative-to を外す） |
| \<access-log directory="${jboss.home.dir}/standalone/log/access"/\> | 共有 | directory="${jboss.server.log.dir}/access" |
| \<access-log directory="${env.ACCESS_DIR}"/\> | 判定できない | そのまま（WARN） |

### 10-3. エントリポイントの流れ（追加部分）

```
3-B. pin (JBOSS_LOG_PIN=on、mid/ の外を指す -Djboss.server.log.dir の明示が無いとき)
     LOG_OWN=$(cd mid/<LOG_ID> && pwd -P)                   … current を経由しない実体パス
     export JBOSS_LOG_DIR=$LOG_OWN                          … ブートログ・既定の gc.log
     logging.properties の fileName を揃える
     PIN_OPT=-Djboss.server.log.dir=$LOG_OWN                … server.log・audit.log・既定の access_log.log
     pin_gc_logs     ★ JAVA_OPTS / JAVA_TOOL_OPTIONS / JDK_JAVA_OPTIONS の -Xlog・-Xloggc (共有の置き場 → $LOG_OWN)
                       standalone.conf の GC ログの指定は WARN
     pin_access_log  ★ standalone.xml の access-log (共有の置き場 → directory="${jboss.server.log.dir}…")
```

### 10-4. 主要部分（抜粋）

**GC ログのパスの書き換え（pin_gc_log_var。コメントは省略）**

```sh
for _gt in ${_gv}; do                                   # 値を空白で区切った字句ごと (set -f)
    _gu="$(printf '%s' "${_gt}" | tr -d "'\"")"         # 判定は引用符を外して
    case "${_gu}" in
        -Xloggc:*) _gf="${_gu#-Xloggc:}" ;;
        -Xlog:*:*) _gf="${_gu#-Xlog:*:}"; _gf="${_gf%%:*}"; _gf="${_gf#file=}" ;;
        *) continue ;;
    esac
    case "${_gf}" in /?*/?*) ;; *) continue ;; esac      # 絶対パスだけ
    shared_log_rest "${_gf%/*}" || continue              # 共有の置き場か (残りは SHARED_REST)
    # 字句の中のパスだけ置き換え、値の中の同じ字句 (最初の 1 つ) を差し替える
    _gtn="${_gt%%"${_gf}"*}${LOG_OWN}${SHARED_REST}/${_gf##*/}${_gt#*"${_gf}"}"
    _gnew="${_gnew%%"${_gt}"*}${_gtn}${_gnew#*"${_gt}"}"
done
```

**access-log の書き換え（pin_access_log_line。要約。実際のコードは引用符・エスケープを処理している）**

```sh
_adir="$(xml_attr "${_ae}" directory)"; _arel="$(xml_attr "${_ae}" relative-to)"
case "${_arel}" in
    "")                    _aeff="${_adir:-${LOGDIR_EXPR}}" ;;      # 既定は ${jboss.server.log.dir}
    jboss.server.log.dir)  return 0 ;;                               # pin 済み
    jboss.server.base.dir) _aeff="${STANDALONE_DIR}/${_adir}" ;;
    jboss.home.dir)        _aeff="${JBOSS_HOME}/${_adir}" ;;
    *)                     return 0 ;;
esac
... (${jboss.server.base.dir}・${jboss.home.dir} を展開。その他の式は WARN)
if shared_log_rest "${_aeff}"; then
    sed -i "<行>s#(<access-log…directory=)\"<旧>\"#\1\"\${jboss.server.log.dir}<残り>\"#" standalone.xml
    sed -i "<行>s#(<access-log…)[[:space:]]relative-to=\"<旧>\"#\1#" standalone.xml   # relative-to がある場合
fi
```

- ヒアドキュメントは使っていない（UBI8 の /bin/sh＝bash 4.4 はヒアドキュメントに一時ファイルを作り、readonlyRootFilesystem では失敗するため）。
- standalone.xml の書き換えは、seed から復元した作業用のコピーだけ（seed は変えない）。CONFIG_SEED_MODE=skip で持ち越したファイルは 2 回目以降は書き換え済みなので何もしない。

### 10-5. 起動ログ（CloudWatch）の例

**本番と同じ CMD=eap・JAVA_OPTS に -Djboss.server.log.dir と -Xlog の明示・access-log の directory が絶対パスの場合（実機）**

```
[efs-entrypoint] configuration を復元しました (mode=overwrite, 12 エントリ)
[efs-entrypoint] JBoss EAP log dir: /mnt/logs/…/mid/<ID> (LOG_ID_SOURCE=random)
[efs-entrypoint] log pin: JBoss は /mnt/logs/…/mid/<ID> へ直接書き込みます (current は書き込み経路に使いません)
[efs-entrypoint] note: 共有の置き場 (current 経由) を指す -Djboss.server.log.dir の指定 (JAVA_OPTS: /opt/jboss-eap/standalone/log) は pin で上書きします (docs/LOG_ROTATION.md 10-1)
[efs-entrypoint] note: 共有の置き場を指す GC ログの指定 (JAVA_OPTS: /opt/jboss-eap/standalone/log/gc.log) を /mnt/logs/…/mid/<ID> へ書き換えました (docs/LOG_ROTATION.md 10-2)
[efs-entrypoint] note: access-log (standalone.xml 466 行目) の出力先 directory=/opt/jboss-eap/standalone/log は共有の置き場を指すため、directory=${jboss.server.log.dir} (= /mnt/logs/…/mid/<ID>) に書き換えました (docs/LOG_ROTATION.md 10-2)
[efs-entrypoint] log -> /mnt/logs/…/mid/<ID> (書き込み可)
[efs-entrypoint] preflight OK. starting: /opt/jboss-eap/bin/standalone.sh -Djboss.server.log.dir=/mnt/logs/…/mid/<ID> -b 0.0.0.0 …
```

既定の書き方（GC ログの明示なし、access-log の directory 省略）なら、note 行は出ず、これまでどおりの行だけになる。

### 10-6. 単体試験で確かめたこと（[16]〜[17h]）

| # | ケース | 期待する動作 |
|---|---|---|
| **16〜16b** | JAVA_OPTS の -Xlog（file= あり・なし、引用符付き）・-Xloggc が standalone/log・mid/current とその下を指す | パス部分だけ実体パスへ。二重の空白・他の引用符も含めて他は 1 文字も変えない。下のディレクトリを作る。note 行 |
| **16c・16d** | mid/ の外・相対パス・stdout・-Xlog:disable／全タスク共有の EFS | 書き換えない／書き換えずに WARN |
| **16e** | JAVA_TOOL_OPTIONS・JDK_JAVA_OPTIONS、同じ字句が 2 つ | どちらも・2 つとも書き換える |
| **16f・16g** | JBOSS_LOG_PIN=off・mid/ の外の -Djboss.server.log.dir／CMD=eap＋本番と同じ JAVA_OPTS | 書き換えない／pin・note と GC ログの書き換えが両方効く |
| **16h** | standalone.conf に共有の置き場を指す GC ログの指定 | WARN（行番号付き）。コメント行と $JBOSS_LOG_DIR の書き方は WARN しない |
| **17** | access-log が既定・${jboss.server.log.dir}・relative-to="jboss.server.log.dir" | 書き換えない |
| **17b〜17d** | directory が絶対パス（その下・末尾 /・mid/current・前回 LOG_ID・'…' の属性）・${jboss.server.base.dir}/log・${jboss.home.dir}/standalone/log・relative-to="jboss.server.base.dir"／"jboss.home.dir" | directory="${jboss.server.log.dir}\<下\>"、relative-to を外す。他の属性はそのまま。seed は変えない |
| **17e・17f** | use-server-log="true"・console-access-log・relative-to="jboss.server.data.dir"・mid/ の外／式・全タスク共有の EFS・属性が複数行・relative-to だけ | 書き換えない／書き換えずに WARN |
| **17g・17h** | JBOSS_LOG_PIN=off・SERVER_CONFIG=standalone-full.xml／CONFIG_SEED_MODE=skip で 2 回起動 | 書き換えない・SERVER_CONFIG のファイルだけ書き換える／2 回目は何もしない |

---

## 11. 確認手順・移行手順・運用

> **やさしく言うと:** JVM が手に持っているファイルと、起動ログの note 行を見れば、直ったかどうかが分かります。

### 11-1. 効いているかの確認

```sh
# 1) CloudWatch: log pin 行が出ていること。明示の書き方があれば note 行 (GC ログ / access-log) も出る

# 2) ECS Exec: JVM が握っている gc.log・access_log.log と、GC ログの起動引数
for p in /proc/[0-9]*; do
  case "$(readlink $p/exe 2>/dev/null)" in
    */java) ls -l $p/fd | grep -E 'gc\.log|access_log'               # mid/<自分の LOG_ID>/ の下であること
            tr '\0' '\n' < $p/cmdline | grep -E '^-Xlog|^-Xloggc' ;;   # file= が実体パスであること
  esac
done

# 3) access-log の設定 (directory が未設定=既定か ${jboss.server.log.dir} であること)
/opt/jboss-eap/bin/jboss-cli.sh -c --command='/subsystem=undertow/server=default-server/host=default-host/setting=access-log:read-resource'
```

- access_log.log は最初のリクエストで開くので、fd に出ないときは 1 回アクセスしてから見る。

### 11-2. 本番で確認してほしいこと（イメージ・設定）と 2026-09-29 の確認結果

| 確認すること | 見る場所 | 共有の置き場を指していたら | 2026-09-29 の確認結果 |
|---|---|---|---|
| **GC ログの明示** | 本番のエントリポイントで JAVA_OPTS に入れている値、タスク定義の JAVA_OPTS／JAVA_TOOL_OPTIONS／JDK_JAVA_OPTIONS | 修正版で自動的に書き換わる（note 行）。できれば $JBOSS_LOG_DIR/gc.log を使う書き方か、指定の削除（standalone.sh の既定に任せる）に直す | **明示あり**。残り: 正確な値（出力先が standalone/log・mid/ の下か、$JBOSS_HOME などの変数を文字のまま書いていないか）と、設定している場所。修正版で起動して GC ログの note 行が出るかで確かめられる |
| **standalone.conf の GC ログ** | イメージの /opt/jboss-eap/bin/standalone.conf | 書き換えられない（WARN）。イメージ側で $JBOSS_LOG_DIR/gc.log を使う書き方に直す | 未確認（JAVA_OPTS の明示とは別の場所。修正版の起動ログに WARN が出れば、ここにもある） |
| **access-log の directory** | seed の /opt/jboss-eap/standalone/configuration-seed/\<SERVER_CONFIG\> の \<access-log …\> | 修正版で自動的に書き換わる（note 行）。できれば directory を省略するか ${jboss.server.log.dir} にする | **directory の指定なし**（既定の ${jboss.server.log.dir}）。pin だけで直り、書き換えは起きない |
| **GC_LOG** | 本番の環境変数・standalone.conf | JAVA_OPTS に GC ログの明示が無いときだけ意味を持つ（false なら standalone.sh は gc.log を出さない。true〔既定〕なら出す）。明示がある場合は、GC_LOG の値にかかわらず明示どおりに出る | 本番は明示があるので、GC_LOG の値は結果に影響しない |

### 11-3. 移行手順

1. base → front／back の順にイメージを再ビルドする（CI では STRICT_SEED=1）。
2. 日中にデプロイする。修正前のタスクは current 経由で access_log.log を改名するので、0 時（JVM のタイムゾーン）をまたいで新旧が並走しないようにする。
3. 起動ログで log pin 行と、あれば note 行を確認する。
4. 翌朝、各 mid/\<LOG_ID\>/ に access_log.\<前日\>.log と access_log.log がそろい、-1 付きのファイルが無く、名前の日付と中身の日付が一致していることを確認する（下の洗い出し）。

### 11-4. すでに名前と中身がずれた access_log の洗い出し

```sh
cd /mnt/logs/<Component_name>/logs/<Service_Name>/mid
ls -1 */access_log.*-[0-9]*.log 2>/dev/null        # -1, -2 付きのファイルは、同じディレクトリで 2 回改名が起きた印
for f in */access_log.????-??-??*.log; do
  name_date=$(printf '%s\n' "$f" | sed -E 's/.*access_log\.([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/')
  d=$(grep -m1 -oE '\[[0-9]{2}/[A-Za-z]{3}/[0-9]{4}' "$f" | tr -d '[' | tr '/' ' ')
  [ -n "$d" ] || continue
  first=$(date -d "$d" +%F)
  [ "$first" != "$name_date" ] && echo "MISMATCH $f (名前=$name_date, 先頭行=$first)"
done
```

- gc.log は中身から書いた JVM を見分けにくい。各行の装飾 [時刻][稼働時間ms] から「時刻 − 稼働時間」を計算すると JVM の起動時刻になり、どのタスクが書いた行かを見分けられる（本書の試験道具はこの方法で判定した）。消えた GC ログは戻らない。

### 11-5. 運用上の注意

- JBOSS_LOG_PIN=off のまま、本番の JAVA_OPTS から -Djboss.server.log.dir を消さない（GC ログの明示が無い構成では gc.log が current 経由になる）。pin=off では GC ログの明示の書き換えも行わないので、本番のように明示がある構成では、pin=off にすると明示の出力先が current 経由に戻る。pin=off は切り分け専用。
- ログ収集ツールの対象は mid/\*/gc.log\*・mid/\*/access_log\* にする（current は他タスクの起動で切り替わる）。
- 同じ理由で、logging サブシステムに自分で足したファイルハンドラも、path を /opt/jboss-eap/standalone/log/… の絶対パスや relative-to="jboss.server.base.dir" + path="log/…" で書いていると current 経由になる。relative-to="jboss.server.log.dir" で書けば pin に乗る（エントリポイントは確認しない。seed の standalone.xml を grep して確かめる）。
- アプリのログ（/webapp/…/logs → EFS の \<Service_Name\> 直下）は、mid/ のような「タスクごとのディレクトリ」が無く、全タスクが同じ場所に書く。アプリがタスク固有でないファイル名で日付ローテーションしていると、同じ種類の事故が起きる（JBoss の設定ではないので本書の対象外。アプリのログ設定を確認すること）。

---

## 12. 用語集

> **やさしく言うと:** むずかしい言葉を、ひとことで言い換えます。

| 用語 | ひとことで | もう少し詳しく |
|---|---|---|
| **ガベージコレクション（GC）** | メモリのお掃除 | 使わなくなったメモリを JVM が自動で片付ける仕組み |
| **gc.log（GC ログ）** | お掃除の記録 | GC がいつ・どれくらい動いたかの記録。性能の調査に使う |
| **GC_LOG** | お掃除記録を出すかのスイッチ | JBoss EAP の standalone.conf の既定は true。false で出さない |
| **-Xlog（統合ログ）** | JVM の記録の出し方の指定 | JDK 9 からの書き方。-Xlog:gc\*:file=\<パス\>:\<装飾\>:filecount=N,filesize=M |
| **-Xloggc** | JDK 8 までの GC ログの指定 | -Xloggc:\<パス\> と -XX:+UseGCLogFileRotation など |
| **filecount／filesize** | 何冊まで・1 冊何 MB | EAP の既定は 5 冊・3MB。いっぱいになると gc.log.0〜4 に回す |
| **HotSpot** | OpenJDK の JVM 本体 | 本番の openjdk-11 もこれ。GC ログを書いてローテーションする |
| **アクセスログ（access_log.log）** | 来客名簿 | Web サーバが受けたリクエストを 1 行ずつ書くファイル |
| **Undertow** | JBoss の Web サーバ部分 | WildFly 8／EAP 7 から。アクセスログも書く |
| **access-log（設定）** | 来客名簿の設定 | standalone.xml の undertow の host の中の setting。directory・prefix・suffix・rotate など |
| **Common Log Format（pattern="common"）** | 来客名簿の書き方 | %h %l %u %t "%r" %s %b。1990 年代の Web サーバから続く形 |
| **遅延 open** | 最初のお客さんが来てから名簿を開く | access_log.log は起動時ではなく最初のリクエストで開く |
| **directory／relative-to** | 名簿の置き場所の書き方 | relative-to を付けると「その path の値 + / + directory」 |
| **${jboss.server.log.dir}** | JBoss のログ置き場の住所 | pin で mid/\<LOG_ID\> の実体パスになる |
| **JBOSS_LOG_DIR** | standalone.sh が使うログ置き場 | ブートログと既定の gc.log の場所。pin で実体パスになる |
| **pin（固定）** | 本当の住所を渡す | JBoss の書き込み先を current 経由ではなく実体パスに固定すること（2026-09-27） |
| **共有の置き場** | 案内板を通る場所 | standalone/log・mid/ 配下。そこへ書くと他タスクと同じ current を辿る |
| **note 行／WARN** | 黒板のお知らせ | エントリポイントが書き換えたとき（note）・確かめてほしいとき（WARN）に出す起動ログの行 |

---

## 13. 参考資料（一次情報）

> **やさしく言うと:** 調べるときに見た、元の資料の一覧です。

| 分類 | 資料 | URL |
|---|---|---|
| **Red Hat** | JBoss EAP 7.4 Configuration Guide — Logging with JBoss EAP（Garbage Collection Logging: 既定で有効・GC_LOG=false で無効・3MB × 5） | https://docs.redhat.com/en/documentation/red_hat_jboss_enterprise_application_platform/7.4/html/configuration_guide/logging_with_jboss_eap |
| **Red Hat** | JBoss EAP 7.4 Performance Tuning Guide — Diagnosing Performance Issues（GC ログ） | https://docs.redhat.com/en/documentation/red_hat_jboss_enterprise_application_platform/7.4/html/performance_tuning_guide/diagnosing_performance_issues |
| **Red Hat** | JBoss EAP 8.0 Configuration Guide — Logging with JBoss EAP | https://docs.redhat.com/en/documentation/red_hat_jboss_enterprise_application_platform/8.0/html/configuration_guide/logging-with-jboss-eap_default |
| **配布物** | JBoss EAP 7.4 の feature pack（bin/standalone.conf・standalone.sh。wildfly-ee-galleon-pack 7.4.25.GA-redhat-00001） | https://maven.repository.redhat.com/ga/org/jboss/eap/wildfly-ee-galleon-pack/ |
| **配布物** | JBoss EAP 8.0／8.1 のコア feature pack（wildfly-core-galleon-pack 21.0.20／27.1.15.Final-redhat-00001） | https://maven.repository.redhat.com/ga/org/wildfly/core/wildfly-core-galleon-pack/ |
| **ソース** | EAP 7.4.25 の -sources.jar（undertow-core 2.2.40.SP3-redhat-00001、wildfly-undertow 7.4.25.GA-redhat-00001、wildfly-server・wildfly-controller 15.0.46.Final-redhat-00001） | https://maven.repository.redhat.com/ga/ |
| **ソース** | OpenJDK HotSpot LogFileOutput（jdk11u） | https://github.com/openjdk/jdk11u/blob/master/src/hotspot/share/logging/logFileOutput.cpp |
| **ソース** | OpenJDK HotSpot LogFileOutput（jdk21u） | https://github.com/openjdk/jdk21u/blob/master/src/hotspot/share/logging/logFileOutput.cpp |
| **ソース** | Undertow DefaultAccessLogReceiver（main） | https://github.com/undertow-io/undertow/blob/main/core/src/main/java/io/undertow/server/handlers/accesslog/DefaultAccessLogReceiver.java |
| **ソース** | WildFly undertow サブシステム AccessLogDefinition（main） | https://github.com/wildfly/wildfly/blob/main/undertow/src/main/java/org/wildfly/extension/undertow/AccessLogDefinition.java |
| **ソース** | WildFly Core standalone.sh（main） | https://github.com/wildfly/wildfly-core/blob/main/core-feature-pack/galleon-common/src/main/resources/packages/bin.standalone/content/bin/standalone.sh |
| **OpenJDK** | JEP 158: Unified JVM Logging | https://openjdk.org/jeps/158 |
| **OpenJDK** | JEP 271: Unified GC Logging | https://openjdk.org/jeps/271 |
| **OpenJDK** | JDK-6941923: Handling large log files produced by long running Java Applications（GC ログのローテーション。7u2・6u34） | https://bugs.openjdk.org/browse/JDK-6941923 |
| **Linux** | open(2) man page（O_APPEND と NFS の注意） | https://man7.org/linux/man-pages/man2/open.2.html |
| **本リポジトリ** | docs/LOG_ROTATION.md（server.log の報告書と 10-1・10-2） | ECS_EFS_Dockerfile_Symboliclink_lite/docs/LOG_ROTATION.md |
