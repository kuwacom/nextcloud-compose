#!/bin/bash
# 公式 entrypoint の自動 upgrade が止まったときの復旧と事後処理を行うスクリプト
# entrypoint は /var/www/html の version.php とイメージのバージョンを比べて自動で occ upgrade するが、
# 非互換アプリがあると途中で異常終了し maintenance mode が残る
# (config 内のバージョンは書き換わるため、再起動しても自動 upgrade は再実行されない)

set -e # 失敗したら止める (maintenance mode のまま残るので、ログを確認してから再実行する)

CONTAINER=nextcloud_app

occ() {
    docker exec -u www-data "$CONTAINER" php /var/www/html/occ "$@"
}

echo "現在の状態を確認します"
occ status

# needsDbUpgrade が true のときは自動 upgrade が止まっているので手動で続行する
if occ status | grep -q "needsDbUpgrade.*true"; then
    echo "自動 upgrade が未完了のため occ upgrade を実行します"
    occ maintenance:mode --on
    occ upgrade
    occ maintenance:mode --off
fi

# upgrade 自体は完了済みでも、異常終了の名残で maintenance mode だけ残ることがある
if occ status | grep -q "maintenance: true"; then
    echo "maintenance mode が残っているため解除します"
    occ maintenance:mode --off
fi

# メジャー upgrade 後に毎回警告が出る DB 構造の補完
echo "DB の不足インデックス・カラム・主キーを追加します"
occ db:add-missing-indices
occ db:add-missing-columns
occ db:add-missing-primary-keys

echo ".htaccess を更新します"
occ maintenance:update:htaccess

# upgrade で自動無効化・消失したアプリがないか確認する
echo "無効アプリの一覧 (消えたアプリがないか確認してください)"
occ app:list | sed -n '/^Disabled:/,$p'

echo "完了しました"
