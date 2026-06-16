-- ============================================================
--  全助成金 × 全ステータス × 期限バッジ サンプル一括投入
--
--  基準日: 2026-06-15（この日付前後で 🔴期限切れ / 🟠7日 / 🟡30日 / 🟢余裕 を再現）
--
--  使い方: SQL Editor で Run → ブラウザ再読み込み
--  ※ 「サンプル：」で始まる会社の案件のみ削除して入れ直します
-- ============================================================

ALTER TABLE companies DISABLE ROW LEVEL SECURITY;
ALTER TABLE career_up_applications DISABLE ROW LEVEL SECURITY;
ALTER TABLE business_improvement_applications DISABLE ROW LEVEL SECURITY;
ALTER TABLE work_style_applications DISABLE ROW LEVEL SECURITY;
ALTER TABLE dual_support_applications DISABLE ROW LEVEL SECURITY;
ALTER TABLE reskilling_applications DISABLE ROW LEVEL SECURITY;
ALTER TABLE over65_applications DISABLE ROW LEVEL SECURITY;
ALTER TABLE company_notes DISABLE ROW LEVEL SECURITY;

ALTER TABLE over65_applications DISABLE ROW LEVEL SECURITY;

DO $$ DECLARE pol record; BEGIN
  FOR pol IN SELECT policyname FROM pg_policies WHERE tablename = 'over65_applications'
  LOOP EXECUTE format('DROP POLICY IF EXISTS %I ON over65_applications', pol.policyname); END LOOP;
END $$;

ALTER TABLE over65_applications ENABLE ROW LEVEL SECURITY;
CREATE POLICY "over65_anon_all" ON over65_applications FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY "over65_authenticated_all" ON over65_applications FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- サンプル会社の案件をクリア
DELETE FROM company_notes WHERE company_id IN (SELECT id FROM companies WHERE name LIKE 'サンプル：%');
DELETE FROM career_up_applications WHERE company_id IN (SELECT id FROM companies WHERE name LIKE 'サンプル：%');
DELETE FROM business_improvement_applications WHERE company_id IN (SELECT id FROM companies WHERE name LIKE 'サンプル：%');
DELETE FROM work_style_applications WHERE company_id IN (SELECT id FROM companies WHERE name LIKE 'サンプル：%');
DELETE FROM dual_support_applications WHERE company_id IN (SELECT id FROM companies WHERE name LIKE 'サンプル：%');
DELETE FROM reskilling_applications WHERE company_id IN (SELECT id FROM companies WHERE name LIKE 'サンプル：%');
DELETE FROM over65_applications WHERE company_id IN (SELECT id FROM companies WHERE name LIKE 'サンプル：%');
DELETE FROM companies WHERE name LIKE 'サンプル：%';

-- 会社（社内担当者付き）
INSERT INTO companies (name, size_category, industry, internal_assignee, notes) VALUES
  ('サンプル：全状況デモ株式会社', '30人以上', '製造業', '山田', '全ステータス・全助成金の見本データ'),
  ('サンプル：期限切れ商事',       '30人未満', '小売',   '佐藤', '🔴 期限超過の案件あり'),
  ('サンプル：今週期限工業',       '30人以上', '建設',   '鈴木', '🟠 7日以内の案件あり'),
  ('サンプル：30日以内有限',       '30人未満', 'サービス','高橋', '🟡 30日以内の案件あり'),
  ('サンプル：余裕ありサービス',   '30人以上', 'IT',     '伊藤', '🟢 余裕あり・完了済み');

-- ============================================================
--  👔 キャリアアップ（status_first / status_second 全パターン）
-- ============================================================
INSERT INTO career_up_applications
  (company_id, employee_name, conversion_date, salary_payment_day, is_priority_worker, status_first, status_second, notes)
SELECT c.id, v.emp, v.conv::date, v.pd, v.pri, v.sf, v.ss, v.notes
FROM companies c
JOIN (VALUES
  -- 1回目: 未申請 🟠残5日 / 2回目: —
  ('サンプル：今週期限工業', '佐藤 健太', '2025-12-20', 15, false, '未申請', NULL,      '【全状況】1回目🟠'),
  -- 1回目: 申請済 / 2回目: 重点・未申請
  ('サンプル：全状況デモ株式会社', '鈴木 美咲', '2025-10-01', 25, true,  '申請済', '未申請', '【全状況】1回目申請済・2回目待ち'),
  -- 1回目: 承認済 ✅ / 2回目: 申請済
  ('サンプル：全状況デモ株式会社', '高橋 一郎', '2025-06-01', 10, true,  '承認済', '申請済', '【全状況】2回目申請済'),
  -- 1回目: 不承認
  ('サンプル：全状況デモ株式会社', '伊藤 翔',   '2025-08-01', 20, false, '不承認', NULL,     '【全状況】1回目不承認'),
  -- 1回目: 🔴期限切れ
  ('サンプル：期限切れ商事',       '渡辺 由美', '2024-03-01', 25, false, '未申請', NULL,     '【全状況】1回目🔴'),
  -- 1回目: 承認済 / 2回目: 承認済 ✅
  ('サンプル：余裕ありサービス',   '中村 亮',   '2024-01-01', 15, true,  '承認済', '承認済', '【全状況】完了'),
  -- 1回目: 承認済 / 2回目: 不承認
  ('サンプル：全状況デモ株式会社', '小林 麻衣', '2025-04-01', 10, true,  '承認済', '不承認', '【全状況】2回目不承認'),
  -- 1回目: 未申請 🟢余裕
  ('サンプル：余裕ありサービス',   '加藤 直樹', '2026-01-15', 25, false, '未申請', NULL,     '【全状況】1回目🟢')
) AS v(co, emp, conv, pd, pri, sf, ss, notes) ON c.name = v.co;

-- ============================================================
--  🏭 業務改善（全8ステータス）
-- ============================================================
INSERT INTO business_improvement_applications
  (company_id, wage_course, worker_count, equipment_description, application_date, decision_date, completion_date_actual, status, notes)
SELECT c.id, v.course, v.wc, v.eq, v.ad::date, v.dd::date, v.cd::date, v.st, v.notes
FROM companies c
JOIN (VALUES
  ('サンプル：全状況デモ株式会社', '50円コース', '2〜3人',  'POSレジ',           NULL,         NULL,         NULL,         '未申請',             '【全状況】未申請'),
  ('サンプル：全状況デモ株式会社', '50円コース', '1人',     '冷蔵ショーケース',   '2026-05-01', NULL,         NULL,         '交付申請済',         '【全状況】交付申請済'),
  ('サンプル：30日以内有限',       '70円コース', '4〜5人',  '自動包装機',         '2026-04-01', '2026-05-15', NULL,         '交付決定済',         '【全状況】交付決定済'),
  ('サンプル：今週期限工業',       '70円コース', '6〜7人',  '搬送ロボット',       '2026-03-01', '2026-04-01', NULL,         '事業実施中',         '【全状況】事業実施中・完了🟡'),
  ('サンプル：全状況デモ株式会社', '90円コース', '8人以上', 'ライン自動化',       '2026-02-01', '2026-03-01', NULL,         '事業完了（報告待）', '【全状況】報告待'),
  ('サンプル：期限切れ商事',       '70円コース', '4〜5人',  'NC工作機械',         '2026-01-01', '2026-02-01', '2026-05-01', '事業実績報告済',     '【全状況】支給🔴期限切れ'),
  ('サンプル：全状況デモ株式会社', '90円コース', '10人以上（特例）','大型プレス','2025-10-01','2025-11-01','2026-03-01', '支給申請済',         '【全状況】支給申請済'),
  ('サンプル：余裕ありサービス',   '50円コース', '2〜3人',  '業務PC更新',         '2025-08-01', '2025-09-01', '2025-12-01', '承認済（助成金受領）','【全状況】完了✅')
) AS v(co, course, wc, eq, ad, dd, cd, st, notes) ON c.name = v.co;

-- ============================================================
--  ⏰ 働き方改革（全7ステータス）
-- ============================================================
INSERT INTO work_style_applications
  (company_id, application_date, completion_date, goal_type, wage_increase_addon, overtime_rate_addon, status, notes)
SELECT c.id, v.ad::date, v.cd::date, v.goal, v.wa, v.oa, v.st, v.notes
FROM companies c
JOIN (VALUES
  ('サンプル：全状況デモ株式会社', NULL,         NULL,         '①時間外労働の削減',           false, false, '未申請',       '【全状況】未申請・交付🟡'),
  ('サンプル：30日以内有限',       '2026-05-20', NULL,         '②年次有給休暇の取得促進',     true,  false, '交付申請済',   '【全状況】交付申請済'),
  ('サンプル：今週期限工業',       '2026-04-01', NULL,         '③勤務間インターバルの導入',   false, false, '交付決定済',   '【全状況】交付決定済'),
  ('サンプル：全状況デモ株式会社', '2026-03-01', NULL,         '①②（時間外＋年休）',          true,  true,  '事業実施中',   '【全状況】事業実施中'),
  ('サンプル：期限切れ商事',       '2026-01-01', '2026-04-01', '①時間外労働の削減',           true,  false, '事業実績報告済','【全状況】支給🔴期限切れ'),
  ('サンプル：全状況デモ株式会社', '2025-11-01', '2026-02-01', '②③（年休＋インターバル）',    false, false, '支給申請済',   '【全状況】支給申請済'),
  ('サンプル：余裕ありサービス',   '2025-06-01', '2025-10-01', '①時間外労働の削減',           true,  false, '承認済',       '【全状況】完了✅')
) AS v(co, ad, cd, goal, wa, oa, st, notes) ON c.name = v.co;

-- ============================================================
--  👶 両立支援（全8ステータス × 6コース分類）
-- ============================================================
INSERT INTO dual_support_applications
  (company_id, employee_name, person_in_charge, course_type, support_course, date1, date2, status, progress, notes)
SELECT c.id, v.emp, v.pic, v.ct, v.sc, v.d1::date, v.d2::date, v.st, v.pr, v.notes
FROM companies c
JOIN (VALUES
  ('サンプル：全状況デモ株式会社', '【DU】未申請',     '担当A', '⑥不妊治療', '不妊治療両立支援',               '2026-10-01', '2026-10-06', '未申請',     '',           '【全状況】未申請'),
  ('サンプル：今週期限工業',       '【DU】申請待ち',   '担当B', '⑥不妊治療', '不妊治療両立支援',               '2026-06-01', '2026-06-06', '申請待ち',   '5日達成',    '【全状況】申請待ち・🟠'),
  ('サンプル：全状況デモ株式会社', '【DU】支給申請済', '担当C', '②介護',     '介護離職防止（職場復帰時）',     '2025-08-01', '2026-01-15', '支給申請済', '審査中',     '【全状況】支給申請済'),
  ('サンプル：余裕ありサービス',   '【DU】承認済',     '担当D', '⑤柔軟',     '柔軟な働き方選択制度',           '2025-06-01', NULL,         '承認済',     '完了',       '【全状況】承認済✅'),
  ('サンプル：全状況デモ株式会社', '【DU】不承認',     '担当E', '①出生時',   '出生時両立支援（第1種）',        '2025-05-01', '2025-09-01', '不承認',     '不支給',     '【全状況】不承認'),
  ('サンプル：30日以内有限',       '【DU】制度利用中', '担当F', '⑤柔軟',     '柔軟な働き方選択制度',           '2026-05-01', NULL,         '制度利用中', '利用中',     '【全状況】制度利用中'),
  ('サンプル：全状況デモ株式会社', '【DU】育休中',     '担当G', '③育児',     '育児休業等支援（育休取得時）',   '2026-04-01', '2026-06-01', '育休中',     '育休中',     '【全状況】育休中'),
  ('サンプル：期限切れ商事',       '【DU】介護休業中', '担当H', '②介護',     '介護離職防止（休業取得時）',     '2026-03-01', '2026-04-14', '介護休業中', '休業中・🔴', '【全状況】介護休業中・期限切れ'),
  ('サンプル：全状況デモ株式会社', '【DU】育休代替短', '担当I', '④育休代替', '育休中等業務代替（1ヶ月未満）',  '2026-05-15', '2026-06-15', '育休中',     '代替中',     '【全状況】④代替1ヶ月未満'),
  ('サンプル：30日以内有限',       '【DU】育休代替長', '担当J', '④育休代替', '育休中等業務代替（1ヶ月以上）',  '2025-12-01', '2026-06-01', '制度利用中', '代替中',     '【全状況】④代替1ヶ月以上'),
  ('サンプル：今週期限工業',       '【DU】育児復帰',   '担当K', '③育児',     '育児休業等支援（職場復帰時）',   '2026-01-01', '2026-04-20', '申請待ち',   '復帰・🟠',   '【全状況】③復帰・7日以内')
) AS v(co, emp, pic, ct, sc, d1, d2, st, pr, notes) ON c.name = v.co;

-- ============================================================
--  📚 リスキリング（全7ステータス × 4区分）
-- ============================================================
INSERT INTO reskilling_applications
  (company_id, training_name, training_category, trainee_count, plan_submit_date, training_start_date, training_end_date, exam_date, status, notes)
SELECT c.id, v.nm, v.cat, v.cnt, v.pd::date, v.sd::date, v.ed::date, v.ex::date, v.st, v.notes
FROM companies c
JOIN (VALUES
  ('サンプル：全状況デモ株式会社', '【RS】未申請',         '①新規事業・事業拡大', 5,  NULL,         '2026-09-01', NULL,         NULL,         '未申請',             '【全状況】計画届未提出'),
  ('サンプル：30日以内有限',       '【RS】計画届提出済',   '②DX推進',             8,  '2026-05-01', '2026-07-01', NULL,         NULL,         '計画届提出済',       '【全状況】訓練開始前'),
  ('サンプル：今週期限工業',       '【RS】訓練実施中',     '②DX推進',            10,  '2026-04-01', '2026-06-01', '2026-09-30', NULL,         '訓練実施中',         '【全状況】訓練中'),
  ('サンプル：全状況デモ株式会社', '【RS】訓練完了支給待', '③GX推進',             6,  '2026-03-01', '2026-04-01', '2026-05-31', NULL,         '訓練完了（支給待）', '【全状況】支給🟠'),
  ('サンプル：全状況デモ株式会社', '【RS】支給申請済',     '④その他事業展開',     4,  '2026-02-01', '2026-03-01', '2026-05-01', NULL,         '支給申請済',         '【全状況】支給申請済'),
  ('サンプル：余裕ありサービス',   '【RS】承認済',         '②DX推進',            12,  '2025-10-01', '2025-12-01', '2026-03-31', NULL,         '承認済',             '【全状況】完了✅'),
  ('サンプル：期限切れ商事',       '【RS】不承認',         '①新規事業・事業拡大', 3,  '2025-08-01', '2025-10-01', '2026-01-31', '2026-02-15', '不承認',             '【全状況】不承認')
) AS v(co, nm, cat, cnt, pd, sd, ed, ex, st, notes) ON c.name = v.co;

-- ============================================================
--  👴 65歳超（全7ステータス × 3コース）
-- ============================================================
INSERT INTO over65_applications
  (company_id, target_name, course_type, measure_detail, plan_cert_date, implementation_date, application_date, status, notes)
SELECT c.id, v.tgt, v.ct, v.ms, v.pc::date, v.im::date, v.ap::date, v.st, v.notes
FROM companies c
JOIN (VALUES
  ('サンプル：全状況デモ株式会社', '【O65】未申請',       '③無期雇用転換', '転換予定・計画前',           NULL,         NULL,         NULL,         '未申請',     '【全状況】未申請'),
  ('サンプル：30日以内有限',       '【O65】計画申請済',   '②雇用管理改善', '評価制度整備（申請中）',     NULL,         NULL,         NULL,         '計画申請済', '【全状況】計画申請済'),
  ('サンプル：今週期限工業',       '【O65】計画認定済',   '②雇用管理改善', '評価制度整備',               '2026-04-01', NULL,         NULL,         '計画認定済', '【全状況】措置前'),
  ('サンプル：全状況デモ株式会社', '【O65】措置実施済',   '①継続雇用促進', '定年65→68歳引上げ',          '2026-02-01', '2026-06-01', NULL,         '措置実施済', '【全状況】支給🟠本日付近'),
  ('サンプル：期限切れ商事',       '【O65】措置実施済2',  '①継続雇用促進', '定年廃止',                   '2026-01-01', '2026-02-01', NULL,         '措置実施済', '【全状況】支給🔴期限切れ'),
  ('サンプル：全状況デモ株式会社', '【O65】支給申請済',   '③無期雇用転換', '山田太郎・製造部',           '2026-01-10', '2026-02-01', '2026-03-10', '支給申請済', '【全状況】支給申請済'),
  ('サンプル：余裕ありサービス',   '【O65】承認済',       '①継続雇用促進', '定年70歳引上げ',             '2025-08-01', '2025-10-01', '2025-12-05', '承認済',     '【全状況】完了✅'),
  ('サンプル：全状況デモ株式会社', '【O65】不承認',       '③無期雇用転換', '佐藤花子・事務',             '2025-06-01', '2025-08-01', '2025-10-01', '不承認',     '【全状況】不承認')
) AS v(co, tgt, ct, ms, pc, im, ap, st, notes) ON c.name = v.co;

-- ============================================================
--  📝 会社メモ（履歴タイムライン用）
-- ============================================================
INSERT INTO company_notes (company_id, note_date, content, author, subsidy_type)
SELECT c.id, v.dt::date, v.content, v.author, v.sub
FROM companies c
JOIN (VALUES
  ('サンプル：全状況デモ株式会社', '2026-06-10', '初回ヒアリング実施。書類一覧を共有。', '山田', 'biz'),
  ('サンプル：今週期限工業',       '2026-06-14', '期限が近い案件3件を確認。',             '鈴木', NULL),
  ('サンプル：期限切れ商事',       '2026-06-01', '期限超過分の対応方針を協議。',           '佐藤', 'career_up')
) AS v(co, dt, content, author, sub) ON c.name = v.co;

-- ============================================================
--  確認（ステータス網羅チェック）
-- ============================================================
SELECT 'companies' AS テーブル, COUNT(*) AS 件数 FROM companies WHERE name LIKE 'サンプル：%'
UNION ALL SELECT 'career_up',  COUNT(*) FROM career_up_applications WHERE notes LIKE '【全状況】%'
UNION ALL SELECT 'biz',        COUNT(*) FROM business_improvement_applications WHERE notes LIKE '【全状況】%'
UNION ALL SELECT 'work',       COUNT(*) FROM work_style_applications WHERE notes LIKE '【全状況】%'
UNION ALL SELECT 'dual',       COUNT(*) FROM dual_support_applications WHERE notes LIKE '【全状況】%'
UNION ALL SELECT 'reskill',    COUNT(*) FROM reskilling_applications WHERE notes LIKE '【全状況】%'
UNION ALL SELECT 'over65',     COUNT(*) FROM over65_applications WHERE notes LIKE '【全状況】%'
UNION ALL SELECT 'notes',      COUNT(*) FROM company_notes cn JOIN companies c ON c.id = cn.company_id WHERE c.name LIKE 'サンプル：%';

SELECT '👔 CU status_first' AS 区分, status_first AS 値, COUNT(*) FROM career_up_applications WHERE notes LIKE '【全状況】%' GROUP BY status_first
UNION ALL SELECT '🏭 BIZ', status, COUNT(*) FROM business_improvement_applications WHERE notes LIKE '【全状況】%' GROUP BY status
UNION ALL SELECT '⏰ WORK', status, COUNT(*) FROM work_style_applications WHERE notes LIKE '【全状況】%' GROUP BY status
UNION ALL SELECT '👶 DUAL', status, COUNT(*) FROM dual_support_applications WHERE notes LIKE '【全状況】%' GROUP BY status
UNION ALL SELECT '📚 RS', status, COUNT(*) FROM reskilling_applications WHERE notes LIKE '【全状況】%' GROUP BY status
UNION ALL SELECT '👴 O65', status, COUNT(*) FROM over65_applications WHERE notes LIKE '【全状況】%' GROUP BY status
ORDER BY 1, 2;
