-- ============================================================
--  Supabase 追加マイグレーション
--  人材開発支援助成金（事業展開等リスキリング支援コース）
--
--  使い方:
--    1. Supabase ダッシュボード → SQL Editor を開く
--    2. このファイルの内容をすべて貼り付けて Run
--    3. 最後の SELECT で reskill 件数が表示されれば OK
--
--  前提: companies / company_notes 等、既存テーブルが稼働中であること
--  参考: フォルダ内 kikan.sql は設計参考用（全量再実行用ではありません）
-- ============================================================

-- ------------------------------------------------------------
-- 1. リスキリング申請テーブル
-- ------------------------------------------------------------

-- updated_at 用関数（未作成の場合のみ定義）
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TABLE IF NOT EXISTS reskilling_applications (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id          uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  training_name       text NOT NULL,
  training_category   text CHECK (training_category IN (
                        '①新規事業・事業拡大','②DX推進','③GX推進','④その他事業展開')),
  trainee_count       smallint CHECK (trainee_count > 0),
  plan_submit_date    date,
  training_start_date date,
  training_end_date   date,
  exam_date           date,
  status              text NOT NULL DEFAULT '未申請'
                      CHECK (status IN (
                        '未申請','計画届提出済','訓練実施中',
                        '訓練完了（支給待）','支給申請済','承認済','不承認')),
  notes               text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE reskilling_applications IS
  '人材開発支援助成金（事業展開等リスキリング支援コース）';

CREATE INDEX IF NOT EXISTS idx_reskill_company
  ON reskilling_applications(company_id);

-- updated_at トリガー
DROP TRIGGER IF EXISTS trg_reskill_updated_at ON reskilling_applications;
CREATE TRIGGER trg_reskill_updated_at
  BEFORE UPDATE ON reskilling_applications
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE reskilling_applications DISABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------
-- 2. company_notes：助成金種別に reskill を追加
-- ------------------------------------------------------------
ALTER TABLE company_notes
  DROP CONSTRAINT IF EXISTS company_notes_subsidy_type_check;

ALTER TABLE company_notes
  ADD CONSTRAINT company_notes_subsidy_type_check
  CHECK (subsidy_type IN ('career_up','biz','work','dual','reskill','over65'));

-- ------------------------------------------------------------
-- 3. 統合ビュー更新（使用している場合のみ・未使用なら害なし）
-- ------------------------------------------------------------
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
  FROM reskilling_applications;

-- ------------------------------------------------------------
-- 4. サンプルデータ（任意・必要なければコメントアウト）
--    会社名が companies テーブルに存在する場合のみ投入
-- ------------------------------------------------------------
INSERT INTO reskilling_applications
  (company_id, training_name, training_category, trainee_count,
   plan_submit_date, training_start_date, training_end_date, exam_date, status, notes)
SELECT c.id, v.name, v.cat, v.cnt,
       v.plan_date::date, v.start_date::date, v.end_date::date, v.exam_date::date, v.status, v.notes
FROM companies c
JOIN (VALUES
  ('株式会社テスト',       'DX基礎研修（全社）',              '②DX推進',             12, '2026-04-10', '2026-06-01', '2026-09-30', NULL,         '訓練実施中',         ''),
  ('テスト商事株式会社',   '新規事業立上げマネジメント研修',   '①新規事業・事業拡大',   5,  NULL,         '2026-08-01', NULL,         NULL,         '未申請',             '計画届要作成（7/1期限）'),
  ('合同会社みらい',       'カーボンニュートラル実務研修',     '③GX推進',              8,  '2026-05-20', '2026-07-01', '2026-11-30', NULL,         '訓練完了（支給待）',   '支給申請2/28まで'),
  ('株式会社花子工業',     '情報処理安全確保支援士対策',       '②DX推進',              3,  '2026-09-01', '2026-11-01', '2027-01-31', '2027-02-15', '訓練実施中',         '受験後2か月以内に支給申請'),
  ('テスト製造株式会社',   'IoT・スマートファクトリー研修',    '②DX推進',              6,  '2026-07-15', '2026-09-01', NULL,         NULL,         '計画届提出済',       '10月開始予定'),
  ('有限会社サンプル商事', '小規模事業者向けAI活用講座',       '④その他事業展開',       4,  NULL,         '2026-10-01', NULL,         NULL,         '未申請',             '9/1までに計画届'),
  ('株式会社東京サービス', 'サービス業デジタル化研修',         '②DX推進',             10,  '2025-11-20', '2026-01-15', '2026-05-31', NULL,         '承認済',             ''),
  ('有限会社サンプル',     '省エネ・脱炭素基礎コース',         '③GX推進',              7,  '2026-03-01', '2026-04-01', '2026-08-31', NULL,         '支給申請済',         ''),
  ('株式会社太郎',         'ECサイト構築・運用研修',           '①新規事業・事業拡大',   2,  '2026-02-10', '2026-04-01', '2026-07-31', NULL,         '不承認',             '要件不備'),
  ('テスト製造株式会社',   'データ分析実践（Python）',         '②DX推進',              4,  '2026-11-05', '2027-01-10', '2027-03-20', NULL,         '計画届提出済',       '年度内完了見込み')
) AS v(company_name, name, cat, cnt, plan_date, start_date, end_date, exam_date, status, notes)
  ON c.name = v.company_name
WHERE NOT EXISTS (
  SELECT 1 FROM reskilling_applications r
  WHERE r.company_id = c.id AND r.training_name = v.name
);

-- ------------------------------------------------------------
-- 5. 確認
-- ------------------------------------------------------------
SELECT 'reskilling_applications' AS tbl, COUNT(*) AS cnt FROM reskilling_applications;
