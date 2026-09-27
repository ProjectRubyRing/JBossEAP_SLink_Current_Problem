# ECS_EFS_Dockerfile_Symboliclink_lite 修正箇所まとめ — server.log が日付変更後も前日付ファイルに追記される問題の実装

| 項目 | 内容 |
|---|---|
| 目的 | `JBossEAP_serverlog_rotation_current_link.md` / `.xlsx` の「8 章 案 A（実体パスへの固定＝pin）【採用】」と「10 章 実装内容」を、**そのまま動く状態**でこのフォルダに置く。元の `ECS_EFS_Dockerfile_Symboliclink_lite` フォルダにも同じ修正を入れる |
| このフォルダで管理する実装 | `JBossEAP_SLink_Current_Problem/ECS_EFS_Dockerfile_Symboliclink_lite/`（入れ子の git リポジトリではなく、**このリポジトリの普通のファイル**として管理） |
| 元フォルダ | `C:\Users\taka_\Claude\ECS_EFS_Dockerfile_Symboliclink_lite`（同じファイルを適用。**ステージ済み・未コミット**） |
| 修正の基点 | GitHub `ProjectRubyRing/ECS_EFS_Dockerfile_Symboliclink_lite` の `dfe0282`（2026-08-27 の PR #2 マージ。md/xlsx の実装と実機検証はこの版の上で行われた） |
| 変更量 | 既存 8 ファイル **+515 行／−204 行**、変更なし 1 ファイル、新規 11 ファイル（md/xlsx 記載の新規 7 ＋ 今回追加 4） |
| 動作確認（今回実施） | 静的検査（shellcheck・構文）／エントリポイント単体試験 **135 項目すべて合格**（dash・bash --posix・busybox sh）／本物の WildFly での実機試験 **10 シナリオすべて期待どおり**（WildFly 26.1.3 ≒ EAP 7.4、41.0.1 ≒ EAP 8.x）。md/xlsx で「未実施」だった項目もすべて確認済みになった |
| 作成日 | 2026-09-27 |

## 目次

1. [結論（まずここだけ）](#1-結論まずここだけ)
2. [どこに何を置いたか（フォルダ構成）](#2-どこに何を置いたかフォルダ構成)
3. [修正箇所一覧（ファイル別）](#3-修正箇所一覧ファイル別)
4. [修正箇所の詳細（変更前 → 変更後）](#4-修正箇所の詳細変更前--変更後)
5. [環境変数（新設・変更）](#5-環境変数新設変更)
6. [修正後の処理の流れと、書き込み経路の違い](#6-修正後の処理の流れと書き込み経路の違い)
7. [動作確認の結果（2026-09-27 実施）](#7-動作確認の結果2026-09-27-実施)
8. [使い方（ビルド・デプロイ・確認・移行）](#8-使い方ビルドデプロイ確認移行)
9. [元フォルダで行ったことと、GitHub の main との関係（要判断）](#9-元フォルダで行ったことと-github-の-main-との関係要判断)
10. [このフォルダ（JBossEAP_SLink_Current_Problem）の git 上の扱い](#10-このフォルダjbosseap_slink_current_problemの-git-上の扱い)
11. [作業中に気付いた PC 側の注意](#11-作業中に気付いた-pc-側の注意)

---

## 1. 結論（まずここだけ）

> **やさしく言うと:** みんなで 1 枚だけ共有している案内板（`current`）を見てノートを片付けるから、よその子のノートに昨日の日付シールを貼ってしまっていました。そこで、起動するときに「あなたの机はここ」と**本当の住所**を JBoss に直接教えるようにしました。案内板は「最後に来た子の机」を知るための目印として残しますが、片付け（ローテーション）には使いません。

- **何を直したか**: `docker/base/entrypoint.sh` が、JBoss を起動する直前に
  - 自分専用のディレクトリ `mid/<LOG_ID>` の**実体パス**を `current` を通らずに求め（`cd … && pwd -P`）、
  - `standalone.sh` の引数の先頭に `-Djboss.server.log.dir=<実体パス>` を差し込み、
  - `JBOSS_LOG_DIR=<実体パス>` を export し、
  - `logging.properties` に残った `current` 経由・前回 `LOG_ID` のパスを実体パスへ揃える。
  → JBoss の日次ローテーション（rename と再 open）は**常に自分のディレクトリの中だけ**で行われ、他タスクのファイルに触れなくなった。
- **旧実装（ECS タスク ID 方式）**は同じ `entrypoint.sh` に統合した（`LOG_ID_SOURCE=taskid`）。`entrypoint.taskid.sh` は互換ラッパーになり、どちらの方式でも configuration の復元・fail-fast・pin が必ず効く。
- **置き場所**: このフォルダの `ECS_EFS_Dockerfile_Symboliclink_lite/` と、元フォルダの両方に**同一内容**で置いた（git に登録される内容＝全 20 ファイルのモードとハッシュが一致することを確認）。
- **動作確認**: 本物の WildFly を「ECS タスク相当」で 2 つ動かし、JVM の 0 時をまたがせて確認した。修正後は、ご報告の症状（新タスクが前日付ファイルへ追記）も、前日分の消失も起きない。`JBOSS_LOG_PIN=off`（修正前の挙動）にすると、どちらも再現する（7 章）。
- **要判断（9 章）**: GitHub の `main` には、今日 10:37 付けのコミットとして別方式の実装（`5f13387`、3 段リンク方式＝md の「案 B」）が入っている。元フォルダはその 1 つ前（`dfe0282`）の上に今回の修正（案 A）を載せた状態で、**まだコミットも push もしていない**。どちらの方式を正とするか決めてから push すること。

---

## 2. どこに何を置いたか（フォルダ構成）

> **やさしく言うと:** 「★」が中身を直したファイル、「＋」が新しく作ったファイルです。

```
JBossEAP_SLink_Current_Problem/                      (このリポジトリ)
├── JBossEAP_serverlog_rotation_current_link.md      調査報告書 (変更なし)
├── JBossEAP_serverlog_rotation_current_link.xlsx    調査報告書 (変更なし)
├── JBossEAP_serverlog_rotation_修正箇所まとめ.md     ＋ 本書
└── ECS_EFS_Dockerfile_Symboliclink_lite/             ＋ 実装一式 (元フォルダと同一内容)
    ├── .gitattributes                                ＋ [今回追加] *.sh を LF で取り出す
    ├── docker/
    │   ├── base/
    │   │   ├── Dockerfile                            ★ 2 本のエントリポイントをイメージへ
    │   │   ├── entrypoint.sh                         ★ 本体: 3-B pin・LOG_ID_SOURCE・事前検証の見直し
    │   │   └── entrypoint.taskid.sh                  ★ 別実装 → 互換ラッパー (45 行)
    │   ├── front/Dockerfile                          ★ コメントのみ (リンクの作り方は不変)
    │   └── back/Dockerfile                           ★ コメントのみ (リンクの作り方は不変)
    ├── docs/
    │   ├── CP_PRESERVE_OWNERSHIP.md                  ・ 変更なし
    │   ├── DESIGN.md                                 ★ current の位置づけ・6 章 1 の訂正・pin の説明
    │   ├── LOG_ROTATION.md                           ＋ 調査報告書 (md) と同一
    │   ├── REJECTED_ALTERNATIVES.md                  ★ 案 C を A/A' と併用で採用
    │   └── TROUBLESHOOTING.md                        ★ 5-4 の差し替え・7 章 (本症状の切り分け) 追加
    └── test/
        ├── rotation/                                 ＋ Docker 版の再現・回帰試験 (md 7 章)
        │   ├── README.md / .gitignore
        │   ├── scenario.sh / batch.sh
        │   └── fake-eap/Dockerfile / make_ticker_war.py
        └── local/                                    ＋ [今回追加] Docker を使わない試験
            ├── README.md
            ├── entrypoint_test.sh                    エントリポイントの分岐試験 (JBoss 不要)
            └── rotation_local.sh                     本物の WildFly で 0 時をまたぐ試験 (Docker 不要)
```

---

## 3. 修正箇所一覧（ファイル別）

> **やさしく言うと:** 動きが変わるのは `entrypoint.sh` と `entrypoint.taskid.sh`（と、それをイメージに入れる `base/Dockerfile`）だけです。残りは説明書きと試験道具です。

| ファイル | 区分 | 行数（+／−） | 何を変えたか | md/xlsx の該当箇所 |
|---|---|---|---|---|
| `docker/base/entrypoint.sh` | ★変更（動作） | +242／−40 | ①「3-B. 実体パスへの固定（pin）」を追加 ②`LOG_ID_SOURCE`（random／taskid）で旧タスク ID 方式を統合 ③事前検証を「自分の実体ディレクトリに書けるか」に変更 ④不正な環境変数は `current` を触る前に停止 ⑤`logging.properties` のパス揃え | 10 章 表 1 行目、8 章 案 A |
| `docker/base/entrypoint.taskid.sh` | ★変更（動作） | +33／−86 | 別実装をやめ、`LOG_ID_SOURCE=taskid` で本体を呼ぶ互換ラッパーに。自分自身を呼ぶ誤設定は FATAL | 10 章 表 2 行目 |
| `docker/base/Dockerfile` | ★変更（動作） | +14／−8 | `efs-entrypoint.sh` と `efs-entrypoint-taskid.sh` の両方をイメージへ COPY・chmod・CR 除去 | 10 章 表 3 行目 |
| `docker/front/Dockerfile` | ★変更（コメント） | +7／−2 | リンクは入口として残し、JBoss は実体パスへ書く旨を明記。リンクの作り方は変更なし | 10 章 表 4 行目 |
| `docker/back/Dockerfile` | ★変更（コメント） | +5／−3 | 同上 | 10 章 表 4 行目 |
| `docs/DESIGN.md` | ★変更（文書） | +90／−32 | current の位置づけ、pin の説明、6 章 1 の評価の訂正、タスク定義例に `LOG_ID_SOURCE`・`JBOSS_LOG_PIN`・`TZ` | 10 章 表 7 行目 |
| `docs/REJECTED_ALTERNATIVES.md` | ★変更（文書） | +53／−27 | 案 C（`-Djboss.server.log.dir`）を A／A' と組み合わせて採用、比較表の更新 | 10 章 表 7 行目 |
| `docs/TROUBLESHOOTING.md` | ★変更（文書） | +71／−6 | 5-4（タスク ID 方式への切り替え）の差し替え、7 章「前日付の server.log に追記され続ける」の切り分け、チェックリスト追加 | 10 章 表 7 行目 |
| `docs/LOG_ROTATION.md` | ＋新規 | 894 行 | 調査報告書 `JBossEAP_serverlog_rotation_current_link.md` と**同一**（バイト比較で一致） | 10 章 表 5 行目 |
| `test/rotation/*`（6 ファイル） | ＋新規 | 265 行 | Docker 版の再現・回帰試験（WildFly を使った疑似 EAP。S1／S2／S2r／R1／R2、`JBOSS_LOG_PIN=on／off`）。本番イメージには含めない | 10 章 表 6 行目、7 章 |
| `test/local/*`（3 ファイル） | ＋新規【今回追加】 | — | Docker を使わない試験（エントリポイント単体試験、WildFly を使った 0 時またぎ試験）。7 章の結果はこれで取得 | md/xlsx 記載外 |
| `.gitattributes` | ＋新規【今回追加】 | 4 行 | `*.sh text eol=lf`。Windows（`core.autocrlf=true`）でチェックアウトしてもシェルスクリプトが CRLF にならないようにする | md/xlsx 記載外 |
| `docs/CP_PRESERVE_OWNERSHIP.md` | ・変更なし | 0 | — | — |

> **md/xlsx 記載外の追加について:** `test/local/` と `.gitattributes` は、今回「完全に動作する状態」を確かめ、今後もこのフォルダで確かめ直せるようにするために足したもので、本番の動作には関係しません（イメージにも入りません）。

---

## 4. 修正箇所の詳細（変更前 → 変更後）

### 4-1. `docker/base/entrypoint.sh`（410 行 → 612 行。行番号は修正後）

> **やさしく言うと:** 「机を決める → 案内板を書き換える」までは今までどおり。その直後に「あなたの本当の住所はここ」と JBoss に渡す処理（3-B）を足しました。

| 行 | 区分 | 内容 |
|---|---|---|
| 1〜97 | コメント | 「3-B」の説明、pin が必要な理由（`current` 共有 × close → パスで rename → パスで再 open）、`LOG_ID_SOURCE`／`JBOSS_LOG_PIN` の説明を追記 |
| 167〜177 | **新規** | `0-2. 切り替え用の環境変数の検証`：`LOG_ID_SOURCE`（random／taskid）と `JBOSS_LOG_PIN`（on／off）が不正なら、**`current` を張り替える前に** FATAL で停止（設定ミスのタスクが `current` だけ書き換えて止まると、移行期に並走している pin の無い旧イメージのタスクの 0 時処理が、その止まったタスクのディレクトリへ向いてしまうため） |
| 205〜232 | **新規** | `fetch_task_id()`：メタデータ v4 の `/task` から TaskARN を取り出し、最後の `/` 以降をタスク ID に。curl／wget 両対応、3 回まで再試行、英数字とハイフン以外を含む値は採用しない |
| 234〜242 | **新規** | `has_log_dir_opt()`：`-Djboss.server.log.dir` が引数か `JAVA_OPTS` で明示されていれば、運用者の指定を優先して pin しない |
| 244〜249 | **新規** | `re_quote()`／`repl_quote()`：sed 用のエスケープ |
| 251〜283 | **新規** | `pin_logging_properties()`：`logging.properties` の `handler.*.fileName=` が `standalone/log/…` か `mid/<何か>/…` を指していたら、今回の実体パスへ書き換える（配布物既定の `${org.jboss.boot.log.file:…}` 形式は触らない） |
| 286〜436 | 変更なし | 1. configuration の復元（PR #2 の `cp -Rf` 対策を含む） |
| 445〜492 | **変更** | 3. `LOG_ID` の決定を `LOG_ID_SOURCE` で分岐。taskid はタスク ID（同一タスク内の再起動は同じディレクトリを再利用）、取れなければ random にフォールバック。random の生成処理は従来のまま |
| 494〜502 | 変更 | `ln -sfn` の説明に「current は目印」を追記。起動ログに `(LOG_ID_SOURCE=…)` を表示 |
| **504〜547** | **新規（本対策）** | **3-B. pin**：`LOG_OWN=$(cd mid/<LOG_ID> && pwd -P)`、`export JBOSS_LOG_DIR=$LOG_OWN`、`pin_logging_properties`、CMD が `standalone.sh` ならコマンド直後に `-Djboss.server.log.dir=$LOG_OWN` を挿入 |
| 557〜572 | **変更** | 4. 事前検証：`standalone/log` が解決できること（dangling でないこと）は従来どおり確認。書き込み確認の対象を「リンクの先」から「自分の実体ディレクトリ `LOG_OWN`」に変更。リンクが別タスクを指していても異常扱いしない（並行起動では正常） |
| 574〜612 | 変更なし | tmp／data／deployments の検証、pdf、`exec "$@"` |

**3. LOG_ID の決定（変更前 → 変更後。抜粋・一部省略）**

```sh
# ---- 変更前 (dfe0282) : 起動時刻-ランダム8桁 だけ ----
LOG_ID=""
_i=0
while [ "${_i}" -lt 5 ]; do
    _cand="$(date +%Y%m%d%H%M%S)-$(gen_rand8)"
    if mkdir "${MID_DIR}/${_cand}" 2>/dev/null; then LOG_ID="${_cand}"; break; fi
    _i=$((_i + 1))
done
...
say "JBoss EAP log dir: ${MID_DIR}/${LOG_ID}"

# ---- 変更後 : LOG_ID_SOURCE で random / taskid を選ぶ ----
LOG_ID_SOURCE="${LOG_ID_SOURCE:-random}"
LOG_ID=""
case "${LOG_ID_SOURCE}" in
    random) ;;
    taskid)
        _tid="$(fetch_task_id || true)"
        if [ -n "${_tid}" ]; then
            mkdir -p "${MID_DIR}/${_tid}" || die "..."     # 同一タスク内の再起動は同じディレクトリを再利用
            LOG_ID="${_tid}"
        else
            echo "[efs-entrypoint] WARN: ECS タスク ID を取得できないため random 方式 ... で代替します" >&2
        fi ;;
    *)  die "LOG_ID_SOURCE の値が不正です: ..." ;;
esac
if [ -z "${LOG_ID}" ]; then
    # (従来の「起動時刻-ランダム8桁」の生成処理そのまま)
fi
ln -sfn "${LOG_ID}" "${MID_DIR}/current" || die "..."     # current は「最後に起動したタスク」の目印
say "JBoss EAP log dir: ${MID_DIR}/${LOG_ID} (LOG_ID_SOURCE=${LOG_ID_SOURCE})"
```

**3-B. JBoss のログ出力先を実体パスへ固定（新規・本対策の中心。抜粋・WARN 出力などは要約）**

```sh
LOG_OWN="$(cd "${MID_DIR}/${LOG_ID}" 2>/dev/null && pwd -P)" \
    || die "${MID_DIR}/${LOG_ID} を解決できません。"          # current を辿らずに自分の実体を得る

JBOSS_LOG_PIN="${JBOSS_LOG_PIN:-on}"
case "${JBOSS_LOG_PIN}" in
    on)
        if has_log_dir_opt "$@"; then
            # -Djboss.server.log.dir が明示されていれば、それを優先 (WARN を出す)
        else
            export JBOSS_LOG_DIR="${LOG_OWN}"                  # standalone.sh: boot.log.file と gc.log
            pin_logging_properties                             # 残っている current 経由のパスを揃える
            case "${1:-}" in
                */standalone.sh|standalone.sh)
                    _cmd="$1"; shift
                    set -- "${_cmd}" "-Djboss.server.log.dir=${LOG_OWN}" "$@"   # ★コマンド直後に挿入
                    say "log pin: JBoss は ${LOG_OWN} へ直接書き込みます (current は書き込み経路に使いません)" ;;
                *)  # CMD が standalone.sh 以外 → WARN (ラッパーから -Djboss.server.log.dir="$JBOSS_LOG_DIR" を渡す)
            esac
        fi ;;
    off) # 従来どおり current 経由 (切り分け・再現試験専用。WARN)
    *)   die "JBOSS_LOG_PIN の値が不正です: ..." ;;
esac
```

> **なぜ「コマンド直後」に挿入するのか:** `standalone.sh` は `--` より後ろの引数を解釈しないため、末尾に足すと効かない場合がある。コマンド直後なら必ず解釈される。`standalone.sh` はこの値を `readlink -m` した上で `-Dorg.jboss.boot.log.file` にも使い、JVM にも `-Djboss.server.log.dir` として渡す（WildFly Core の `standalone.sh` で確認）。

**4. 事前検証（変更前 → 変更後。抜粋）**

```sh
# ---- 変更前 : リンクの先 (= その瞬間の current の先) に書けるか ----
is_writable "${LOG_REAL}" || die "${LOG_LINK} -> ${LOG_REAL} に書き込めません。..."
say "log -> ${LOG_REAL} (書き込み可)"

# ---- 変更後 : 自分の実体ディレクトリに書けるか。リンクが別タスクを指すのは正常 ----
if [ "${LOG_REAL}" != "${LOG_OWN}" ]; then
    say "note: ${LOG_LINK} は別タスクのディレクトリ ${LOG_REAL} を指しています (並行起動で current が張り替えられたため)"
fi
is_writable "${LOG_OWN}" || die "${LOG_OWN} に書き込めません。..."
say "log -> ${LOG_OWN} (書き込み可)"
```

### 4-2. `docker/base/entrypoint.taskid.sh`（別実装 → 互換ラッパー）

> **やさしく言うと:** 昔のタスク ID 版は「説明書の大事なページ（設定の復元）」が抜けた別の本でした。1 冊にまとめて、表紙だけ残しました。

- **変更前（98 行の別実装）**: メタデータからタスク ID を取り `mid/<タスクID>` を作って `current` を張り替えるだけ。**configuration の復元・fail-fast 検証・pin が無く**、ECS（readonlyRootFilesystem=true）でそのまま使うと JBoss が無音で起動失敗し、pin も無いので本件のローテーション事故も起きる。
- **変更後（45 行）**: `LOG_ID_SOURCE=taskid` を既定にして本体を呼ぶだけ。

```sh
if [ -n "${EFS_ENTRYPOINT_TASKID_WRAPPED:-}" ]; then          # 自分自身を呼ぶ誤設定を検出
    echo "[efs-entrypoint-taskid] FATAL: ラッパーが自分自身を呼び出しました。" >&2
    echo "[efs-entrypoint-taskid] FATAL: base の Dockerfile で entrypoint.sh を /usr/local/bin/efs-entrypoint.sh として COPY してください。" >&2
    exit 1
fi
export EFS_ENTRYPOINT_TASKID_WRAPPED=1
export LOG_ID_SOURCE="${LOG_ID_SOURCE:-taskid}"
exec /usr/local/bin/efs-entrypoint.sh "$@"
```

### 4-3. `docker/base/Dockerfile`（43〜47 行）

```dockerfile
# ---- 変更前 ----
COPY entrypoint.sh /usr/local/bin/efs-entrypoint.sh
RUN chmod 0755 /usr/local/bin/efs-entrypoint.sh \
    && sed -i 's/\r$//' /usr/local/bin/efs-entrypoint.sh

# ---- 変更後 : 2 本とも入れる (どちらも同じ本体を使う) ----
COPY entrypoint.sh        /usr/local/bin/efs-entrypoint.sh
COPY entrypoint.taskid.sh /usr/local/bin/efs-entrypoint-taskid.sh
RUN chmod 0755 /usr/local/bin/efs-entrypoint.sh /usr/local/bin/efs-entrypoint-taskid.sh \
    && sed -i 's/\r$//' /usr/local/bin/efs-entrypoint.sh /usr/local/bin/efs-entrypoint-taskid.sh
```

### 4-4. `docker/front/Dockerfile`・`docker/back/Dockerfile`（コメントのみ）

- `/opt/jboss-eap/standalone/log -> …/mid/current` のリンクの作り方は**変更なし**（`readonlyRootFilesystem=true` のためビルド時にしか作れない）。
- コメントに「current は全タスク共有の『最後に起動したタスク』の目印で、JBoss 自身はエントリポイントが渡す `-Djboss.server.log.dir=mid/<LOG_ID>`（実体パス）へ直接書く」ことを追記（front 15〜19 行・75 行・77 行、back 14〜16 行・52〜53 行）。

### 4-5. `docs/`（文書）

| ファイル | 主な変更 |
|---|---|
| `DESIGN.md` | 冒頭に `LOG_ROTATION.md` への案内。1 章の図に「current は目印・JBoss は実体へ直接書く」。3 章に「書き込み経路は current を通さない (pin)」を新設。タスク ID 方式は `LOG_ID_SOURCE=taskid` に統合した旨。5 章のタスク定義例に `LOG_ID_SOURCE`・`JBOSS_LOG_PIN`・`TZ`。**6 章 1 の旧評価（「desiredCount=1 なら実害はほぼ無い」）を訂正** |
| `REJECTED_ALTERNATIVES.md` | 冒頭に 2026-09 改訂の注記。案 A／A' 単独の欠陥を明記。**案 C（`-Djboss.server.log.dir`）を A／A' と併用で採用**に変更。比較表に「並行タスク分離（0 時のローテーション）」の観点と「A' + C（既定）／A + C」の行を追加 |
| `TROUBLESHOOTING.md` | 5-4 を「`LOG_ID_SOURCE=taskid` を設定するだけ（移植不要）」に差し替え。**7 章「日付が変わっても前日付の server.log.<日付> に追記され続ける」**（原因・ECS Exec での確認コマンド・対処・壊れたファイルの洗い出し）を新設。チェックリストに「`log pin` 行が出ている」「JVM のタイムゾーン」を追加 |
| `LOG_ROTATION.md`（新規） | 調査報告書の Markdown 版（このフォルダの `JBossEAP_serverlog_rotation_current_link.md` と同一） |

### 4-6. `test/rotation/`（md/xlsx 記載の試験道具・新規）

Docker で ECS と同じ条件（`--read-only`、空の tmpfs、共有ボリューム＝EFS）を作り、本物の WildFly で 0 時をまたぐ試験を行う。`JBOSS_LOG_PIN=on／off` で修正後と修正前の挙動を比べられる。使い方は `test/rotation/README.md`。**本番イメージには含めない。**

### 4-7. 今回追加したもの（md/xlsx 記載外）

| ファイル | 何のため |
|---|---|
| `test/local/entrypoint_test.sh` | エントリポイントの分岐を、Docker も JBoss も使わずに 1〜2 分で確認する（135 項目。dash／bash --posix／busybox sh） |
| `test/local/rotation_local.sh` | 本物の WildFly（26.1.3／41.0.1）を Docker なしで「ECS タスク相当」の複数プロセスとして起動し、0 時をまたぐ試験を行う（`test/rotation/scenario.sh` と同じシナリオ・同じ記録形式）。Docker の仮想ディスクで C: が逼迫するこの PC 向け |
| `test/local/README.md` | 上 2 つの使い方と、2026-09-27 の結果 |
| `.gitattributes` | `*.sh text eol=lf`。Windows で `git clone` しても `.sh` が CRLF にならない（CRLF だと bash が `$'\r': command not found` で止まる。エントリポイントは Dockerfile でも CR を除去している） |

---

## 5. 環境変数（新設・変更）

> **やさしく言うと:** 何も設定しなければ「修正後の正しい動き（pin あり・起動時刻-乱数の名前）」になります。

| 変数 | 既定 | 意味 |
|---|---|---|
| `LOG_ID_SOURCE`（新設） | `random` | `random`: 起動時刻-ランダム8桁（ECS メタデータ不要）／`taskid`: ECS タスク ID（`describe-tasks`・CloudWatch と突き合わせやすい。取れなければ random）。不正値は FATAL（`current` を触る前） |
| `JBOSS_LOG_PIN`（新設） | `on` | `on`: JBoss の書き込み先を `mid/<LOG_ID>` の実体パスへ固定／`off`: 従来どおり `current` 経由（**切り分け・再現試験専用。本番では使わない**）。不正値は FATAL |
| `JBOSS_LOG_DIR`（エントリポイントが export） | ― | `standalone.sh` が `-Dorg.jboss.boot.log.file` と gc.log の出力先に使う。CMD が standalone.sh 以外のラッパーなら、ラッパーから `-Djboss.server.log.dir="$JBOSS_LOG_DIR"` を渡す |
| `ECS_CONTAINER_METADATA_URI_V4` | （ECS が設定） | `LOG_ID_SOURCE=taskid` のときだけ使う |
| `CONFIG_SEED_MODE`／`JBOSS_CONFIG_FILE` | `overwrite`／`standalone.xml` | 従来どおり |
| `TZ`（推奨・任意） | （未設定＝UTC） | 日次ローテーションの 0 時とファイル名の日付を決める。日本時間で区切るなら `Asia/Tokyo` |

タスク ID 方式（旧実装）へ切り替えるには、タスク定義の environment に `LOG_ID_SOURCE=taskid` を足す（推奨）か、entryPoint を `["/usr/local/bin/efs-entrypoint-taskid.sh"]` にする。**どちらも再ビルド不要**で、configuration の復元・fail-fast・pin が必ず効く。

---

## 6. 修正後の処理の流れと、書き込み経路の違い

```
0.   umask 002・診断ヘルパー
0-2. LOG_ID_SOURCE / JBOSS_LOG_PIN の検証            ← 新規 (不正なら current を触る前に停止)
1.   configuration の復元 (seed → configuration)       … 従来どおり
2.   アプリログ用ディレクトリ作成                      … 従来どおり
3.   LOG_ID の決定 (random / taskid)                   ← LOG_ID_SOURCE で分岐
     mkdir mid/<LOG_ID> → ln -sfn <LOG_ID> mid/current  … current は「最後に起動したタスク」の目印
3-B. pin: LOG_OWN=$(cd mid/<LOG_ID> && pwd -P)         ← 新規 (本対策)
     export JBOSS_LOG_DIR=$LOG_OWN
     logging.properties の fileName を $LOG_OWN に揃える
     standalone.sh の直後に -Djboss.server.log.dir=$LOG_OWN を挿入
4.   書き込み検証 ($LOG_OWN, tmp, data)                ← 対象を「自分の実体」に変更
5.   pdf → exec standalone.sh -Djboss.server.log.dir=$LOG_OWN ...
```

```
【修正前】 JBoss が知っているのは「道順」だけ。rename と再 open のたびに current を辿り直す
  /opt/jboss-eap/standalone/log/server.log
     → (log)     /mnt/logs/<C>/logs/<S>/mid/current      ← 全タスク共有。最後に起動したタスクが書き換える
     → (current) <その瞬間の最新タスク>/server.log        ← 0 時の rename がここ (= 他タスク) に当たる

【修正後】 JBoss は「自分の住所」を直接知っている。current はパスの途中に出てこない
  -Djboss.server.log.dir=/mnt/logs/<C>/logs/<S>/mid/<自分の LOG_ID>
     → <自分の LOG_ID>/server.log                          ← rename も再 open も常に自分のディレクトリ
  (standalone/log → mid/current のリンクは、人やログ収集ツールの入口として残る)
```

---

## 7. 動作確認の結果（2026-09-27 実施）

> **やさしく言うと:** 本物の JBoss の仲間（WildFly）を 2 人並べて、わざと夜中の 0 時をまたがせました。直した版では、みんな自分のノートだけを片付けました。直す前の動き（`JBOSS_LOG_PIN=off`）では、報告どおり、よその子のノートに昨日のシールを貼ってしまいました。

### 7-1. 実装を正確に復元できていることの確認

md/xlsx を作った前回の作業では、修正は `JBossEAP_SLink_Current_Problem` の中に入れ子で clone したリポジトリ上で行われたが、そのフォルダは削除されていた（このリポジトリには commit `dfe0282` を指す gitlink だけが残っていた）。そこで前回の作業記録から、ファイルへの編集 32 件（Write／Edit）と試験道具の作成・修正（コピーと sed）を**同じ基点 `dfe0282` に同じ順序で再適用**して復元し、前回の最終状態と突き合わせた。

| 突き合わせた項目 | 前回の最終状態 | 復元結果 |
|---|---|---|
| 既存 8 ファイルの変更量（ファイルごと） | back 8、base/Dockerfile 22、entrypoint.sh 282、entrypoint.taskid.sh 119、front 9、DESIGN 122、REJECTED 80、TROUBLESHOOTING 77（計 +515／−204） | すべて一致 |
| entrypoint.sh の主要行 | 0-2＝167 行、fetch_task_id＝213、pin_logging_properties＝261、LOG_ID_SOURCE＝450、3-B＝505、JBOSS_LOG_PIN＝513 | すべて一致 |
| entrypoint.taskid.sh の exec 行 | 45 行 | 一致 |
| test/rotation の scenario.sh／batch.sh | 8,286 バイト／982 バイト（shellcheck 対応の修正後） | 一致 |
| docs/LOG_ROTATION.md | 調査報告書の md のコピー | 報告書 md とバイト単位で一致 |

### 7-2. 静的検査

| 検査 | 結果 |
|---|---|
| `shellcheck -s sh`（entrypoint.sh・entrypoint.taskid.sh） | 警告なし（info レベルの SC2012 が 1 件。修正前からある `ls \| wc -l` の行で、今回の変更箇所ではない） |
| `dash -n`／`bash --posix -n`／`busybox sh -n` | 両スクリプトとも OK |
| `shellcheck -s bash`（test/rotation・test/local） | 警告なし |
| 改行コード | 全ファイル LF（CRLF なし） |

### 7-3. エントリポイント単体試験（`test/local/entrypoint_test.sh`）

WSL（Ubuntu 22.04）で `dash`・`bash --posix`・`busybox sh` の 3 種類のシェルで実行し、**PASS=135 FAIL=0 SKIP=0**。md 7-10 の 9 ケースに加え、taskid の新形式・旧形式・整形 JSON・不正な ARN、ラッパー経由の実行（user+mount 名前空間で `/usr/local/bin` を差し替え）、8 本同時起動（全員が別ディレクトリ・自分の実体パスを受け取る）、EFS 側がシンボリックリンク経由のとき物理パスを渡すこと、などを確認（一覧は `test/local/README.md`）。

### 7-4. 実機試験（`test/local/rotation_local.sh`、WSL 上で Docker を使わずに実施）

WildFly 26.1.3.Final（≒ JBoss EAP 7.4、Temurin JRE 11.0.32.1）と WildFly 41.0.1.Final（≒ EAP 8.x、Temurin JRE 21.0.12.1）を、今回の `entrypoint.sh` 経由で「ECS タスク相当」の別プロセスとして起動した（共有ディレクトリ＝EFS、タスクごとに空の configuration／tmp／data、`standalone/log → …/mid/current` のリンク、SIGTERM での停止）。0 時は JVM のタイムゾーンだけをずらして作った（時計は実時刻）。

| シナリオ | 実装 | サーバ | 結果 | 確認できたこと |
|---|---|---|---|---|
| **S1**（ご報告のケース：A が 0 時をまたいで稼働 → 0 時後に B 起動 → A 停止） | 修正後 | WildFly 26.1.3 | **解消** | A は自分のディレクトリで `server.log.2026-09-26`（前日分）と `server.log`（停止ログ）を作成。B の fd は最後まで `server.log`、B の当日分はすべて B の `server.log` |
| S1 | 修正後 | WildFly 41.0.1 | **解消** | 26.1.3 と同じ（EAP 8.x 相当でも同じ） |
| S1 | `JBOSS_LOG_PIN=off`（修正前の挙動） | WildFly 26.1.3 | 再現 | B の fd が `server.log` → `server.log.2026-09-26` に変わり、B の当日分が前日付ファイルへ。B の `server.log` には A の停止ログ。A の `server.log` は改名されないまま（md 7-3 と同じ） |
| **S2**（A・B が 0 時をまたぐ、A が先にログ） | 修正後 | WildFly 26.1.3 | **解消** | A・B とも自分のディレクトリに前日分と当日分。消失なし |
| S2 | `JBOSS_LOG_PIN=off` | WildFly 26.1.3 | 再現＋消失 | **B の前日分（起動ログ・0 時前のログ）がどのファイルにも残らない**。B の `server.log.2026-09-26` の中身は A の当日分（md 7-5 と同じ） |
| **S2r**（同、B が先にログ） | 修正後 | WildFly 26.1.3 | **解消** | 消失なし。各自のディレクトリで完結 |
| **R1**（B 起動後に A を `:reload`、続いて `:shutdown(restart=true)`＝JVM だけの再起動） | 修正後 | WildFly 26.1.3 | **問題なし** | `:reload` 後も JVM 再起動後も A の fd は自分の `server.log`。JVM 引数も実体パス（再起動ループでも引き継がれる） |
| R1 | `JBOSS_LOG_PIN=off` | WildFly 26.1.3 | 再現 | `:reload` ではファイルを開き直さない（自分のファイルのまま）。**JVM 再起動後は current 経由で B の `server.log` を開き、A と B の 2 つの JVM が同じファイルに書いた** |
| **R2**（0 時前に A がクラッシュ → 0 時後に同じタスクで再起動＝ECS restartPolicy 相当） | 修正後・`LOG_ID_SOURCE=taskid` | WildFly 26.1.3 | 期待どおり | 同じ `mid/<タスクID>` を再利用。起動直後の最初のログで前回分が `server.log.2026-09-26` に改名され、今回分は新しい `server.log` |
| R2 | 修正後・random | WildFly 26.1.3 | 期待どおり | 新しい `mid/<起動時刻-乱数>` を作成。前回のディレクトリの `server.log` は改名されずに残る |

**md/xlsx で「未実施」だった項目 → 今回すべて確認済み**

| md/xlsx の記載（7-2 の最終行・7-10 の注記・5 章 Q3） | 今回の結果 |
|---|---|
| S2r の修正後 | 解消を確認 |
| `:reload`／JVM 再起動（Q3 の表 3〜4 行目） | 修正後は自分のディレクトリに戻る。修正前は JVM 再起動で他タスクのファイルに追記（md の記述どおり）。`:reload` は FILE ハンドラを開き直さなかった |
| コンテナ再起動（Q3 の表 2 行目） | taskid は同じディレクトリで「最終更新日」の名前に改名してから新しい `server.log`、random は新ディレクトリ（md の記述どおり） |
| WildFly 41 での修正後 S1 | 解消を確認 |
| `JBOSS_LOG_PIN=off` での再現 | S1・S2・R1 で再現を確認 |

### 7-5. 代表的な記録（S1、WildFly 26.1.3。`mid/` 以下の最終状態）

```
【修正後 (JBOSS_LOG_PIN=on)】                                  【修正前の挙動 (JBOSS_LOG_PIN=off)】
current -> 20260927122605-w1g69xi3 (B)                          current -> 20260927122605-yhqwy4rf (B)
[20260927122310-8kebi2cw] (A)                                   [20260927122310-0h3ol312] (A)
  server.log            A の停止ログ (00:00:14)                    server.log            A の 9/26 分 (改名されないまま)
  server.log.2026-09-26 A の 9/26 分 (起動・0 時前のログ)        [20260927122605-yhqwy4rf] (B)
[20260927122605-w1g69xi3] (B)                                     server.log            A の停止ログ (他タスクのログが混入)
  server.log            B の 9/27 分すべて                        server.log.2026-09-26 B の 9/27 分 (前日付の名前に追記) ← 症状
B の fd: server.log → server.log (変わらない)                   B の fd: server.log → server.log.2026-09-26
JVM 引数: -Djboss.server.log.dir=mid/<B の LOG_ID>               JVM 引数: -Dorg.jboss.boot.log.file=…/standalone/log/server.log
          -Dorg.jboss.boot.log.file=mid/<B の LOG_ID>/server.log
```

**R1（修正前の挙動）: JVM だけの再起動で、A が B のファイルに書き始めた**

```
[…-g35u9y1k] (A)  server.log : A の起動 … :reload の停止・起動 … A:after-reload … WFLYSRV0050 (停止) まで
[…-7vkgjlf7] (B)  server.log : B の起動 / B:running / A の起動 (WFLYSRV0049・0025) / A:after-jvm-restart / B:still-running
FD A -> mid/…-7vkgjlf7/server.log   FD B -> mid/…-7vkgjlf7/server.log   ← 2 つの JVM が同じファイルへ
```

### 7-6. 検証の限界

- 実機試験は WSL の ext4 上の共有ディレクトリで EFS を代用した（rename と fd の関係は NFS でも同じ。NFS 固有の属性キャッシュや ESTALE は再現しない）。readonlyRootFilesystem（`--read-only`）は `rotation_local.sh` では再現しない（前回の Docker 版の試験で確認済み。`test/rotation/scenario.sh`）。
- サーバは JBoss EAP 本体ではなくアップストリームの WildFly（ログ部分の jboss-logmanager・logging サブシステム・standalone.sh は同系統で、既定の FILE ハンドラ設定も同一）。
- Docker 版の試験道具（`test/rotation/`）は、今回は shellcheck と構文確認のみ（中身は前回実際に実行したものと同じで、差分は使い方コメント 1 行と shellcheck 対応の 4 箇所だけ）。

---

## 8. 使い方（ビルド・デプロイ・確認・移行）

> **やさしく言うと:** いつもどおりイメージを作り直してデプロイするだけです。タスク定義は変えなくても効きます。

**ビルド**（base → front／back の順。CI では `STRICT_SEED=1`）

```bash
docker build -t myapp-base:latest --build-arg STRICT_SEED=1 docker/base
docker build -t intra-web-front:latest --build-arg BASE_IMAGE=myapp-base:latest \
  --build-arg Service_Name=intra-web --build-arg Component_name=intra-web-front docker/front
```

**タスク定義**（変更不要。明示するなら以下。`TZ` は日本時間の 0 時で区切りたい場合）

```json
"environment": [
  { "name": "LOG_ID_SOURCE", "value": "random" },
  { "name": "JBOSS_LOG_PIN", "value": "on" },
  { "name": "TZ",            "value": "Asia/Tokyo" }
]
```

**効いているかの確認**

```bash
# 1) CloudWatch (awslogs) に次の 2 行が出ていること
[efs-entrypoint] log pin: JBoss は /mnt/logs/.../mid/<LOG_ID> へ直接書き込みます (current は書き込み経路に使いません)
[efs-entrypoint] preflight OK. starting: /opt/jboss-eap/bin/standalone.sh -Djboss.server.log.dir=/mnt/logs/.../mid/<LOG_ID> ...

# 2) ECS Exec で、JVM が握っているファイルと起動引数が「自分の LOG_ID の実体パス」であること
for p in /proc/[0-9]*; do
  case "$(readlink $p/exe 2>/dev/null)" in
    */java) ls -l $p/fd | grep -E '\.log'
            tr '\0' '\n' < $p/cmdline | grep -E 'jboss.server.log.dir|org.jboss.boot.log.file' ;;
  esac
done
```

**移行時の注意**

1. 修正前のイメージのタスクは、修正後のタスクと並んでいる間も `current` 経由で rename する。**切り替えのデプロイは日中に行い、0 時（JVM のタイムゾーン）までに修正前のリビジョンのタスクがすべて停止したこと**を確認する（`aws ecs describe-services` の deployments で旧リビジョンの runningCount=0）。
2. 翌朝、各 `mid/<LOG_ID>/` に `server.log.<前日>` と `server.log` が揃い、名前の日付と中身の日付が一致していることを確認する（ずれたファイルの洗い出しは `docs/TROUBLESHOOTING.md` 7 章）。
3. ログ収集ツールが `mid/current/server.log` を読んでいる場合は `mid/*/server.log*` に変える（`current` は他タスクの起動で切り替わるため）。
4. 補助策（0 時帯のデプロイ回避、登録解除の遅延の短縮、サーキットブレーカー、Early Success Criteria で `DEFERRED` を使わない等）は調査報告書 9 章を参照。

**試験のやり直し（Docker なし、WSL／Linux）**

```bash
test/local/entrypoint_test.sh                            # 1〜2 分。JBoss 不要
test/local/rotation_local.sh setup wf26                  # JRE 11 + WildFly 26.1.3 (約 400MB)
test/local/rotation_local.sh batch 240 "S1 wf26 fixed-S1 100" "S1 wf26 legacy-S1 200 JBOSS_LOG_PIN=off"
test/local/rotation_local.sh clean                       # 後片付け
```

---

## 9. 元フォルダで行ったことと、GitHub の main との関係（要判断）

> **やさしく言うと:** 元のフォルダにも同じ修正を入れました。ただし GitHub の側には、別の作業で違うやり方で直した版（今日 10:37 のコミット）がすでに入っています。どちらを正式にするか、決めてから push してください。

**元フォルダ `C:\Users\taka_\Claude\ECS_EFS_Dockerfile_Symboliclink_lite` で行った操作**

| 順 | 操作 | 結果 |
|---|---|---|
| 1 | `git fetch origin` | GitHub の最新を取得（`origin/main` = `5f13387`） |
| 2 | `git merge --ff-only dfe0282` | ローカル `main` を `c044948` → `dfe0282`（PR #2「起動時 cp の Permission denied を解消」のマージ）へ早送り。md/xlsx の実装が載っている版にそろえるため。作業ツリーはクリーンだった |
| 3 | 修正後のファイル一式を上書き・追加 | このフォルダの `ECS_EFS_Dockerfile_Symboliclink_lite/` と**同一内容**（git に登録される内容＝全 20 ファイルのモードとハッシュが一致。変更なしの `docs/CP_PRESERVE_OWNERSHIP.md` だけは git から取り出し直したため、作業ツリー上の改行が CRLF） |
| 4 | `git add`（ステージ） | 新規のテスト用スクリプト（`test/rotation/*.sh`・`test/local/*.sh`）は実行権限（100755）付きで登録。**コミット・push はしていない** |

`git diff --cached --stat`（元フォルダ）は、既存 8 ファイル +515／−204 と新規 11 ファイル。元に戻すときは `git reset --hard dfe0282`（修正を捨てる）や `git reset --hard c044948`（早送り前に戻す）。

**⚠ GitHub の `main` には別方式の実装が入っている**

- `5f13387`（2026-09-27 10:37、作成者 Takahiko Yoshizawa、コミットメッセージ "first commit"）は `dfe0282` の子で、同じ問題を**別の方式**で直している: `standalone/log → tmp/jboss-log-target`（タスクローカルのボリューム上のリンク）→ `mid/<LOG_ID>` の 3 段リンク、`LOG_ID_MODE=timestamp|taskid`、`LOG_LINK_STRICT`、`docs/SERVER_LOG_DATE_ROLLOVER.md`、`docker/base/tests/rotation_isolation_test.sh` など。調査報告書でいう**「案 B（コンテナ専用リンク）」**にあたる。
- 今回の修正（**案 A**）と同じファイル（entrypoint.sh・entrypoint.taskid.sh・各 Dockerfile・docs）を変えているため、元フォルダで `git pull` すると**競合する**。どちらを正とするか決めてから、コミット・push すること。
  - 案 A（今回）: タスク定義の変更不要、front／back のリンクは従来のまま、`-Djboss.server.log.dir` で JBoss 本体・ブートログ・監査ログすべてを実体パスへ。
  - 案 B（`5f13387`）: `/opt/jboss-eap/standalone/log` を ECS Exec で覗くと「自分の」ログが見える。front／back の再ビルドと tmp のボリュームが前提。
- 参考（コードを読んで気付いた点）: `5f13387` の entrypoint.sh には「`JBOSS_LOG_DIR` だけで standalone.sh が `-Djboss.server.log.dir` と `-Dorg.jboss.boot.log.file` の両方に展開する」とあるが、WildFly Core の `standalone.sh` は `JBOSS_LOG_DIR` を `-Dorg.jboss.boot.log.file`（と gc.log）にしか使わない（`-Djboss.server.log.dir` は引数か `JAVA_OPTS` で渡したときだけ JVM に届く）。3 段リンクに作り直したイメージでは問題にならないが、同コミットの「再ビルド前の旧イメージでも `JBOSS_LOG_DIR` で同じ事故を避けられる」という暫定動作は、logging サブシステム起動後の FILE ハンドラ（`relative-to=jboss.server.log.dir`）には効かない。

---

## 10. このフォルダ（JBossEAP_SLink_Current_Problem）の git 上の扱い

> **やさしく言うと:** 前は「別の箱の場所を書いたメモ」しか入っていなかったので、箱の中身そのものを入れました。

- **これまで**: `ECS_EFS_Dockerfile_Symboliclink_lite` は入れ子の git リポジトリで、このリポジトリには「`dfe0282` を指す gitlink（mode 160000）」しか記録されていなかった（GitHub 上でも中身は見えない）。しかも作業ツリーからは削除されていた。
- **今回**: 入れ子の `.git` を持たない**普通のフォルダ**として実装一式を置き、このリポジトリで直接管理する形にした。gitlink の削除（`git rm --cached`。ファイルは消していない）とファイル 20 個の追加、本書の追加を**ステージ済み（未コミット）**。テスト用スクリプト 4 本は実行権限（100755）付きで登録した。
  - 注意: ステージを取り消して（`git reset` など）から `git add` し直すと、Windows（`core.filemode=false`）では新規ファイルが 100644 で登録される。その場合は `git add --chmod=+x ECS_EFS_Dockerfile_Symboliclink_lite/test/rotation/*.sh ECS_EFS_Dockerfile_Symboliclink_lite/test/local/*.sh` を付け直す（元フォルダでも同様）。
- 内容を確認して問題なければ、次でコミット・push できる。

```bash
cd C:/Users/taka_/Claude/JBossEAP_SLink_Current_Problem
git status                       # deleted: …(gitlink) / new file: ECS_EFS_Dockerfile_Symboliclink_lite/… / new file: 本書
git diff --cached --stat
git commit -m "ECS_EFS_Dockerfile_Symboliclink_lite: server.log の日次ローテーション対策 (実体パスへの固定) を実装"
git push
```

---

## 11. 作業中に気付いた PC 側の注意

- **C: の空き**: 作業開始時 12.9GB → 終了時 8.6GB。大半は Windows の `pagefile.sys`（7.7GB に拡張）で、WSL で JVM を複数動かしたときのメモリ使用によるもの。システム管理のページファイルは通常、再起動で元の大きさに戻る。WSL の Ubuntu 仮想ディスク（`ext4.vhdx`）は 4.86GB → 5.52GB と約 0.7GB 増えた（試験用の JRE・WildFly は削除済みだが、仮想ディスクは自動では縮まない）。WSL（Ubuntu）は試験後に停止し、作業前と同じ「Stopped」に戻した。
- **一時フォルダの自動削除**: 作業中、`%TEMP%` 配下に置いた作業用ファイルのうち「更新日時が古いもの」（git から取り出して 2026-08-27 の日時が付いていたもの）だけが消えた。空き容量が減ったときに Windows の「ストレージ センサー」などが一時ファイルを掃除したとみられる。成果物はすべて `C:\Users\taka_\Claude\…` 側に置き、消えた 1 ファイル（`docs/CP_PRESERVE_OWNERSHIP.md`、変更なしのファイル）は git から取り出し直して、内容が git の記録と一致することを確認済み。**`%TEMP%` に大事なファイルを置かない**ほうが安全。
