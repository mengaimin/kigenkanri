-- ============================================================
--  Supabase 追加マイグレーション
--  65歳超雇用推進助成金
--
--  使い方:
--    1. Supabase ダッシュボード → SQL Editor を開く
--    2. このファイルの内容をすべて貼り付けて Run
--    3. 最後の SELECT で cnt が 6 前後なら OK
--
--  画面に案件が出ない場合:
--    supabase_over65_samples.sql を再実行してください（RLS 無効化＋再投入）
-- ============================================================

-- ★ テーブル作成前後どちらでも、アプリから読めるよう RLS を無効化
ALTER TABLE IF EXISTS over65_applications DISABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TABLE IF NOT EXISTS over65_applications (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id          uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  target_name         text NOT NULL,
  course_type         text NOT NULL CHECK (course_type IN (
                        '①継続雇用促進','②雇用管理改善','③無期雇用転換')),
  measure_detail      text,
  plan_cert_date      date,
  implementation_date date,
  application_date    date,
  status              text NOT NULL DEFAULT '未申請'
                      CHECK (status IN (
                        '未申請','計画申請済','計画認定済','措置実施済',
                        '支給申請済','承認済','不承認')),
  notes               text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE over65_applications IS '65歳超雇用推進助成金 申請管理';

CREATE INDEX IF NOT EXISTS idx_over65_company ON over65_applications(company_id);

DROP TRIGGER IF EXISTS trg_over65_updated_at ON over65_applications;
CREATE TRIGGER trg_over65_updated_at
  BEFORE UPDATE ON over65_applications
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE over65_applications DISABLE ROW LEVEL SECURITY;

-- anon キー（アプリ）から読み書きできるよう RLS ポリシーを設定
DO $$
DECLARE pol record;
BEGIN
  FOR pol IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'over65_applications'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.over65_applications', pol.policyname);
  END LOOP;
END $$;

ALTER TABLE over65_applications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "over65_anon_all" ON over65_applications
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY "over65_authenticated_all" ON over65_applications
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

ALTER TABLE company_notes
  DROP CONSTRAINT IF EXISTS company_notes_subsidy_type_check;

ALTER TABLE company_notes
  ADD CONSTRAINT company_notes_subsidy_type_check
  CHECK (subsidy_type IN ('career_up','biz','work','dual','reskill','over65'));

CREATE OR REPLACE VIEW v_all_applications AS
  SELECT
    'career_up'           AS subsidy_type,
    '正社員化コース'       AS subsidy_label,
    id, company_id,
    employee_name         AS target_name,
    NULL                  AS sub_label,
    status_first          AS status,
    conversion_date       AS key_date,
    notes, created_at, updated_at
  FROM career_up_applications
UNION ALL
  SELECT
    'business_improvement', '業務改善助成金',
    id, company_id, NULL, wage_course, status,
    application_date, notes, created_at, updated_at
  FROM business_improvement_applications
UNION ALL
  SELECT
    'work_style', '働き方改革',
    id, company_id, NULL, goal_type, status,
    application_date, notes, created_at, updated_at
  FROM work_style_applications
UNION ALL
  SELECT
    'dual_support', '両立支援',
    id, company_id, employee_name, support_course, status,
    date1, notes, created_at, updated_at
  FROM dual_support_applications
UNION ALL
  SELECT
    'reskill', 'リスキリング支援',
    id, company_id, training_name, training_category, status,
    training_start_date, notes, created_at, updated_at
  FROM reskilling_applications
UNION ALL
  SELECT
    'over65', '65歳超雇用推進',
    id, company_id, target_name, course_type, status,
    implementation_date, notes, created_at, updated_at
  FROM over65_applications;

INSERT INTO over65_applications
  (company_id, target_name, course_type, measure_detail,
   plan_cert_date, implementation_date, application_date, status, notes)
SELECT c.id, v.target, v.course, v.measure,
       v.plan_date::date, v.impl_date::date, v.app_date::date, v.status, v.notes
FROM companies c
JOIN (VALUES
  ('株式会社テスト',       '定年65歳→68歳引上げ',     '①継続雇用促進', '就業規則改正・定年引上げ',           '2026-02-15', '2026-04-01', NULL,         '措置実施済',   '4/15までに支給申請'),
  ('テスト製造株式会社',   '定年の定め廃止',           '①継続雇用促進', '定年廃止・継続雇用制度',             '2026-04-01', '2026-06-15', '2026-07-10', '支給申請済',   ''),
  ('株式会社花子工業',     '高年齢者評価制度整備',     '②雇用管理改善', '評価制度・賃金規程改定',             '2026-03-20', '2026-05-01', NULL,         '計画認定済',   '5月実施済・申請準備中'),
  ('合同会社みらい',       '再雇用規程の整備',         '②雇用管理改善', '再雇用規程・就業規則改定',           '2026-06-01', '2026-07-01', NULL,         '措置実施済',   ''),
  ('株式会社太郎',         '田中一郎',                 '③無期雇用転換', '有期→無期転換（製造部）',            '2026-01-10', '2026-02-01', '2026-03-05', '承認済',       ''),
  ('株式会社あいうえお',   '佐藤花子',                 '③無期雇用転換', '有期→無期転換（事務）',              NULL,         NULL,         NULL,         '計画申請済',   '計画認定待ち')
) AS v(company_name, target, course, measure, plan_date, impl_date, app_date, status, notes)
  ON c.name = v.company_name
WHERE NOT EXISTS (
  SELECT 1 FROM over65_applications o
  WHERE o.company_id = c.id AND o.target_name = v.target AND o.course_type = v.course
);

-- 再確認
ALTER TABLE over65_applications ENABLE ROW LEVEL SECURITY;

SELECT 'over65_applications' AS tbl, COUNT(*) AS cnt FROM over65_applications;

SELECT c.name AS 会社, o.target_name AS 対象, o.course_type AS コース,
       o.status AS 状況, o.implementation_date AS 措置実施日
FROM over65_applications o
JOIN companies c ON c.id = o.company_id
ORDER BY o.status, c.name;
