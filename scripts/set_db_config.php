<?php
// config.php の db* を 1 回の書き込みでまとめて切り替える (www-data で実行)
// occ config:system:set を 1 キーずつ実行すると、dbtype だけ変わった時点で occ が DB に接続できなくなるため
// 使い方: php set_db_config.php <dbtype> <dbname> <dbhost> <dbuser>   (パスワードは標準入力から 1 行)
if ($argc !== 5) {
	fwrite(STDERR, "usage: php set_db_config.php <dbtype> <dbname> <dbhost> <dbuser> < password\n");
	exit(2);
}
$file = '/var/www/html/config/config.php';
$CONFIG = [];
require $file;
$CONFIG['dbtype'] = $argv[1];
$CONFIG['dbname'] = $argv[2];
$CONFIG['dbhost'] = $argv[3];
$CONFIG['dbuser'] = $argv[4];
$CONFIG['dbpassword'] = rtrim((string)stream_get_contents(STDIN), "\r\n");
copy($file, $file . '.bak-' . date('YmdHis'));
file_put_contents($file, "<?php\n\$CONFIG = " . var_export($CONFIG, true) . ";\n", LOCK_EX);
if (function_exists('opcache_invalidate')) {
	opcache_invalidate($file, true);
}
echo "db config set: {$argv[1]} {$argv[2]}@{$argv[3]}\n";
