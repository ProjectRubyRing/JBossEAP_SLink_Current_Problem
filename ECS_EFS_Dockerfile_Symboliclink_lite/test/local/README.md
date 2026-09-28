# Docker を使わない検証（Linux / WSL）

`test/rotation/`（Docker 版）と同じ確認を、**Docker を使わずに** Linux や WSL（Ubuntu）で行うためのスクリプト。
Docker Desktop の仮想ディスクが膨らんで PC の空き容量を圧迫する環境向け。**本番イメージには含めない。**

| スクリプト | 何を確かめるか | 必要なもの | 所要時間 |
|---|---|---|---|
| `entrypoint_test.sh` | `docker/base/entrypoint.sh` と `entrypoint.taskid.sh` の分岐（pin の付与、明示指定の優先、不正値の停止、taskid の取得とフォールバック、logging.properties の書き換え、並行起動、gc.log・access-log の出力先の書き換え など） | bash、python3、curl（JBoss・Java は不要） | 2〜4 分 |
| `rotation_local.sh` | 本物の WildFly（JBoss EAP のアップストリーム）を「ECS タスク相当」のプロセスとして複数起動し、JVM のタイムゾーン上の 0 時をまたいだ `server.log`・`access_log.log` の挙動と、GC ログ（`gc.log`）のローテーションの行き先 | bash、curl、unzip、tar、python3、ps。JRE と WildFly は `setup` が取得 | 1 シナリオ 2〜5 分 |

## entrypoint_test.sh

```bash
test/local/entrypoint_test.sh                 # dash / bash --posix / busybox sh のうち入っているもの全部で実行
test/local/entrypoint_test.sh "bash --posix"  # シェルを指定
```

最後に `RESULT: PASS=… FAIL=0` と出れば合格（失敗があると終了コード 1）。
2026-09-28 に WSL（Ubuntu 22.04）で `dash`・`bash --posix`・`busybox sh` の 3 種類を試し、**PASS=333 FAIL=0**
（2026-09-27 午前の版は 135 項目、午後の版は 228 項目。2026-09-28 に gc.log・access-log の試験 [16]〜[17h] を追加した）。

主な確認項目:

| # | ケース | 期待する動作 |
|---|---|---|
| 1 | 既定（`JBOSS_LOG_PIN=on`）＋ CMD が `…/standalone.sh` | コマンド直後に `-Djboss.server.log.dir=<mid/<LOG_ID> の実体パス>` を挿入。元の引数は順序・空白とも保持。`JBOSS_LOG_DIR` も実体パス |
| 2 | CMD が `eap`／standalone.sh 以外 | WARN のみ（引数は変えずにそのまま exec）。`JBOSS_LOG_DIR` は export |
| 3 | `-Djboss.server.log.dir` を引数か `JAVA_OPTS` で明示し、その値が `mid/` の外 | 明示を優先して pin しない（WARN に値を出す） |
| 3c〜3e | `-Djboss.server.log.dir` の値が共有の置き場（`<JBOSS_HOME>/standalone/log`・`mid/current` など。引用符付き・末尾 `/` も） | pin で上書き（note に出どころと値）。`JAVA_OPTS` は変えずに渡し、起動引数にある共有の指定は取り除く |
| 15〜15h | CMD=`eap`（本番の起動方式） | `$JBOSS_HOME/bin/standalone.sh` を本番と同じ引数（`-b 0.0.0.0 -bmanagement 0.0.0.0 -c "${SERVER_CONFIG}"`・`javax.net.ssl.*` 3 つ・`JBOSS_SERVER_OPTS` を空白で分割）で起動し、コマンド直後に pin。`JAVA_OPTS`／`JBOSS_SERVER_OPTS` の共有の指定は上書き、`mid/` の外は尊重。未設定の変数でも `set -u` で止まらない。`preflight OK` 行と WARN はパスワードを `****` に伏せる。`SERVER_CONFIG` 未設定は FATAL（`current` を触らない）、`-c` のファイルが seed に無い・`standalone.sh` が無いときも FATAL。`eap` の後ろの引数は本番と同じく使わない（WARN）。ラッパー経由（8b）でも同じ |
| 4 | `JBOSS_LOG_PIN=off` | 従来どおり current 経由（WARN） |
| 5・6 | `JBOSS_LOG_PIN` / `LOG_ID_SOURCE` の不正値 | FATAL で停止。**current も mid も configuration も触らない** |
| 7 | `LOG_ID_SOURCE=taskid` | メタデータ v4 の TaskARN（新形式・旧形式・整形 JSON）からタスク ID。取れない・不正な文字を含むときは random で代替。2 回目の起動（restartPolicy 相当）は同じディレクトリを再利用 |
| 8 | 互換ラッパー `efs-entrypoint-taskid.sh` | `LOG_ID_SOURCE=taskid` で本体を実行。誤って `efs-entrypoint.sh` の名前で置いても無限 exec せず FATAL（user+mount 名前空間で `/usr/local/bin` に tmpfs を重ねて確認。使えない環境では SKIP） |
| 9 | `logging.properties` に `standalone/log/…`・`mid/current/…`・前回 `mid/<ID>/…` の絶対パス | 今回の実体パスへ書き換え。無関係なパスはそのまま |
| 10 | 8 本を同時に起動 | 全員が別々の LOG_ID を作り、各自が**自分の**実体パスを受け取る（current は 1 本だけ） |
| 11〜14 | standalone/log が別タスクを指す／dangling、EFS 側がシンボリックリンク経由、seed・logging.properties 欠落 | 順に note のみ／FATAL／物理パスを渡す／FATAL |
| 16〜16b | `JAVA_OPTS` の GC ログの指定（`-Xlog:…file=<パス>`・`file=` なし・引用符付き・`-Xloggc:`）が共有の置き場（`<JBOSS_HOME>/standalone/log`・`mid/current` とその下）を指す | パス部分だけを `mid/<LOG_ID>` の実体パスへ書き換え（下のディレクトリも作る）。`JAVA_OPTS` の他の部分（二重の空白・引用符）は 1 文字も変えない。note 行を出す |
| 16c・16d | `mid/` の外・相対パス・stdout・`-Xlog:disable`／全タスク共有の EFS（`EFS_LOG_DIR` の直下） | 書き換えない／書き換えずに WARN |
| 16e | `JAVA_TOOL_OPTIONS`・`JDK_JAVA_OPTIONS`、同じ字句が 2 つ | どちらも書き換える。2 つとも書き換える |
| 16f・16g | `JBOSS_LOG_PIN=off`・`mid/` の外の `-Djboss.server.log.dir`（pin しない）／CMD=`eap` + 本番と同じ `JAVA_OPTS` | 書き換えない／pin・`-Djboss.server.log.dir` の note と GC ログの書き換えが両方効く |
| 16h | イメージの `standalone.conf` に共有の置き場を指す GC ログの指定 | WARN（行番号付き。書き換えられない）。コメント行と `$JBOSS_LOG_DIR` の書き方は WARN しない |
| 17 | `standalone.xml` の access-log が既定・`${jboss.server.log.dir}`・`relative-to="jboss.server.log.dir"` | 書き換えない（pin だけで自分のディレクトリ） |
| 17b〜17d | access-log の `directory` が絶対パス（`<JBOSS_HOME>/standalone/log`、その下、`mid/current`、前回 LOG_ID、`'…'` の属性）・`${jboss.server.base.dir}/log`・`${jboss.home.dir}/standalone/log`・`relative-to="jboss.server.base.dir"`／`"jboss.home.dir"` | `directory="${jboss.server.log.dir}<その下>"` に書き換え、`relative-to` を外す。他の属性はそのまま。seed は変えない。note 行に行番号と元の値 |
| 17e・17f | `use-server-log="true"`・`console-access-log`・`relative-to="jboss.server.data.dir"`・`mid/` の外／式（`${env.X}`）・全タスク共有の EFS・属性が複数行・`relative-to` だけ | 書き換えない／書き換えずに WARN |
| 17g・17h | `JBOSS_LOG_PIN=off`・CMD=`eap` + `SERVER_CONFIG=standalone-full.xml`／`CONFIG_SEED_MODE=skip` で 2 回起動 | 書き換えない・`SERVER_CONFIG` のファイルだけ書き換える／2 回目は何もしない |

## rotation_local.sh

```bash
# 1) JRE と WildFly を取得 (wf26 = WildFly 26.1.3 ≒ EAP 7.4、wf41 = WildFly 41.0.1 ≒ EAP 8.x)
test/local/rotation_local.sh setup wf26

# 2) 240 秒後が JVM にとっての 0 時になるようにして、シナリオを並行実行
#    "<シナリオ> <wf26|wf41> <ラベル> <ポートの基準値> [環境変数=値 ...]"
test/local/rotation_local.sh batch 240 \
  "S1 wf26 fixed-S1 100" \
  "S1 wf26 legacy-S1 200 JBOSS_LOG_PIN=off"
cat ~/rotwork/results/fixed-S1.log ~/rotwork/results/legacy-S1.log

# 本番の起動方式 (CMD=eap) と、本番の JAVA_OPTS の -Djboss.server.log.dir=<JBOSS_HOME>/standalone/log を再現する場合
test/local/rotation_local.sh batch 240 \
  "S1 wf26 eap-fixed 100 T_CMD=eap T_JAVA_OPTS_LOG_DIR=1" \
  "S1 wf26 eap-legacy 200 T_CMD=eap T_JAVA_OPTS_LOG_DIR=1 JBOSS_LOG_PIN=off"

# 3) 後片付け (JRE・WildFly・結果をすべて削除)
test/local/rotation_local.sh clean
```

`T_` で始まる指定は試験道具への指示で、タスクの環境変数ではない。

| 指定 | 意味 |
|---|---|
| `T_CMD=eap` | CMD に `eap` を渡す（本番の起動方式）。`SERVER_CONFIG=standalone.xml`、`EXTRASLB_TRUSTSTORE_TYPE=JKS`（base の Dockerfile の ENV と同じ）、ポートのずらしは `JBOSS_SERVER_OPTS` で渡す。指定しなければ CMD に `standalone.sh -b 127.0.0.1 …` を直接渡す |
| `T_JAVA_OPTS_LOG_DIR=1` | 本番のエントリポイントと同じく、`JAVA_OPTS` に `-Djboss.server.log.dir=<JBOSS_HOME>/standalone/log` を入れる |
| `T_JAVA_OPTS_GC=1` | `JAVA_OPTS` に GC ログの明示指定 `-Xlog:gc*:file=<JBOSS_HOME>/standalone/log/gc.log:time,uptimemillis:filecount=5,filesize=3M` を入れる（共有の置き場を指す書き方。standalone.sh は自分の `-Xlog` を足さずにこれを使う） |
| `T_ACCESS_LOG=<種類>` | seed の `standalone.xml` の default-host に access-log を足す。`default` = `<access-log/>`（directory の既定 `${jboss.server.log.dir}`）、`literal` = `directory="<JBOSS_HOME>/standalone/log"`、`basedir` = `relative-to="jboss.server.base.dir" directory="log"` |
| `T_EP=<パス>` | 試験するエントリポイント（既定はリポジトリの `docker/base/entrypoint.sh`）。修正前の版と比べるときに使う（例: `git show <commit>:…/entrypoint.sh > ~/rotwork/entrypoint.prev.sh`） |

2026-09-28 から、JBoss EAP の `standalone.conf` の既定と同じく `GC_LOG=true` で起動する（WildFly は既定で GC ログを出さないため）。
止めるときは `GC_LOG=false` を付ける。スナップショットには `server.log*` に加えて `gc.log*`（中身を書いた JVM を、各行の
「時刻 − 稼働時間 = JVM の起動時刻」から A／B と判定して表示）と `access_log*`（記録されたリクエストの `who=`・`op=`）を出し、
FD 行には JVM が握っている `gc.log`・`access_log` も出す。

S1 では、JBoss 本体が実際に使っている `jboss.server.log.dir` を CLI（`:resolve-expression`）で読み、`LOGDIR` 行に記録する。

| シナリオ | 内容 |
|---|---|
| `S1` | 旧タスク A が 0 時をまたいで稼働 → 0 時後に新タスク B が起動 → A を停止（ご報告のケース） |
| `S2` / `S2r` | A・B が 0 時をまたいで稼働し、A（S2）／B（S2r）が先にログを書く |
| `R1` | 0 時とは無関係。B の起動後に A を `:reload`、続いて `:shutdown(restart=true)`（JVM だけの再起動） |
| `R2` | 0 時前に A がクラッシュ（kill -9）→ 0 時後に同じタスクのコンテナとして再起動（ECS restartPolicy 相当）。`LOG_ID_SOURCE=taskid` を付けるとタスク ID 方式 |
| `G1` | 0 時とは無関係。A 起動（リクエストはまだ受けない）→ B 起動 → A が初めてリクエストを受ける（access_log.log を開く）→ A・B の GC ログを順に今すぐローテーション（検証用 JSP `gc.jsp?op=rotate`。jcmd の `VM.log rotate` と同じ処理で、容量に達したときと同じ関数が動く） |

### 2026-09-27 の実行結果（WSL Ubuntu 22.04）

| シナリオ | 実装 | サーバ | 結果 |
|---|---|---|---|
| S1 | 修正後 | WildFly 26.1.3 / 41.0.1 | 解消: A は自分のディレクトリで `server.log.<前日>` と `server.log`（停止ログ）を作成。B の fd は最後まで `server.log` |
| S1 | `JBOSS_LOG_PIN=off`（修正前の挙動） | WildFly 26.1.3 | 再現: B の fd が `server.log.<前日>` に変わり、B の当日分が前日付ファイルへ。B の `server.log` には A の停止ログ |
| S2 | 修正後 | WildFly 26.1.3 | 解消: A・B とも自分のディレクトリで前日分と当日分に分かれる。消失なし |
| S2 | `JBOSS_LOG_PIN=off` | WildFly 26.1.3 | 再現: B の前日分（起動ログ・0 時前のログ）がどのファイルにも残らない |
| S2r | 修正後 | WildFly 26.1.3 | 解消（S2 と同じ） |
| R1 | 修正後 | WildFly 26.1.3 | `:reload` 後も JVM 再起動後も、A は自分の `server.log` に書く |
| R1 | `JBOSS_LOG_PIN=off` | WildFly 26.1.3 | `:reload` では開き直さない（自分のファイルのまま）。JVM 再起動後は current 経由で **B の `server.log` を開き、2 つの JVM が同じファイルに書く** |
| R2 | 修正後・`LOG_ID_SOURCE=taskid` | WildFly 26.1.3 | 同じ `mid/<タスクID>` を再利用。起動直後の最初のログで前回分が `server.log.<前日>` に改名され、今回分は新しい `server.log` |
| R2 | 修正後・random | WildFly 26.1.3 | 新しい `mid/<起動時刻-乱数>` に `server.log` を作成。前回のディレクトリの `server.log` は改名されずに残る |
| S1 | 修正後・`T_CMD=eap T_JAVA_OPTS_LOG_DIR=1`（本番と同じ起動方式・本番と同じ `JAVA_OPTS`） | WildFly 26.1.3 | 解消: JVM 引数に `-Djboss.server.log.dir` が 2 つ並ぶ（`JAVA_OPTS` 由来のリンクのパス → pin）が、JBoss 本体の値（`LOGDIR`）は `mid/<自分の ID>`。B の fd は最後まで `server.log` |
| S1 | 修正後・`T_CMD=eap`（`JAVA_OPTS` の指定を削除＝推奨） | WildFly 26.1.3 | 解消: JVM 引数の `-Djboss.server.log.dir` は pin の 1 つだけ |
| S1 | `JBOSS_LOG_PIN=off`・`T_CMD=eap T_JAVA_OPTS_LOG_DIR=1`（本番の現状） | WildFly 26.1.3 | 再現: JBoss 本体の値は `…/opt/jboss-eap/standalone/log`（リンクのまま。`-Dorg.jboss.boot.log.file` だけは standalone.sh が解決した実体）。B の fd が `server.log.<前日>` に変わり、B の `server.log` には A の停止ログ |

`T_CMD=eap` の初回は `EXTRASLB_TRUSTSTORE_TYPE` を渡しておらず、`-Djavax.net.ssl.trustStoreType=`（空）のために
JVM 既定のトラストストアを読めず、HTTPS の SSL コンテキスト（`applicationSSC`）が起動に失敗して検証用アプリが 404 になった
（それでも上の 3 行と同じ結論。起動・停止ログと fd で判定できた）。いまの `T_CMD=eap` は base の Dockerfile と同じ
`EXTRASLB_TRUSTSTORE_TYPE=JKS` を渡す。詳細は `docs/LOG_ROTATION.md` 10-1 (6)。

### 2026-09-28 の実行結果（gc.log・access_log.log。WSL Ubuntu 22.04、WildFly 26.1.3 + Temurin JRE 11.0.32.1）

「2026-09-27 版」は gc.log・access_log.log の書き換えを入れる前のエントリポイント（`T_EP` で指定）。詳細は `docs/LOG_ROTATION.md` 10-2 (5)。

| シナリオ | 指定 | 結果 |
|---|---|---|
| G1 | `JBOSS_LOG_PIN=off T_ACCESS_LOG=default` | 再現: A は最初のリクエストで B の `access_log.log` を開く（2 つの JVM が同じファイルへ）。A が GC ログを回すと B の現役 `gc.log` が `gc.log.0` に改名され、続いて B が回すと B は自分の GC ログ（266 行）を削除 |
| G1 | 2026-09-27 版・`T_CMD=eap T_JAVA_OPTS_LOG_DIR=1 JBOSS_LOG_PIN=off T_ACCESS_LOG=default`（本番の現状） | gc.log は問題なし（standalone.sh が `-Djboss.server.log.dir` を解決した `mid/<自分>/gc.log`）。access_log.log は再現 |
| G1 | `T_ACCESS_LOG=default`（pin あり・既定の書き方） | 問題なし（どちらも各自のディレクトリ） |
| G1 | 2026-09-27 版・`T_CMD=eap T_JAVA_OPTS_LOG_DIR=1 T_JAVA_OPTS_GC=1 T_ACCESS_LOG=literal` | 再現（pin があっても、明示の `-Xlog` と絶対パスの access-log は current 経由。B の GC ログ 276 行が削除された） |
| G1 | 今回の版・同上 | 解消（note 行 2 つ。`-Xlog` の `file=` と access-log の `directory` が実体パス・`${jboss.server.log.dir}` に） |
| G1 | 今回の版・`T_JAVA_OPTS_GC=1 T_ACCESS_LOG=basedir` | 解消（`relative-to` を外して `directory=${jboss.server.log.dir}`） |
| S2r | `JBOSS_LOG_PIN=off T_ACCESS_LOG=default` | 再現: B の当日分が `access_log.<前日>-1.log` へ（fd で確認）、A の当日分は B のディレクトリの `access_log.log`。A の `access_log.log` は改名されない |
| S2r | 2026-09-27 版・`T_CMD=eap T_JAVA_OPTS_LOG_DIR=1 JBOSS_LOG_PIN=off T_ACCESS_LOG=default`（本番の現状） | 同上（本番の現状で access_log.log にも server.log と同じ症状） |
| S2r | 2026-09-27 版・`T_CMD=eap T_JAVA_OPTS_LOG_DIR=1 T_JAVA_OPTS_GC=1 T_ACCESS_LOG=literal` | server.log は解消、access_log.log は再現 |
| S2r | 今回の版・同上 | 解消（A・B とも自分のディレクトリに `access_log.<前日>.log` と `access_log.log`） |

WildFly 41 での確認は、C: の空き不足（Windows の pagefile.sys が 9.9GB に拡張）のため見送った。

> **「本番の現状」の意味（2026-09-29 追記）:** 上の表の「本番の現状」は、`CMD=eap` で `JAVA_OPTS` に `-Djboss.server.log.dir` がある構成を、**GC ログの明示なし**で動かしたもの。本番の `JAVA_OPTS` には `-Xlog`／`-Xloggc` の明示がある（2026-09-29 確認）ので、本番の gc.log は 4 行目（2026-09-27 版・`T_JAVA_OPTS_GC=1`＝明示あり）と同じく**再現する側**にあたる（明示があると、pin の有無にかかわらず `standalone.sh` は自分の指定を作らない）。本番の access-log は `directory` の指定なし＝`T_ACCESS_LOG=default` と同じ。

## 注意

- 作業場所（`ROTWORK`、既定 `~/rotwork`）は ext4 など POSIX のファイルシステムに置く。WSL で `/mnt/c` 配下に置くと rename や
  シンボリックリンクの振る舞いが Linux と異なり、正しい試験にならない。
- `setup` は wf26 で約 400MB、wf41 で約 500MB を使う。WSL では Ubuntu の仮想ディスク（ext4.vhdx）が膨らむ（ファイルを消しても自動では縮まない）。
  zip の一時置き場を Windows 側にしたい場合は `DL_DIR=/mnt/c/Users/<you>/AppData/Local/Temp` を指定する。
- JVM 1 つあたり 300MB 前後のメモリを使う。WSL の既定メモリ（ホストの半分）では、同時に走らせるシナリオは 3〜4 本まで（最大 JVM 6〜8 個）を目安にする。
  Windows 側でメモリが逼迫すると `pagefile.sys` が拡張されることがある（通常は再起動で元に戻る）。
- Windows から `wsl -- bash -c '…$VAR…'` のように呼ぶと、`$` が WSL 側の既定シェルで先に展開されてしまう。WSL のターミナル内で実行するか、スクリプトファイルにして呼ぶ。
- readonlyRootFilesystem（`--read-only`）と EFS（NFS）そのものは再現しない。前者は Docker 版の `test/rotation/scenario.sh` で、rename と fd の関係は NFS でも同じ。
