# pecl channel-update は XML エラーで常に失敗するが、無視しても install は成功するため続行する
# bash -c の文字列内は行継続で 1 行に連結されるため、文字列の中にコメントを書かない
docker exec nextcloud_app bash -c "\
    apt-get update && \
    apt-get install -y \
        smbclient \
        libsmbclient-dev \
        build-essential \
        cifs-utils && \
    (pecl channel-update pecl.php.net || true) && \
    pecl install smbclient && \
    docker-php-ext-enable smbclient
"
