-- ============================================================
--  Supabase 追加：リスキリング支援 サンプル案件（10件）
--
--  使い方:
--    1. 先に supabase_add_reskilling.sql を実行済みであること
--    2. SQL Editor に貼り付けて Run
--    3. 最後の SELECT で件数が 1 以上なら OK
-- ============================================================

ALTER TABLE reskilling_applications DISABLE ROW LEVEL SECURITY;

INSERT INTO companies (name, size_category) VALUES
  ('テスト商事株式会社', '30人以上')
ON CONFLICT (name) DO NOTHING;

SELECT v.company_name AS サンプル会社,
       CASE WHEN c.id IS NOT NULL THEN '✓ 登録済' ELSE '✗ 未登録' END AS 状態
FROM (VALUES
  ('株式会社テスト'), ('テスト商事株式会社'), ('合同会社みらい'),
  ('株式会社花子工業'), ('テスト製造株式会社'), ('有限会社サンプル商事'),
  ('株式会社東京サービス'), ('有限会社サンプル'), ('株式会社太郎')
) AS v(company_name)
LEFT JOIN companies c ON c.name = v.company_name
ORDER BY 1;

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

SELECT COUNT(*) AS リスキリング件数 FROM reskilling_applications;

SELECT c.name AS 会社, r.training_name AS 訓練, r.training_category AS 区分,
       r.status AS 状況, r.training_start_date AS 開始, r.training_end_date AS 終了
FROM reskilling_applications r
JOIN companies c ON c.id = r.company_id
ORDER BY r.status, c.name;
