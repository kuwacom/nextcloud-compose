#!/bin/bash

# Nextcloud ホスト側マウントディレクトリのパス
NEXTCLOUD_BASE="./nextcloud"

# 対象ディレクトリ
DIRS=("data" "config" "themes" "custom_apps")

# 所有者とグループの UID/GID（www-data の UID/GID は通常 33）
OWNER_UID=33
OWNER_GID=33

echo "Nextcloud のパーミッションを修正します"

for dir in "${DIRS[@]}"; do
    TARGET="${NEXTCLOUD_BASE}/${dir}"
    if [ -d "$TARGET" ]; then
        echo "処理中: $TARGET"

        # 所有者とグループを設定（変更が必要なファイルのみ）
        find "$TARGET" ! -user "$OWNER_UID" -o ! -group "$OWNER_GID" -exec sudo chown "$OWNER_UID:$OWNER_GID" {} +

        # ディレクトリのパーミッションを設定（変更が必要なディレクトリのみ）
        find "$TARGET" -type d ! -perm 750 -exec sudo chmod 750 {} +

        # ファイルのパーミッションを設定（変更が必要なファイルのみ）
        find "$TARGET" -type f ! -perm 640 -exec sudo chmod 640 {} +

        # data ディレクトリの場合、ルートディレクトリのパーミッションを 700 に設定
        if [ "$dir" == "data" ]; then
            sudo chmod 700 "$TARGET"
        fi
    else
        echo "ディレクトリが存在しません: $TARGET"
    fi
done

echo "パーミッションの修正が完了しました"
