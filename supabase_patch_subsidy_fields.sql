-- 助成金管理項目の追加（既存データに影響なし・すべて NULL 可）
-- Supabase SQL Editor で Run

-- 業務改善：賃金・設備投資
ALTER TABLE business_improvement_applications
  ADD COLUMN IF NOT EXISTS min_wage_before int,
  ADD COLUMN IF NOT EXISTS min_wage_after int,
  ADD COLUMN IF NOT EXISTS wage_raise_date date,
  ADD COLUMN IF NOT EXISTS equipment_amount bigint;

COMMENT ON COLUMN business_improvement_applications.min_wage_before IS '引上げ前の事業場内最低賃金（円）';
COMMENT ON COLUMN business_improvement_applications.min_wage_after IS '引上げ後の事業場内最低賃金（円）';
COMMENT ON COLUMN business_improvement_applications.wage_raise_date IS '賃金引上げ日（6か月維持期限の起算）';
COMMENT ON COLUMN business_improvement_applications.equipment_amount IS '設備投資等の金額（円）';

-- 働き方改革：交付決定日
ALTER TABLE work_style_applications
  ADD COLUMN IF NOT EXISTS decision_date date;

COMMENT ON COLUMN work_style_applications.decision_date IS '交付決定日';

-- キャリアアップ：支給管理
ALTER TABLE career_up_applications
  ADD COLUMN IF NOT EXISTS subsidy_amount bigint,
  ADD COLUMN IF NOT EXISTS reception_number text;

COMMENT ON COLUMN career_up_applications.subsidy_amount IS '支給決定額（円）';
COMMENT ON COLUMN career_up_applications.reception_number IS '受付番号・管理番号';

-- 業務改善：令和8年度 交付申請期限（年度設定で変更可）
INSERT INTO program_deadlines
  (subsidy_type, deadline_key, label, deadline_date, fiscal_year_label, source_note)
VALUES
  ('biz', 'app_limit', '交付申請期限', '2026-11-30', '令和8年度',
   '令和8年度：9/1受付開始。地域別最低賃金発効日前日または11/30の早い方等—告示に合わせて更新')
ON CONFLICT (subsidy_type, deadline_key) DO NOTHING;
