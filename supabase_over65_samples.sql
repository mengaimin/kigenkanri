-- ============================================================
--  ※ このファイルは supabase_all_status_samples.sql に統合しました
--  65歳超のみ投入する場合も、下記を実行してください
-- ============================================================

-- Supabase SQL Editor では \i が使えないため、
-- supabase_all_status_samples.sql の内容をそのまま Run してください。

-- RLS（65歳超テーブルが見えない場合）
ALTER TABLE over65_applications DISABLE ROW LEVEL SECURITY;

DO $$ DECLARE pol record; BEGIN
  FOR pol IN SELECT policyname FROM pg_policies WHERE tablename = 'over65_applications'
  LOOP EXECUTE format('DROP POLICY IF EXISTS %I ON over65_applications', pol.policyname); END LOOP;
END $$;

ALTER TABLE over65_applications ENABLE ROW LEVEL SECURITY;
CREATE POLICY "over65_anon_all" ON over65_applications FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY "over65_authenticated_all" ON over65_applications FOR ALL TO authenticated USING (true) WITH CHECK (true);
