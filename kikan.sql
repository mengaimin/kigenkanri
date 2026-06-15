-- ============================================================
--  助成金統合管理システム  Supabase マイグレーション
--  対象: キャリアアップ / 業務改善 / 働き方改革 / 両立支援 / リスキリング / 65歳超
-- ============================================================

-- 拡張
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================
--  マスタ: 会社
-- ============================================================
CREATE TABLE companies (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL,
  size_category text CHECK (size_category IN ('30人未満','30人以上')),
  industry      text,
  notes         text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX companies_name_idx ON companies (name);
COMMENT ON TABLE companies IS '取引先企業マスタ';

-- ============================================================
--  キャリアアップ助成金（正社員化コース）
-- ============================================================
CREATE TABLE career_up_applications (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id          uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  employee_name       text NOT NULL,
  conversion_date     date,                        -- 正社員転換日
  salary_payment_day  smallint CHECK (salary_payment_day BETWEEN 1 AND 31),  -- 給与支給日（日のみ）
  is_priority_worker  boolean NOT NULL DEFAULT false,  -- 重点支援対象者
  status_first        text NOT NULL DEFAULT '未申請'
                      CHECK (status_first  IN ('未申請','申請済','承認済','不承認')),
  status_second       text
                      CHECK (status_second IN ('未申請','申請済','承認済','不承認')),
  notes               text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE career_up_applications IS 'キャリアアップ助成金（正社員化コース）申請管理';

-- ============================================================
--  業務改善助成金（令和8年度: 50/70/90円コース）
-- ============================================================
CREATE TABLE business_improvement_applications (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id            uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  wage_course           text CHECK (wage_course IN ('50円コース','70円コース','90円コース')),
  worker_count          text CHECK (worker_count IN ('1人','2〜3人','4〜5人','6〜7人','8人以上','10人以上（特例）')),
  special_category      text,                       -- 特例事業者区分
  equipment_description text,                       -- 設備投資内容
  application_date      date,                       -- 交付申請日
  decision_date         date,                       -- 交付決定日
  completion_date_actual date,                      -- 事業完了日（実績）
  status                text NOT NULL DEFAULT '未申請'
                        CHECK (status IN ('未申請','交付申請済','交付決定済','事業実施中',
                                          '事業完了（報告待）','事業実績報告済','支給申請済','承認済（助成金受領）')),
  notes                 text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE business_improvement_applications IS '業務改善助成金 申請管理（令和8年度）';

-- ============================================================
--  働き方改革推進支援助成金（労働時間短縮・年休促進支援コース）
-- ============================================================
CREATE TABLE work_style_applications (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id           uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  application_date     date,                        -- 交付申請日
  completion_date      date,                        -- 事業完了日
  goal_type            text,                        -- 成果目標（①②③）
  wage_increase_addon  boolean NOT NULL DEFAULT false,  -- 賃上げ加算
  overtime_rate_addon  boolean NOT NULL DEFAULT false,  -- 割増賃金率加算
  status               text NOT NULL DEFAULT '未申請'
                       CHECK (status IN ('未申請','交付申請済','交付決定済','事業実施中',
                                         '事業実績報告済','支給申請済','承認済')),
  notes                text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE work_style_applications IS '働き方改革推進支援助成金 申請管理（令和8年度）';

-- ============================================================
--  両立支援等助成金（6コース）
-- ============================================================
CREATE TABLE dual_support_applications (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id       uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  employee_name    text NOT NULL,
  person_in_charge text,                            -- 担当者名
  course_type      text NOT NULL
                   CHECK (course_type IN ('①出生時','②介護','③育児','④育休代替','⑤柔軟','⑥不妊治療')),
  support_course   text NOT NULL,                   -- 具体的な支給コース名
  --
  -- 各コースで意味が変わる日付 (date1〜date3)
  -- ①出生時:     date1=育休開始日, date2=育休終了日（起算日）
  -- ②介護(取得): date1=介護休業開始日, date2=5日取得達成日（起算日）
  -- ②介護(復帰): date1=介護休業開始日, date2=介護休業終了日（起算日）
  -- ③育児(取得): date1=計画届提出日, date2=育休開始日（起算日）
  -- ③育児(復帰): date1=育休開始日, date2=育休終了日（起算日）
  -- ④育休代替:   date1=育休開始日, date2=育休終了日（起算日）
  -- ⑤柔軟:      date1=対象措置利用開始日（起算日）
  -- ⑥不妊治療:  date1=休暇取得開始日, date2=5日達成日（起算日）
  --
  date1            date,
  date2            date,
  date3            date,
  --
  progress         text,                            -- 進捗メモ
  application_date date,                            -- 支給申請日（実績）
  status           text NOT NULL DEFAULT '未申請'
                   CHECK (status IN ('未申請','申請待ち','支給申請済','承認済','不承認','制度利用中',
                                     '育休中','介護休業中')),
  notes            text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE dual_support_applications IS '両立支援等助成金 申請管理（6コース）';

-- ============================================================
--  人材開発支援助成金（事業展開等リスキリング支援コース）
-- ============================================================
CREATE TABLE reskilling_applications (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id          uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  training_name       text NOT NULL,                -- 訓練名称
  training_category   text CHECK (training_category IN (
                        '①新規事業・事業拡大','②DX推進','③GX推進','④その他事業展開')),
  trainee_count       smallint CHECK (trainee_count > 0),
  plan_submit_date    date,                         -- 計画届提出日（実績）
  training_start_date date,                         -- 訓練開始日
  training_end_date   date,                         -- 訓練終了日
  exam_date           date,                         -- 受験日（資格試験等・支給申請起算）
  status              text NOT NULL DEFAULT '未申請'
                      CHECK (status IN ('未申請','計画届提出済','訓練実施中',
                                        '訓練完了（支給待）','支給申請済','承認済','不承認')),
  notes               text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE reskilling_applications IS '人材開発支援助成金（事業展開等リスキリング支援コース）';

-- ============================================================
--  65歳超雇用推進助成金
-- ============================================================
CREATE TABLE over65_applications (
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

-- ============================================================
--  updated_at 自動更新トリガー
-- ============================================================
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_companies_updated_at
  BEFORE UPDATE ON companies
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_career_up_updated_at
  BEFORE UPDATE ON career_up_applications
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_biz_updated_at
  BEFORE UPDATE ON business_improvement_applications
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_work_updated_at
  BEFORE UPDATE ON work_style_applications
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_dual_updated_at
  BEFORE UPDATE ON dual_support_applications
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_reskill_updated_at
  BEFORE UPDATE ON reskilling_applications
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_over65_updated_at
  BEFORE UPDATE ON over65_applications
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================
--  インデックス
-- ============================================================
CREATE INDEX idx_career_up_company  ON career_up_applications(company_id);
CREATE INDEX idx_biz_company        ON business_improvement_applications(company_id);
CREATE INDEX idx_work_company       ON work_style_applications(company_id);
CREATE INDEX idx_dual_company       ON dual_support_applications(company_id);
CREATE INDEX idx_dual_course        ON dual_support_applications(course_type);
CREATE INDEX idx_reskill_company    ON reskilling_applications(company_id);
CREATE INDEX idx_over65_company     ON over65_applications(company_id);

-- ============================================================
--  統合ダッシュボード用ビュー（期限日はアプリ側で計算）
-- ============================================================
CREATE OR REPLACE VIEW v_all_applications AS
  SELECT
    'career_up'           AS subsidy_type,
    '正社員化コース'       AS subsidy_label,
    id,
    company_id,
    employee_name         AS target_name,
    NULL                  AS sub_label,
    status_first          AS status,
    conversion_date       AS key_date,
    notes,
    created_at,
    updated_at
  FROM career_up_applications
UNION ALL
  SELECT
    'business_improvement'      AS subsidy_type,
    '業務改善助成金'              AS subsidy_label,
    id,
    company_id,
    NULL                         AS target_name,
    wage_course                  AS sub_label,
    status,
    application_date             AS key_date,
    notes,
    created_at,
    updated_at
  FROM business_improvement_applications
UNION ALL
  SELECT
    'work_style'                 AS subsidy_type,
    '働き方改革'                  AS subsidy_label,
    id,
    company_id,
    NULL                         AS target_name,
    goal_type                    AS sub_label,
    status,
    application_date             AS key_date,
    notes,
    created_at,
    updated_at
  FROM work_style_applications
UNION ALL
  SELECT
    'dual_support'               AS subsidy_type,
    '両立支援'                    AS subsidy_label,
    id,
    company_id,
    employee_name                AS target_name,
    support_course               AS sub_label,
    status,
    date1                        AS key_date,
    notes,
    created_at,
    updated_at
  FROM dual_support_applications
UNION ALL
  SELECT
    'reskill'                    AS subsidy_type,
    'リスキリング支援'            AS subsidy_label,
    id,
    company_id,
    training_name                AS target_name,
    training_category            AS sub_label,
    status,
    training_start_date          AS key_date,
    notes,
    created_at,
    updated_at
  FROM reskilling_applications
UNION ALL
  SELECT
    'over65'                     AS subsidy_type,
    '65歳超雇用推進'              AS subsidy_label,
    id,
    company_id,
    target_name                  AS target_name,
    course_type                  AS sub_label,
    status,
    implementation_date          AS key_date,
    notes,
    created_at,
    updated_at
  FROM over65_applications;

-- ============================================================
--  サンプルデータ（スプレッドシートの内容を移行）
-- ============================================================

-- 会社マスタ
INSERT INTO companies (name, size_category) VALUES
  ('株式会社テスト',         '30人以上'),
  ('有限会社サンプル商事',   '30人未満'),
  ('合同会社みらい',         '30人以上'),
  ('株式会社東京サービス',   '30人未満'),
  ('株式会社花子工業',       '30人以上'),
  ('テスト製造株式会社',     '30人以上'),
  ('有限会社サンプル',       '30人未満'),
  ('テスト商事株式会社',     '30人以上'),
  ('株式会社太郎',           '30人未満'),
  ('株式会社あいうえお',     '30人未満'),
  ('介護株式会社',           '30人未満'),
  ('育休株式会社',           '30人未満'),
  ('代替株式会社',           '30人未満'),
  ('株式会社代替',           '30人未満'),
  ('柔軟株式会社',           '30人未満'),
  ('株式会社柔軟',           '30人未満'),
  ('治療株式会社',           '30人未満'),
  ('株式会社治療',           '30人未満')
ON CONFLICT (name) DO NOTHING;

-- キャリアアップ（株式会社テスト）
INSERT INTO career_up_applications
  (company_id, employee_name, conversion_date, salary_payment_day, is_priority_worker, status_first, status_second, notes)
SELECT c.id, v.employee_name, v.conversion_date::date, v.salary_payment_day, v.is_priority,
       v.status_first, v.status_second, v.notes
FROM companies c
CROSS JOIN (VALUES
  ('テスト　イエン様', '2025-03-01', 25, true,  '承認済', '申請済',  ''),
  ('テスト　花子',     '2025-06-01', 10, false, '未申請', NULL,      ''),
  ('山田　太郎',       '2025-10-01', 15, true,  '承認済', '未申請',  ''),
  ('田中　恵子',       '2025-06-09', 10, true,  '承認済', '未申請',  ''),
  ('テスト　山田',     '2026-07-01', 10, true,  '未申請', '未申請',  ''),
  ('テスト　太郎',     '2025-12-01', 5,  false, '未申請', NULL,      '')
) AS v(employee_name, conversion_date, salary_payment_day, is_priority, status_first, status_second, notes)
WHERE c.name = '株式会社テスト';

-- 業務改善
INSERT INTO business_improvement_applications
  (company_id, wage_course, worker_count, special_category, equipment_description,
   application_date, decision_date, completion_date_actual, status, notes)
SELECT c.id, v.wage_course, v.worker_count, v.special_cat, v.equip,
       v.app_date::date, v.dec_date::date, v.comp_date::date, v.status, v.notes
FROM companies c
JOIN (VALUES
  ('テスト製造株式会社', '70円コース', '4〜5人',  'なし',                              '食洗機・配膳ロボット',  '2026-09-15', '2026-11-01', NULL,         '事業実施中',         ''),
  ('有限会社サンプル商事','50円コース','1人',     '賃金要件（最低賃金1,050円未満）',  'POSシステム導入',       '2026-10-05', '2026-11-20', NULL,         '交付申請済',         ''),
  ('合同会社みらい',      '90円コース','8人以上', '物価高騰等要件（利益率3%ポイント以上低下）','生産ライン自動化設備','2026-10-20','2026-12-05','2027-01-20','事業完了（報告待）', '支給申請2/20まで'),
  ('株式会社東京サービス','50円コース','2〜3人',  'なし',                              NULL,                    NULL,         NULL,         NULL,         '未申請',             '9月以降予定'),
  ('株式会社花子工業',    '70円コース','4〜5人',  'なし',                              'NC工作機械',            '2026-11-05', '2026-12-20', '2027-01-31', '事業実績報告済',     '2/28支給申請期限')
) AS v(company_name, wage_course, worker_count, special_cat, equip, app_date, dec_date, comp_date, status, notes)
ON c.name = v.company_name;

-- 働き方改革
INSERT INTO work_style_applications
  (company_id, application_date, completion_date, goal_type, wage_increase_addon, overtime_rate_addon, status, notes)
SELECT c.id, v.app_date::date, v.comp_date::date, v.goal, v.wage_add, v.over_add, v.status, v.notes
FROM companies c
JOIN (VALUES
  ('株式会社テスト',      '2026-05-10', '2026-12-15', '①時間外労働の削減',           true,  false, '交付決定済',  ''),
  ('有限会社サンプル',    '2026-06-01', NULL,         '②③（年休＋インターバル）',    false, false, '交付申請済',  ''),
  ('テスト商事株式会社',  '2026-09-15', NULL,         '①②（時間外＋年休）',          true,  true,  '未申請',      '要急ぎ'),
  ('合同会社みらい',      NULL,         NULL,         '①時間外労働の削減',           true,  false, '未申請',      ''),
  ('株式会社花子工業',    '2026-11-01', NULL,         '③勤務間インターバルの導入',    false, false, '交付申請済',  '')
) AS v(company_name, app_date, comp_date, goal, wage_add, over_add, status, notes)
ON c.name = v.company_name;

-- 両立支援
INSERT INTO dual_support_applications
  (company_id, employee_name, person_in_charge, course_type, support_course, date1, date2, status, progress, notes)
SELECT c.id, v.emp, v.pic, v.course_type, v.support_course,
       v.d1::date, v.d2::date, v.status, v.progress, v.notes
FROM companies c
JOIN (VALUES
  ('株式会社テスト',  'テスト太郎', 'テスト担当',  '①出生時', '出生時両立支援（第1種）', '2025-10-01', '2026-01-30', '承認済',     '承認済',       ''),
  ('株式会社太郎',    'テスト花子', 'テスト主任',  '①出生時', '出生時両立支援（第1種）', '2025-08-01', '2026-02-01', '不承認',     '不承認',       ''),
  ('株式会社あいうえお','田中　花子','田中担当',  '①出生時', '出生時両立支援（第1種）', '2026-01-01', '2026-06-01', '申請待ち',    '支給申請待ち', ''),
  ('介護株式会社',    '介護太郎',  '介護担当',    '②介護',   '介護離職防止（休業取得時）','2026-06-11','2026-06-18', '介護休業中', '介護休業中',   ''),
  ('育休株式会社',    '育休太郎',  '育休担当',    '③育児',   '育児休業等支援（育休取得時）','2026-05-01','2026-06-01','育休中',    '育休中',       ''),
  ('代替株式会社',    '代替太郎',  '代替担当',    '④育休代替','育休中等業務代替（1ヶ月未満）','2026-06-01','2026-07-01','育休中',   '育休中',       ''),
  ('株式会社代替',    '代替花子',  '代替主任',    '④育休代替','育休中等業務代替（1ヶ月以上）','2025-12-01','2026-12-01','育休中',   '育休中',       ''),
  ('柔軟株式会社',    '柔軟太郎',  '柔軟担当',    '⑤柔軟',   '柔軟な働き方選択制度',   '2026-06-01', NULL,         '制度利用中', '制度利用中',   ''),
  ('株式会社柔軟',    '柔軟花子',  '柔軟主任',    '⑤柔軟',   '柔軟な働き方選択制度',   '2025-06-01', NULL,         '承認済',     '承認済',       ''),
  ('治療株式会社',    '治療太郎',  '治療担当',    '⑥不妊治療','不妊治療両立支援',      '2026-06-01', '2026-06-06', '申請待ち',   '5日達成・申請待ち',''),
  ('株式会社治療',    '治療花子',  '治療主任',    '⑥不妊治療','不妊治療両立支援',      '2026-10-01', '2026-10-06', '未申請',     '',             '')
) AS v(company_name, emp, pic, course_type, support_course, d1, d2, status, progress, notes)
ON c.name = v.company_name;

-- リスキリング支援
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
ON c.name = v.company_name;

-- 65歳超雇用推進
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
ON c.name = v.company_name;

-- RLS を無効化（社内管理ツールのため）
ALTER TABLE companies                        DISABLE ROW LEVEL SECURITY;
ALTER TABLE career_up_applications           DISABLE ROW LEVEL SECURITY;
ALTER TABLE business_improvement_applications DISABLE ROW LEVEL SECURITY;
ALTER TABLE work_style_applications          DISABLE ROW LEVEL SECURITY;
ALTER TABLE dual_support_applications        DISABLE ROW LEVEL SECURITY;
ALTER TABLE reskilling_applications          DISABLE ROW LEVEL SECURITY;
ALTER TABLE over65_applications              DISABLE ROW LEVEL SECURITY;

-- データ件数確認
SELECT 'companies' AS tbl, COUNT(*) FROM companies
UNION ALL SELECT 'career_up',  COUNT(*) FROM career_up_applications
UNION ALL SELECT 'biz',        COUNT(*) FROM business_improvement_applications
UNION ALL SELECT 'work',       COUNT(*) FROM work_style_applications
UNION ALL SELECT 'dual',       COUNT(*) FROM dual_support_applications
UNION ALL SELECT 'reskill',    COUNT(*) FROM reskilling_applications
UNION ALL SELECT 'over65',    COUNT(*) FROM over65_applications;



CREATE TABLE IF NOT EXISTS company_notes (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id   uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  note_date    date NOT NULL DEFAULT CURRENT_DATE,
  content      text NOT NULL,
  author       text,
  subsidy_type text CHECK (subsidy_type IN ('career_up','biz','work','dual','reskill','over65')),
  created_at   timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE company_notes DISABLE ROW LEVEL SECURITY;
CREATE INDEX ON company_notes(company_id);

-- 既存DBへ追加する場合: reskilling_applications テーブル作成と
-- company_notes の subsidy_type 制約更新（'reskill' 追加）を実行してください。