-- db:convert-type (NC 35.0.2) が最後の sequence 再同期で失敗したときの手動補完
-- 原因: スキーマ作成時に、列既定値から参照されない孤立 sequence (oc_jobs / oc_previews / oc_preview_locations / oc_preview_versions の id_seq) が残り、
--       PgSqlTools::resynchronizeDatabaseSequences が "SELECT MAX() FROM" という空の SQL を発行する
-- 1. 孤立 sequence を削除 (どの列の既定値からも参照されないもの。id 列に OWNED BY は残っているが既定値は外れている。
--    新規インストールの PostgreSQL にはこれらの sequence は存在しない)
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT c.relname AS seq
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'S' AND n.nspname = current_schema()
      AND NOT EXISTS (SELECT 1 FROM information_schema.columns col
                      WHERE col.table_catalog = current_database()
                        AND col.column_default = 'nextval(''' || c.relname || '''::regclass)')
  LOOP
    RAISE NOTICE 'drop orphan sequence %', r.seq;
    EXECUTE format('DROP SEQUENCE %I', r.seq);
  END LOOP;
END $$;

-- 2. 残りの sequence を MAX(id) に合わせる (convert-type が本来行う処理。空テーブルは 1 / is_called=false)
DO $$
DECLARE r record; m bigint; n int := 0;
BEGIN
  FOR r IN
    SELECT s.sequence_name, col.table_name, col.column_name
    FROM information_schema.sequences s
    JOIN information_schema.columns col
      ON col.table_catalog = current_database()
     AND col.column_default = 'nextval(''' || s.sequence_name || '''::regclass)'
    WHERE s.sequence_schema = current_schema()
  LOOP
    EXECUTE format('SELECT MAX(%I) FROM %I', r.column_name, r.table_name) INTO m;
    IF m IS NULL THEN
      PERFORM setval(quote_ident(r.sequence_name)::regclass, 1, false);
    ELSE
      PERFORM setval(quote_ident(r.sequence_name)::regclass, m, true);
    END IF;
    n := n + 1;
  END LOOP;
  RAISE NOTICE 'resynced % sequences', n;
END $$;
