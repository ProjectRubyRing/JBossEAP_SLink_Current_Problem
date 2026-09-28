# pin 方式（実体パスへの固定）— JBoss EAP のログをタスクごとに分ける実装

> **最初に読んでください（2026-09-29）**
> - このフォルダは、JBoss EAP の `server.log`（と gc.log・access_log.log）がローテーションのときに**他タスクのファイルを改名してしまう問題**への対策のうち、**「pin 方式」の実装一式**です。
> - GitHub `ProjectRubyRing/ECS_EFS_Dockerfile_Symboliclink_lite` の **main のルート（`docker/`・`docs/`）には、別の対策「コンテナ専用リンク方式」**が入っています。そちらは**そのまま残し**、pin 方式は**ぶつかるファイルも含めて**このフォルダ（同リポジトリでは `pin_method/`）にまとめました。
> - 2 つは**同じ名前のファイルで中身が違います**。1 つのサービスでは**どちらか片方だけ**を使い、base・front・back の 3 つのイメージは**同じフォルダから**ビルドしてください（3 章・5 章）。

> **やさしく言うと:** 教室の入口に「いまのノートはこっち」という案内板（EFS 上の `mid/current`）が 1 枚だけあります。ノートの片付け係（ログのローテーション）は、片付けのたびに案内板を見てノートを探します。あとから来た子が案内板を自分の机に向けると、先にいた子の片付け係は**あとから来た子のノート**に昨日の日付のシールを貼ってしまいます。直し方が 2 通りできました。
> - **pin 方式（このフォルダ）:** 一人ひとりに「あなたのノートの本当の住所」を書いたメモを渡し、片付け係には案内板を見させない。
> - **コンテナ専用リンク方式（ルート）:** 一人ひとりの机の引き出しに「自分専用の案内板」を置き、片付け係にはそちらを見させる。
>
> どちらでも事故は止まります。ただ、道具の名前が同じで中身が違うので、1 つのクラスで両方を混ぜて使うと動きません。

## 目次

1. [置き場所と、2 か所にある理由](#1-置き場所と2-か所にある理由)
2. [呼び方の注意（案 A／案 B）](#2-呼び方の注意案-a案-b)
3. [ぶつかるファイル（同じパスで中身が違う）](#3-ぶつかるファイル同じパスで中身が違う)
4. [2 つの方式の違い](#4-2-つの方式の違い)
5. [混ぜてはいけない組み合わせ](#5-混ぜてはいけない組み合わせ)
6. [このフォルダからビルド・試験する](#6-このフォルダからビルド試験する)
7. [本番の設定への当てはめ（2026-09-29 に確認した事実）](#7-本番の設定への当てはめ2026-09-29-に確認した事実)
8. [正本と写しの同期](#8-正本と写しの同期)
9. [参考資料](#9-参考資料)

---

## 1. 置き場所と、2 か所にある理由

| 置き場所 | 中身 | 役割 |
|---|---|---|
| `ProjectRubyRing/JBossEAP_SLink_Current_Problem` の `ECS_EFS_Dockerfile_Symboliclink_lite/` | pin 方式 | **正本**。調査・実装・試験はこちらで行う |
| `ProjectRubyRing/ECS_EFS_Dockerfile_Symboliclink_lite` の `pin_method/` | pin 方式（正本と同じ内容） | GitHub の main に、コンテナ専用リンク方式と**並べて**置くための写し |
| `ProjectRubyRing/ECS_EFS_Dockerfile_Symboliclink_lite` のルート | コンテナ専用リンク方式（コミット `5f13387`） | main の本体。`pin_method/` を足したときも**ルートのファイルは 1 つも変えていない**（案内用の `README.md` を新しく置いただけ） |

**経緯**

| 日時 | 出来事 |
|---|---|
| 2026-09-27 10:37 | コンテナ専用リンク方式が `ProjectRubyRing/ECS_EFS_Dockerfile_Symboliclink_lite` の main に入った（`5f13387`） |
| 2026-09-27 | 同じ問題に対して、調査用リポジトリで pin 方式を実装し、本物の WildFly で確認した（`eaae068`）。同日午後、本番の起動方式（`CMD=eap`）と本番の `JAVA_OPTS` の `-Djboss.server.log.dir` にも対応した（`5e7343c`） |
| 2026-09-28〜29 | gc.log と Undertow の access_log.log にも同じ対策が要るかを検討した。pin を素通りする明示の書き方を、エントリポイントが実体パスへ揃える処理を追加した |
| 2026-09-29 | 「main のコンテナ専用リンク方式は残し、pin 方式はぶつかるファイルも含めて別フォルダにまとめる」と決め、`pin_method/` を作った |

2 つの方式は `docker/base/entrypoint.sh`・`docker/front/Dockerfile` など**同じファイル**を書き換えます。同じ場所に置くと、どちらかを上書きすることになります。そのため pin 方式は、**このフォルダだけでビルド・試験できる一式**としてフォルダごと分けました。

---

## 2. 呼び方の注意（案 A／案 B）

調査報告書と会話では、pin 方式を「**案 A**」、コンテナ専用リンク方式を「**案 B**」と呼んできました。

一方、`docs/REJECTED_ALTERNATIVES.md`（どちらの方式にもある）は、**別の番号付け**で案 A〜D を並べています。そこでの「案 B」は**「ビルド時に UUID などを焼き込む（不採用）」**で、上の「案 B」とは別物です。混同を避けるため、この README とルートの `README.md` では方式の名前で呼びます。

| この README での名前 | 調査報告書・会話 | `docs/REJECTED_ALTERNATIVES.md` の言葉で言うと |
|---|---|---|
| **pin 方式**（このフォルダ） | 案 A | 案 A'（起動時刻-ランダム8桁の 2 段リンク）はそのままにして、案 C（`-Djboss.server.log.dir` で実体パスを渡す）を組み合わせた形 |
| **コンテナ専用リンク方式**（ルート） | 案 B | 案 A' の名前付けに、案 C（`JBOSS_LOG_DIR`）と案 D（間接リンク）を組み合わせ、間接リンクを既存の `standalone/tmp` に置いた形 |

---

## 3. ぶつかるファイル（同じパスで中身が違う）

| パス | pin 方式（このフォルダ） | コンテナ専用リンク方式（ルート） |
|---|---|---|
| `docker/base/entrypoint.sh` | `mid/<LOG_ID>` を作り、その**実体パス**を `-Djboss.server.log.dir` として JBoss に渡す（起動コマンドの直後に挿入。`standalone/log`・`mid/` を指す明示指定はこれで上書き）。`JBOSS_LOG_DIR` も実体パスにする。`logging.properties` のファイル名を実体パスへ揃える。gc.log（`JAVA_OPTS`・`JAVA_TOOL_OPTIONS`・`JDK_JAVA_OPTIONS` の `-Xlog`／`-Xloggc`）と access-log（`standalone.xml` の `directory`）が共有の置き場を指していれば、実体パスへ書き換える。本番と同じ `CMD=eap` の起動（`standalone.sh -b 0.0.0.0 -bmanagement 0.0.0.0 -c "$SERVER_CONFIG"` ＋ `javax.net.ssl.*` ＋ `$JBOSS_SERVER_OPTS`）を持つ。変数は `LOG_ID_SOURCE`（random／taskid）・`JBOSS_LOG_PIN`（on／off） | `mid/<LOG_ID>` を作り、タスクごとの `standalone/tmp/jboss-log-target` をそこへ張る。`JBOSS_LOG_DIR` を実体パスにする（`-Djboss.server.log.dir` は足さない）。最後は `exec "$@"`（`CMD=eap` の起動処理は無い）。変数は `LOG_ID_MODE`（timestamp／taskid）・`LOG_LINK_STRICT`（0／1） |
| `docker/base/entrypoint.taskid.sh` | `LOG_ID_SOURCE=taskid` を付けて `efs-entrypoint.sh` を呼ぶラッパー。自分自身を呼ぶ誤設定は FATAL | `LOG_ID_MODE=taskid` を付けて `efs-entrypoint.sh` を呼ぶラッパー。`efs-entrypoint.sh` という名前で置くと FATAL |
| `docker/base/Dockerfile` | 2 つのエントリポイントを COPY。`ENV SERVER_CONFIG=standalone.xml`・`EXTRASLB_TRUSTSTORE_TYPE=JKS` | 2 つのエントリポイントを COPY |
| `docker/front/Dockerfile`・`docker/back/Dockerfile` | `standalone/log → /mnt/logs/<Component_name>/logs/<Service_Name>/mid/current`（従来のまま。人やログ収集の入口として残す）。`CMD ["eap"]` | `standalone/log → tmp/jboss-log-target`（相対リンク）。`CMD ["/opt/jboss-eap/bin/standalone.sh", "-b", "0.0.0.0"]` |
| `docs/DESIGN.md`・`docs/REJECTED_ALTERNATIVES.md`・`docs/TROUBLESHOOTING.md` | pin 方式の説明 | コンテナ専用リンク方式の説明 |

**片方にしか無いもの**

| pin 方式だけ | コンテナ専用リンク方式だけ |
|---|---|
| `docs/LOG_ROTATION.md`（仕組み・実機検証・gc.log と access_log.log）、`test/local/`（Docker を使わない単体試験と実機試験）、`test/rotation/`（Docker 版の実機試験）、`.gitattributes`、この `README.md` | `docs/SERVER_LOG_DATE_ROLLOVER.md`・`.xlsx`（説明書）、`docker/base/tests/rotation_isolation_test.sh`（試験） |

**同じ内容のもの:** `docs/CP_PRESERVE_OWNERSHIP.md`（どちらも 2026-08-27 の `dfe0282` のまま）。

---

## 4. 2 つの方式の違い

| 項目 | pin 方式（このフォルダ） | コンテナ専用リンク方式（ルート） |
|---|---|---|
| JBoss が書くパス | `-Djboss.server.log.dir=/mnt/logs/…/mid/<LOG_ID>`（実体パスそのもの） | `/opt/jboss-eap/standalone/log/…` → `standalone/tmp/jboss-log-target`（タスクごと）→ `mid/<LOG_ID>` |
| EFS の `mid/current` の役割 | 「最後に起動したタスク」を人が見るための目印。JBoss は通らない | 同じ |
| イメージのリンク | 変えない（`standalone/log → …/mid/current`） | 変える（`→ tmp/jboss-log-target`）。front と back の再ビルドが要る |
| タスク定義の前提 | 変更なし（`entryPoint` を上書きする場合は、イメージの `CMD` が引き継がれないので `command: ["eap"]` も指定する。`command` を上書きしている場合も `["eap"]` にする） | `standalone/tmp` が、タスクごとの書き込み可能なボリュームであること（JBoss の起動にもともと必要） |
| ECS Exec で `/opt/jboss-eap/standalone/log` を見ると | 最後に起動したタスクのログ（`current` の先）。自分のログは `mid/<LOG_ID>` にある | 自分のログ |
| 本番の起動方式（`CMD=eap`） | 入っている（`docs/LOG_ROTATION.md` 10-1。実機で確認） | 入っていない。本番で使うには、本番のエントリポイントの起動処理と合わせる作業が別に要る |
| 本番の `JAVA_OPTS` の `-Djboss.server.log.dir=${JBOSS_HOME}/standalone/log` | 共有の置き場を指すので、起動引数の実体パスで上書きする（実機で確認） | そのパスがタスクごとのリンクを通るので、自分のディレクトリになる（仕組みからの判断） |
| gc.log（本番は `JAVA_OPTS` に `-Xlog`／`-Xloggc` の明示あり） | 出力先が `standalone/log`・`mid/` の下なら、エントリポイントがそのパス部分を実体パスへ書き換える（起動ログに `note` 行。WildFly 26.1.3 で実機確認） | 出力先が `/opt/jboss-eap/standalone/log` の下なら、タスクごとのリンクを通るので自分のディレクトリになる（仕組みからの判断。実機では未確認） |
| access_log.log（本番は `directory` の指定なし） | 既定の `${jboss.server.log.dir}` が pin の実体パスになる（実機で確認）。`directory` を明示した場合も書き換える | `${jboss.server.log.dir}` が `/opt/jboss-eap/standalone/log` を指すので、タスクごとのリンクを通って自分のディレクトリになる（仕組みからの判断。実機では未確認） |
| 試験 | 単体試験 333 項目（dash／bash --posix／busybox sh）。本物の WildFly での実機試験（0 時をまたぐ試験は 26.1.3 と 41.0.1、GC ログと access_log.log の試験は 26.1.3） | `docker/base/tests/rotation_isolation_test.sh`（JBoss は起動せず、ハンドラと同じ 3 手を再現する） |

---

## 5. 混ぜてはいけない組み合わせ

| 組み合わせ | どうなるか |
|---|---|
| pin 方式の base ＋ ルートの front／back | front／back のリンク先 `tmp/jboss-log-target` を pin 方式は作らない。エントリポイントが「dangling symlink」として FATAL にし、起動しない（コードからの判断） |
| ルートの base ＋ pin 方式の front／back | front／back の `CMD ["eap"]` を、ルートのエントリポイントは解釈できない（`exec eap` になる）ので起動しない。CMD を直しても、リンクが `current` のままなので `server.log` は直らない（下の注意）（コードからの判断） |
| pin 方式のイメージに `LOG_ID_MODE` を渡す。ルートのイメージに `LOG_ID_SOURCE`・`JBOSS_LOG_PIN` を渡す | 黙って無視される（エラーにならない）。タスク ID 名にしたいときは、それぞれの方式の変数を使うか、どちらのイメージにもあるラッパー `efs-entrypoint-taskid.sh` を ENTRYPOINT にする |
| 同じタグ（例 `myapp-base:latest`）で両方をビルドする | 後からビルドした方で上書きされる。各 Dockerfile のビルド例はどちらも同じタグなので、pin 方式は `:pin` などに分け、front／back の `BASE_IMAGE` も pin 方式の base を指す |
| 同じサービスで方式を切り替える（ローリングデプロイで新旧のタスクが並ぶ） | pin 方式のタスクもコンテナ専用リンク方式のタスクも、自分の `mid/<LOG_ID>` へ直接書き、`current` を通らない。並んでも互いのファイルには触れない（仕組みからの判断）。危ないのは**修正前のイメージ**（`current` 経由で書く）のタスクが 0 時をまたいで残る場合で、これはどちらの方式へ切り替えるときも同じ。切り替えのデプロイは日中に行い、0 時（JVM のタイムゾーン）までに修正前のタスクがすべて止まったことを確かめる |

> **注意（コンテナ専用リンク方式を、リンクが `current` のままのイメージで使う場合）:** ルートのエントリポイントは警告を出して起動し、コメントでは「`JBOSS_LOG_DIR` を実ディレクトリにするので同じ事故は避けられる」と説明しています。ところが WildFly Core の `standalone.sh` が `JBOSS_LOG_DIR` を使うのは、ブートログ（`-Dorg.jboss.boot.log.file`）と gc.log の出力先だけです（WildFly Core 18.1.2.Final の `bin/standalone.sh` で確認）。logging サブシステムが動き出した後の `server.log`（`relative-to="jboss.server.log.dir"`）は `current` 経由のまま残ります。front／back を作り直すまでは、`LOG_LINK_STRICT=1` で起動を止める方が安全です。

---

## 6. このフォルダからビルド・試験する

各ファイルのコメントにあるコマンドは、**このフォルダを起点にした相対パス**です。元リポジトリでは `pin_method/`、調査用リポジトリでは `ECS_EFS_Dockerfile_Symboliclink_lite/` に移動してから実行します。

```sh
cd pin_method      # 調査用リポジトリなら cd ECS_EFS_Dockerfile_Symboliclink_lite

# イメージ（タグはコンテナ専用リンク方式と分ける）
docker build -t myapp-base:pin --build-arg STRICT_SEED=1 docker/base
docker build -t intra-web-front:pin \
  --build-arg BASE_IMAGE=myapp-base:pin \
  --build-arg Service_Name=intra-web \
  --build-arg Component_name=intra-web-front \
  docker/front
docker build -t intra-api-back:pin \
  --build-arg BASE_IMAGE=myapp-base:pin \
  --build-arg Service_Name=intra-api \
  --build-arg Component_name=intra-api-back \
  docker/back

# エントリポイントの単体試験（Docker 不要。Linux／WSL で 2〜4 分）
bash test/local/entrypoint_test.sh
```

- 本物の WildFly で 0 時をまたぐ試験: `test/local/README.md`（Docker 不要）、`test/rotation/README.md`（Docker 版）
- デプロイ手順・確認方法・移行時の注意: `docs/LOG_ROTATION.md` 10 章、`docs/TROUBLESHOOTING.md` 7 章・8 章

---

## 7. 本番の設定への当てはめ（2026-09-29 に確認した事実）

| 本番の設定 | pin 方式での扱い |
|---|---|
| 起動は `CMD=eap`（エントリポイントの最後で `standalone.sh` を組み立てる） | 同じ起動処理を持つ（`docs/LOG_ROTATION.md` 10-1） |
| `JAVA_OPTS` に `-Djboss.server.log.dir=${JBOSS_HOME}/standalone/log` | 共有の置き場を指すので、起動引数の先頭に置く実体パスの `-Djboss.server.log.dir` で上書きする |
| `JAVA_OPTS` に `-Xlog`／`-Xloggc` の明示がある | 出力先が `standalone/log`・`mid/` の下なら、そのパス部分だけを実体パスへ書き換え、起動ログに `note: 共有の置き場を指す GC ログの指定 (…) を … へ書き換えました` を出す。**修正前の今の本番でも、gc.log の事故は起き得る**（`standalone.sh` は明示があると自分の指定を作らないため。JDK 11 では `-Xloggc` も `-Xlog` と同じ仕組みになり、何も書かなければ 20MB × 5 ファイルで回す） |
| `standalone.xml` の access-log に `directory` の指定がない | 既定の `${jboss.server.log.dir}` が pin の実体パスになる。書き換えるものはないので、access-log の `note` 行は出ない |

書き換えの対象にならない書き方（相対パス、`$JBOSS_HOME` のような変数を文字のまま書いた値、`bin/standalone.conf` の中の指定）と、その見分け方は `docs/LOG_ROTATION.md` 10-2 にまとめています。

---

## 8. 正本と写しの同期

- **変更は正本（調査用リポジトリの `ECS_EFS_Dockerfile_Symboliclink_lite/`）で行い、試験してから `pin_method/` へ写します。** `pin_method/` だけを直すと 2 つがずれます。
- 写し方と、ずれていないかの確かめ方（Git Bash。`<…>` は各自のクローン先）:

```sh
SRC=<調査用リポジトリ>/ECS_EFS_Dockerfile_Symboliclink_lite
DST=<ECS_EFS_Dockerfile_Symboliclink_lite リポジトリ>/pin_method
cp -r "$SRC"/. "$DST"/                                   # 追加・上書き（消したファイルは消えない）
diff -r --strip-trailing-cr "$SRC" "$DST" && echo "同じ内容"   # 差があれば表示される（消し忘れもここで分かる）
```

- Windows（`core.filemode=false`）で新しく git に登録するときは、試験スクリプトに実行権限を付けます: `git add --chmod=+x pin_method/test/local/*.sh pin_method/test/rotation/*.sh`

---

## 9. 参考資料

| 資料 | 置き場所 | 内容 |
|---|---|---|
| `docs/LOG_ROTATION.md` | このフォルダ | pin 方式の仕組み、本番の起動方式への対応（10-1）、gc.log と access_log.log（10-2）、実機検証 |
| `JBossEAP_serverlog_rotation_current_link.md`／`.xlsx` | 調査用リポジトリの直下 | server.log が前日付のファイルに書かれ続ける原因の調査報告書（案 A＝pin 方式・案 B＝コンテナ専用リンク方式の比較を含む） |
| `JBossEAP_gclog_accesslog_rotation_検討.md`／`.xlsx` | 同上 | gc.log と access_log.log の調査報告書 |
| `JBossEAP_serverlog_rotation_修正箇所まとめ.md` | 同上 | pin 方式の変更箇所の一覧。14 章にこのフォルダ分けの記録 |
| `docs/SERVER_LOG_DATE_ROLLOVER.md` | 元リポジトリのルート | コンテナ専用リンク方式の説明書 |
