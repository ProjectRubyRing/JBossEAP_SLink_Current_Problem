# Docker を使わない検証（Linux / WSL）

`test/rotation/`（Docker 版）と同じ確認を、**Docker を使わずに** Linux や WSL（Ubuntu）で行うためのスクリプト。
Docker Desktop の仮想ディスクが膨らんで PC の空き容量を圧迫する環境向け。**本番イメージには含めない。**

| スクリプト | 何を確かめるか | 必要なもの | 所要時間 |
|---|---|---|---|
| `entrypoint_test.sh` | `docker/base/entrypoint.sh` と `entrypoint.taskid.sh` の分岐（pin の付与、明示指定の優先、不正値の停止、taskid の取得とフォールバック、logging.properties の書き換え、並行起動 など） | bash、python3、curl（JBoss・Java は不要） | 1〜2 分 |
| `rotation_local.sh` | 本物の WildFly（JBoss EAP のアップストリーム）を「ECS タスク相当」のプロセスとして複数起動し、JVM のタイムゾーン上の 0 時をまたいだ `server.log` の挙動 | bash、curl、unzip、tar、python3、ps。JRE と WildFly は `setup` が取得 | 1 シナリオ 5 分前後 |

## entrypoint_test.sh

```bash
test/local/entrypoint_test.sh                 # dash / bash --posix / busybox sh のうち入っているもの全部で実行
test/local/entrypoint_test.sh "bash --posix"  # シェルを指定
```

最後に `RESULT: PASS=… FAIL=0` と出れば合格（失敗があると終了コード 1）。
2026-09-27 に WSL（Ubuntu 22.04）で `dash`・`bash --posix`・`busybox sh` の 3 種類を試し、**PASS=135 FAIL=0**。

主な確認項目:

| # | ケース | 期待する動作 |
|---|---|---|
| 1 | 既定（`JBOSS_LOG_PIN=on`）＋ CMD が `…/standalone.sh` | コマンド直後に `-Djboss.server.log.dir=<mid/<LOG_ID> の実体パス>` を挿入。元の引数は順序・空白とも保持。`JBOSS_LOG_DIR` も実体パス |
| 2 | CMD が standalone.sh 以外 | WARN のみ（引数は変えない）。`JBOSS_LOG_DIR` は export |
| 3 | `-Djboss.server.log.dir` を引数か `JAVA_OPTS` で明示 | 明示を優先して pin しない（WARN） |
| 4 | `JBOSS_LOG_PIN=off` | 従来どおり current 経由（WARN） |
| 5・6 | `JBOSS_LOG_PIN` / `LOG_ID_SOURCE` の不正値 | FATAL で停止。**current も mid も configuration も触らない** |
| 7 | `LOG_ID_SOURCE=taskid` | メタデータ v4 の TaskARN（新形式・旧形式・整形 JSON）からタスク ID。取れない・不正な文字を含むときは random で代替。2 回目の起動（restartPolicy 相当）は同じディレクトリを再利用 |
| 8 | 互換ラッパー `efs-entrypoint-taskid.sh` | `LOG_ID_SOURCE=taskid` で本体を実行。誤って `efs-entrypoint.sh` の名前で置いても無限 exec せず FATAL（user+mount 名前空間で `/usr/local/bin` に tmpfs を重ねて確認。使えない環境では SKIP） |
| 9 | `logging.properties` に `standalone/log/…`・`mid/current/…`・前回 `mid/<ID>/…` の絶対パス | 今回の実体パスへ書き換え。無関係なパスはそのまま |
| 10 | 8 本を同時に起動 | 全員が別々の LOG_ID を作り、各自が**自分の**実体パスを受け取る（current は 1 本だけ） |
| 11〜14 | standalone/log が別タスクを指す／dangling、EFS 側がシンボリックリンク経由、seed・logging.properties 欠落 | 順に note のみ／FATAL／物理パスを渡す／FATAL |

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

# 3) 後片付け (JRE・WildFly・結果をすべて削除)
test/local/rotation_local.sh clean
```

| シナリオ | 内容 |
|---|---|
| `S1` | 旧タスク A が 0 時をまたいで稼働 → 0 時後に新タスク B が起動 → A を停止（ご報告のケース） |
| `S2` / `S2r` | A・B が 0 時をまたいで稼働し、A（S2）／B（S2r）が先にログを書く |
| `R1` | 0 時とは無関係。B の起動後に A を `:reload`、続いて `:shutdown(restart=true)`（JVM だけの再起動） |
| `R2` | 0 時前に A がクラッシュ（kill -9）→ 0 時後に同じタスクのコンテナとして再起動（ECS restartPolicy 相当）。`LOG_ID_SOURCE=taskid` を付けるとタスク ID 方式 |

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

## 注意

- 作業場所（`ROTWORK`、既定 `~/rotwork`）は ext4 など POSIX のファイルシステムに置く。WSL で `/mnt/c` 配下に置くと rename や
  シンボリックリンクの振る舞いが Linux と異なり、正しい試験にならない。
- `setup` は wf26 で約 400MB、wf41 で約 500MB を使う。WSL では Ubuntu の仮想ディスク（ext4.vhdx）が膨らむ（ファイルを消しても自動では縮まない）。
  zip の一時置き場を Windows 側にしたい場合は `DL_DIR=/mnt/c/Users/<you>/AppData/Local/Temp` を指定する。
- JVM 1 つあたり 300MB 前後のメモリを使う。WSL の既定メモリ（ホストの半分）では、同時に走らせるシナリオは 3〜4 本まで（最大 JVM 6〜8 個）を目安にする。
  Windows 側でメモリが逼迫すると `pagefile.sys` が拡張されることがある（通常は再起動で元に戻る）。
- Windows から `wsl -- bash -c '…$VAR…'` のように呼ぶと、`$` が WSL 側の既定シェルで先に展開されてしまう。WSL のターミナル内で実行するか、スクリプトファイルにして呼ぶ。
- readonlyRootFilesystem（`--read-only`）と EFS（NFS）そのものは再現しない。前者は Docker 版の `test/rotation/scenario.sh` で、rename と fd の関係は NFS でも同じ。
