-- ============================================================
--  Supabase 修正：65歳超 — RLS 解除 ＋ サンプル投入
--
--  症状: 画面は出るが案件が 0 件（RLS で anon から見えない）
--  使い方: SQL Editor に貼り付けて Run → ブラウザ再読み込み
-- ============================================================

-- 1. RLS を無効化（社内管理ツール用）
ALTER TABLE over65_applications DISABLE ROW LEVEL SECURITY;

-- 2. 既存ポリシーを削除（ダッシュボードで RLS 有効化した場合の対策）
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

-- 3. 念のため anon / authenticated 用の全許可ポリシー（RLS 再有効化時も読める）
ALTER TABLE over65_applications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "over65_anon_all" ON over65_applications
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY "over65_authenticated_all" ON over65_applications
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 4. 会社名マッチ確認
SELECT v.company_name AS サンプル会社,
       CASE WHEN c.id IS NOT NULL THEN '✓ 登録済' ELSE '✗ 未登録' END AS 状態
FROM (VALUES
  ('株式会社テスト'), ('テスト製造株式会社'), ('株式会社花子工業'),
  ('合同会社みらい'), ('株式会社太郎'), ('株式会社あいうえお')
) AS v(company_name)
LEFT JOIN companies c ON c.name = v.company_name
ORDER BY 1;

-- 5. サンプル 6 件投入
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

-- 6. 確認
SELECT COUNT(*) AS "65歳超件数" FROM over65_applications;

SELECT c.name AS 会社, o.target_name AS 対象, o.course_type AS コース,
       o.status AS 状況, o.implementation_date AS 措置実施日
FROM over65_applications o
JOIN companies c ON c.id = o.company_id
ORDER BY o.status, c.name;

-- RLS 状態確認（rowsecurity = false または policy あり）
SELECT relname, relrowsecurity AS rls有効
FROM pg_class
WHERE relname = 'over65_applications';

SELECT policyname, roles, cmd
FROM pg_policies
WHERE tablename = 'over65_applications';
