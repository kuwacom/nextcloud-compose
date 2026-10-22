#!/bin/bash
# メジャーアップグレードの前に App Store のアプリ更新を当てるスクリプト
# 旧バージョンのアプリのまま上げると非互換で occ upgrade が中断することがある (recognize 8.2.2 が NC31 で Fatal になった実績あり)

set -e

CONTAINER=nextcloud_app

echo "アプリを App Store の最新版に更新します"
docker exec -u www-data "$CONTAINER" php /var/www/html/occ app:update --all

echo "現在の状態を確認します"
docker exec -u www-data "$CONTAINER" php /var/www/html/occ status

echo "完了しました"
