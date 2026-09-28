# server.log 日次ローテーションの再現・回帰試験（検証専用）

`current` を共有したまま JBoss が日付変更時にローテーションすると、他タスクの
`server.log` を前日付へ改名・上書きしてしまう問題（[`docs/LOG_ROTATION.md`](../../docs/LOG_ROTATION.md)）を、
ローカルの Docker で再現し、修正（`JBOSS_LOG_PIN=on`）で起きないことを確かめるためのスクリプト。
**本番イメージには含めない。**

## 仕組み

- JBoss EAP の代わりにアップストリームの WildFly を `/opt/jboss-eap` に置いた「疑似 EAP」
  （`fake-eap/Dockerfile`）をベースに、本リポジトリの `docker/base` → `docker/front` をそのままビルドする。
- ECS と同じ条件で起動する: `--read-only`（readonlyRootFilesystem）、`--tmpfs` で
  configuration / tmp / data（中身がコピーされない空のタスクローカルボリューム）、
  共有の Docker ボリューム `/mnt/logs`（EFS 役）。コンテナ A / B が旧タスク / 新タスク。
- 0 時を待たずに済むよう、**JVM のタイムゾーンだけ**を `GMT±hh:mm` にずらし、
  数分後が JVM にとっての 0 時になるようにする（時計そのものは実時刻）。
- 検証用 JSP（`/ticker/log.jsp?who=…`）で任意の時点に `TICK who=…` を 1 行出し、
  最後に共有ボリューム上の `mid/*/server.log*` の中身と `/proc/<java>/fd` を記録する。
- 【2026-09-28】検証用 WAR には `gc.jsp`（`?op=gc` で GC を起こす、`?op=rotate` で GC ログを今すぐ
  ローテーションさせる）も入る。gc.log と access_log.log の試験（G1 シナリオ、access-log の有効化、
  GC ログの明示指定、GC_LOG=true）は Docker を使わない `test/local/rotation_local.sh` にだけ入れた
  （`test/local/README.md`・`docs/LOG_ROTATION.md` 10-2）。
- front／back のイメージの CMD は本番と同じ `eap`（エントリポイントが `standalone.sh -b 0.0.0.0
  -bmanagement 0.0.0.0 -c "${SERVER_CONFIG}" …` で起動する）。`SERVER_CONFIG=standalone.xml` と
  `EXTRASLB_TRUSTSTORE_TYPE=JKS` は base の Dockerfile の ENV で入る。本番と同じく `JAVA_OPTS` に
  `-Djboss.server.log.dir=/opt/jboss-eap/standalone/log` を入れた状態を試すには、`scenario.sh` の
  `-e JAVA_OPTS=…` の末尾にその指定を足す（Docker を使わない `test/local/rotation_local.sh` では
  `T_JAVA_OPTS_LOG_DIR=1` で同じことができる。2026-09-27 に実施した結果は `test/local/README.md`）。

## 使い方

```bash
cd test/rotation
python fake-eap/make_ticker_war.py && mv ticker.war fake-eap/

# 疑似 EAP → base → front (EAP 7.4 相当の WildFly 26.1.3 の例。EAP 8.x 相当は quay.io/wildfly/wildfly:latest)
docker build -t rot-fake-eap:wf26 --build-arg WILDFLY_IMAGE=quay.io/wildfly/wildfly:26.1.3.Final-jdk11 fake-eap
docker build -t rot-base:wf26  --build-arg BASE_IMAGE=rot-fake-eap:wf26 --build-arg STRICT_SEED=1 ../../docker/base
docker build -t rot-front:wf26 --build-arg BASE_IMAGE=rot-base:wf26 \
  --build-arg Service_Name=intra-web --build-arg Component_name=intra-web-front ../../docker/front

# 引数: 0 時までの秒数、"シナリオ イメージ ラベル [docker run の追加引数...]" を並べる (並行実行)
./batch.sh 215 "S1 rot-front:wf26 fixed-S1" "S1 rot-front:wf26 legacy-S1 -e JBOSS_LOG_PIN=off"
cat results/fixed-S1.log results/legacy-S1.log
```

| シナリオ | 内容 | 実施状況 |
|---|---|---|
| `S1` | 旧タスク A が 0 時をまたいで稼働 → 0 時後に新タスク B が起動 → A を停止（ご報告のケース） | 修正前 (WildFly 26.1.3 / 41.0.1)・修正後 (26.1.3) で実施 |
| `S2` | A・B が 0 時をまたいで稼働し、A が先にログを書く | 修正前・修正後 (26.1.3) で実施 |
| `S2r` | 同上で B が先にログを書く | 修正前 (26.1.3) で実施 |
| `R1` | 0 時とは無関係。旧タスク A の `:reload` と `:shutdown(restart=true)` | 未実施 |
| `R2` | 0 時前にクラッシュ → 0 時後に同じコンテナを再起動（ECS restartPolicy 相当）。`--network <label>-net -e LOG_ID_SOURCE=taskid -e ECS_CONTAINER_METADATA_URI_V4=http://<label>-meta:8000/v4/fake` を付けるとタスク ID 方式（`--entrypoint` で上書きするとイメージの CMD `eap` が消えて起動コマンドが空になるため、環境変数で切り替える） | 未実施 |

期待する結果: `JBOSS_LOG_PIN=on`（既定）では、各 `mid/<LOG_ID>/` に自分の
`server.log.<前日>` と `server.log` だけが並ぶ。`JBOSS_LOG_PIN=off`（旧挙動）では、
新タスクのディレクトリに `server.log.<前日>`（中身は当日のログ）と旧タスクの停止ログ入りの
`server.log` ができ、S2 / S2r では新タスクの前日分が消える。

## 注意

- WildFly のイメージは 1 つ 800MB 前後、疑似 EAP のビルドでさらに数百 MB 使う。
  ホストのディスク（Docker Desktop なら仮想ディスクの置き場所）に数 GB の空きを確保してから実行すること。
- 共有ボリュームは EFS ではなく同一ホストの Docker ボリューム。rename と fd の関係は NFS でも同じだが、
  NFS 固有の属性キャッシュや ESTALE は再現しない。
- 後片付け: `docker rmi rot-front:wf26 rot-base:wf26 rot-fake-eap:wf26` とビルドキャッシュ。
