#!/bin/bash
# MariaDB -> PostgreSQL へ occ db:convert-type で移行するスクリプト (Linux ホストで sudo bash 実行を想定)
# 前提: MariaDB のまま最新バージョンまでアップグレード済みで安定していること
# 移行中は nextcloud の DB 接続が MariaDB のまま (config.php 依存) のため、postgres と移行用 mariadb の両方が起動している必要がある
# 外部アクセスと定期処理を止めるため cron / cloudflared コンテナを停止する

set -e
# パイプ途中の失敗 (ダンプ失敗など) を gzip 等の成功で隠さないため
set -o pipefail

CONTAINER=nextcloud_app
BACKUP_DIR=./backup
TS=$(date +%Y%m%d%H%M%S)
# NC 35.0.2 の db:convert-type は全データコピー後の sequence 再同期で "SELECT MAX() FROM" の構文エラーで失敗する
# この出力が見えたときはデータはコピー済みなので、補完処理に分岐する
SEQ_ERROR_MARK='SELECT MAX() FROM'
# convert-type は OFFSET でページングするため、既定の 1000 行だと数百万行のテーブルで読み飛ばしが膨らみ数日かかる
# 環境変数 CONVERT_CHUNK_SIZE で変更できる (メモリ不足になる場合は下げる)
CONVERT_CHUNK_SIZE=${CONVERT_CHUNK_SIZE:-50000}

# 設定読み込み
if [ ! -f .env ]; then
    echo ".env が見つかりません (.env.example をコピーして作成してください)" >&2
    exit 1
fi

# 秘密値はスクリプトに書かず .env から読む
# .env は compose 形式 (値に空白や行末コメントを含む) で bash では source できないため、必要なキーだけ取り出す
env_value() {
    sed -n "s/^$1=//p" .env | tail -n 1 \
        | sed -e 's/\r$//' -e 's/[[:space:]]\{1,\}#.*$//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}
DB_NAME=$(env_value DB_NAME)
DB_USER=$(env_value DB_USER)
DB_PASSWORD=$(env_value DB_PASSWORD)
MARIADB_ROOT_PASSWORD=$(env_value MARIADB_ROOT_PASSWORD)

: "${DB_NAME:?DB_NAME が .env にありません}"
: "${DB_USER:?DB_USER が .env にありません}"
: "${DB_PASSWORD:?DB_PASSWORD が .env にありません}"
: "${MARIADB_ROOT_PASSWORD:?MARIADB_ROOT_PASSWORD が .env にありません}"

# 引数がなければ user_ldap を一時有効化する (--all-apps が無効アプリのスキーマ作成で失敗するため)
# 他の無効アプリでも失敗する場合は引数で追加する (例: sudo bash migrate-to-postgres.sh user_ldap audioplayer)
if [ $# -gt 0 ]; then
    TEMP_ENABLE_APPS=("$@")
else
    TEMP_ENABLE_APPS=(user_ldap)
fi

CONFIG_BACKUP="$BACKUP_DIR/config.php.$TS"

occ() {
    docker exec -u www-data "$CONTAINER" php /var/www/html/occ "$@"
}

die() {
    echo "エラー: $1" >&2
    if [ -f "$CONFIG_BACKUP" ]; then
        echo "切り戻し方法: config.php をバックアップに戻して MariaDB で再開できます" >&2
        echo "  docker cp \"$CONFIG_BACKUP\" $CONTAINER:/var/www/html/config/config.php" >&2
        # docker cp はホスト側の所有者のまま配置するため、www-data に戻さないと Nextcloud が config を書けず停止する
        echo "  docker exec $CONTAINER chown www-data:www-data /var/www/html/config/config.php" >&2
        echo "  docker compose restart nextcloud" >&2
        echo "maintenance mode が on の場合は occ maintenance:mode --off で解除し、一時有効化したアプリは occ app:disable <app> で戻してください" >&2
    else
        echo "(config.php はまだ変更されていません。バックアップは未取得です)" >&2
    fi
    exit 1
}

mkdir -p "$BACKUP_DIR"

# 準備
echo "cron / cloudflared を停止します (移行中は外部アクセスと定期処理を止める)"
docker compose stop nextcloud-cron cloudflared >/dev/null 2>&1 || true

echo "必要なコンテナを起動します (postgres + 移行用 mariadb + nextcloud)"
docker compose --profile mariadb up -d mariadb db redis nextcloud

echo "DB の起動を待ちます"
for _ in $(seq 60); do
    if docker compose --profile mariadb exec -T mariadb mariadb-admin ping --silent >/dev/null 2>&1 \
        && docker compose exec -T db pg_isready -q -U "$DB_USER" >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

# 既存データの MariaDB では MYSQL_USER / MYSQL_PASSWORD の環境変数は反映されないため、root (.env の MARIADB_ROOT_PASSWORD) で接続する
mariadb_root() {
    docker compose --profile mariadb exec -T mariadb sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec "$0" -uroot "$@"' "$@"
}
mariadb_root mariadb -e "SELECT 1" >/dev/null \
    || die "MariaDB に root で接続できません (.env の MARIADB_ROOT_PASSWORD を既存 MariaDB の root パスワードにしてください)"

# 旧 compose では MariaDB のサービス名が db だったが、db は PostgreSQL に置き換わったため移行用の mariadb に向け直す
if docker exec "$CONTAINER" grep -q "'dbtype' => 'mysql'" /var/www/html/config/config.php; then
    docker exec -u www-data "$CONTAINER" sed -i "s/'dbhost' => 'db\(:3306\)\{0,1\}'/'dbhost' => 'mariadb'/" /var/www/html/config/config.php
fi

echo "現在の状態を確認します"
occ status || die "occ を実行できません"
# 変換元の DB 名は .env ではなく稼働中の config.php に従う
MD_DB_NAME=$(occ config:system:get dbname)

# バックアップ
echo "config.php をバックアップします -> $CONFIG_BACKUP"
docker cp "$CONTAINER":/var/www/html/config/config.php "$CONFIG_BACKUP"

echo "MariaDB のダンプを取得します -> $BACKUP_DIR/mariadb-dump-$TS.sql.gz"
mariadb_root mariadb-dump --single-transaction "$MD_DB_NAME" \
    | gzip > "$BACKUP_DIR/mariadb-dump-$TS.sql.gz" \
    || die "MariaDB のダンプに失敗しました"

echo "補助スクリプトをコンテナに配置します"
docker cp scripts/pg_seq_fix.sql "$CONTAINER":/tmp/pg_seq_fix.sql
docker cp scripts/set_db_config.php "$CONTAINER":/tmp/set_db_config.php
# Windows 側で作成したファイルの CRLF を除去する
docker exec "$CONTAINER" bash -c "sed -i 's/\r\$//' /tmp/pg_seq_fix.sql /tmp/set_db_config.php && chown www-data:www-data /tmp/pg_seq_fix.sql /tmp/set_db_config.php"

# 変換準備
for app in "${TEMP_ENABLE_APPS[@]}"; do
    echo "アプリを一時有効化します: $app (メンテナンスモード中は有効化できないため事前に実行)"
    occ app:enable "$app" || die "app:enable $app に失敗しました"
done

occ maintenance:mode --on

echo "変換先データベースを作り直します (既存の PostgreSQL データは削除されます)"
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d postgres -c "DROP DATABASE IF EXISTS \"$DB_NAME\";" \
    || die "変換先 DB の削除に失敗しました"
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d postgres -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\" TEMPLATE template0 ENCODING 'UTF8';" \
    || die "変換先 DB の作成に失敗しました"

# 変換
echo "occ db:convert-type を実行します (データ量によっては 1 時間以上かかります)"
# パスワードはプロセス一覧や履歴に残らないよう標準入力で渡す
set +e
CONV_OUT=$(printf '%s' "$DB_PASSWORD" | docker exec -i -u www-data "$CONTAINER" php occ db:convert-type -n --all-apps --clear-schema --chunk-size="$CONVERT_CHUNK_SIZE" --port=5432 pgsql "$DB_USER" db "$DB_NAME" 2>&1)
CONV_EXIT=$?
set -e
# 進行状況のバーを除いて出力する
printf '%s\n' "$CONV_OUT" | grep -vE '^\[[=>-]+\]' || true

if [ "$CONV_EXIT" -ne 0 ]; then
    case "$CONV_OUT" in
        *"$SEQ_ERROR_MARK"*)
            echo "既知の不具合 (sequence 再同期) を検出しました。データはコピー済みなので補完処理に進みます"
            # convert-type は失敗時に maintenance を自動で off にするため戻す
            occ maintenance:mode --on
            echo "孤立 sequence の削除と再同期を実行します (pg_seq_fix.sql)"
            tr -d '\r' < scripts/pg_seq_fix.sql | docker compose exec -T db psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" \
                || die "sequence の補完に失敗しました (config.php は MariaDB のままです)"
            echo "config.php の DB 設定を一括で書き換えます (set_db_config.php)"
            # occ config:system:set を 1 キーずつ使うと dbtype を変えた直後から occ が DB に接続できなくなるため一括で書く
            printf '%s' "$DB_PASSWORD" | docker exec -i -u www-data "$CONTAINER" php /tmp/set_db_config.php pgsql "$DB_NAME" "db:5432" "$DB_USER" \
                || die "config.php の書き換えに失敗しました"
            ;;
        *)
            die "db:convert-type が予期しない失敗をしました (exit=$CONV_EXIT)。上記の出力を確認してください"
            ;;
    esac
else
    echo "db:convert-type が最後まで成功しました (config.php は自動で切り替わっています)"
fi

# 整合性確認
echo "全テーブルの行数を比較します (MariaDB vs PostgreSQL)"

md_tables=$(mariadb_root mariadb -N "$MD_DB_NAME" -e "SELECT table_name FROM information_schema.tables WHERE table_schema=DATABASE() ORDER BY 1")
pg_tables=$(docker compose exec -T db psql -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY 1")

# 共通テーブルのみ比較 (oc_migrations は convert-type がコピーせずマイグレーション実行で埋めるため除外)
# 両 DB で同じテーブル一覧を使い、出力も並べ替えてから比べる (照合順序の違いで順番がずれるため)
md_sql=""
pg_sql=""
for t in $(comm -12 <(sort <<<"$md_tables") <(sort <<<"$pg_tables")); do
    [ "$t" = "oc_migrations" ] && continue
    md_sql+="SELECT '$t', COUNT(*) FROM \`$t\` UNION ALL "
    pg_sql+="SELECT '$t', COUNT(*) FROM \"$t\" UNION ALL "
done
md_sql=${md_sql% UNION ALL }
pg_sql=${pg_sql% UNION ALL }

mariadb_root mariadb -N "$MD_DB_NAME" -e "$md_sql" | tr '\t' ' ' | sort > "$BACKUP_DIR/rowcount-mariadb-$TS.txt"
docker compose exec -T db psql -U "$DB_USER" -d "$DB_NAME" -tA -F ' ' -c "$pg_sql" | sed '/^$/d' | sort > "$BACKUP_DIR/rowcount-postgres-$TS.txt"

echo "  MariaDB   : $(awk '{s+=$2} END {print NR" tables, "s" rows"}' "$BACKUP_DIR/rowcount-mariadb-$TS.txt")"
echo "  PostgreSQL: $(awk '{s+=$2} END {print NR" tables, "s" rows"}' "$BACKUP_DIR/rowcount-postgres-$TS.txt")"

md_only=$(comm -23 <(sort <<<"$md_tables") <(sort <<<"$pg_tables") | tr '\n' ' ' | sed 's/ $//')
pg_only=$(comm -13 <(sort <<<"$md_tables") <(sort <<<"$pg_tables") | tr '\n' ' ' | sed 's/ $//')
if [ -n "$md_only" ]; then
    echo "  未変換テーブル (MariaDBのみ): $md_only"
fi
if [ -n "$pg_only" ]; then
    echo "  PostgreSQLのみ (変換元にないテーブル): $pg_only"
fi
if diff -q "$BACKUP_DIR/rowcount-mariadb-$TS.txt" "$BACKUP_DIR/rowcount-postgres-$TS.txt" >/dev/null; then
    echo "行数の不一致: なし"
else
    echo "行数の不一致:"
    diff "$BACKUP_DIR/rowcount-mariadb-$TS.txt" "$BACKUP_DIR/rowcount-postgres-$TS.txt" || true
fi

# 事後処理
echo "メンテナンスモードを解除します"
occ maintenance:mode --off

for app in "${TEMP_ENABLE_APPS[@]}"; do
    echo "一時有効化したアプリを元に戻します: $app"
    occ app:disable "$app"
done

# user_ldap の有効化で config.php に追加されるキーを戻す
if printf '%s\n' "${TEMP_ENABLE_APPS[@]}" | grep -qx 'user_ldap'; then
    occ config:system:delete ldapProviderFactory || true
fi

echo "DB の不足インデックス・カラム・主キーを追加します"
occ db:add-missing-indices
occ db:add-missing-columns
occ db:add-missing-primary-keys

echo "maintenance:repair を実行します"
occ maintenance:repair

echo "MariaDB 時点の DB チェック結果のキャッシュを削除します"
occ config:app:delete serverinfo cached_db_check || true

echo "最終確認 (occ status / setupchecks)"
occ status
# setupchecks は warning が 1 件でもあると exit 1 になるため、移行の成否とは切り離す
occ setupchecks || true

echo "cron / cloudflared を再起動します"
docker compose up -d nextcloud-cron cloudflared

echo ""
echo "PostgreSQL への移行が完了しました"
echo " - mariadb コンテナ (profile) は通常起動しません。安定稼働を確認できたら削除して問題ありません"
echo " - 共有 / 検索 / WebDAV / SMB 外部ストレージの動作確認を行ってください"
echo " - バックアップ: $BACKUP_DIR (mariadb-dump-$TS.sql.gz / config.php.$TS / rowcount-*.txt)"
