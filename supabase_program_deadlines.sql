-- ============================================================
--  Supabase 追加：年度制度締切マスタ（program_deadlines）
--
--  厚生労働省の告示・延長発表後、このテーブルの日付を更新すると
--  アプリ全体の期限計算・表示に自動反映されます。
--  （アプリの「⚙️ 年度期限設定」からも編集可能）
--
--  使い方: SQL Editor に貼り付けて Run
-- ============================================================

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TABLE IF NOT EXISTS program_deadlines (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subsidy_type      text NOT NULL CHECK (subsidy_type IN ('biz','work','reskill')),
  deadline_key      text NOT NULL,
  label             text NOT NULL,
  deadline_date     date NOT NULL,
  fiscal_year_label text NOT NULL DEFAULT '令和8年度',
  source_note       text,
  source_url        text,
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (subsidy_type, deadline_key)
);

COMMENT ON TABLE program_deadlines IS '助成金の年度制度締切（厚労省告示に応じて更新）';

DROP TRIGGER IF EXISTS trg_program_deadlines_updated ON program_deadlines;
CREATE TRIGGER trg_program_deadlines_updated
  BEFORE UPDATE ON program_deadlines
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE program_deadlines DISABLE ROW LEVEL SECURITY;

-- 初期データ（令和8年度・既存アプリと同値）
INSERT INTO program_deadlines
  (subsidy_type, deadline_key, label, deadline_date, fiscal_year_label, source_note)
VALUES
  ('biz',     'comp_limit',   '事業完了期限',   '2027-01-31', '令和8年度', '業務改善助成金 令和8年度'),
  ('biz',     'sup_max',      '支給申請上限',   '2027-04-10', '令和8年度', '業務改善助成金 令和8年度'),
  ('work',    'app_limit',    '交付申請期限',   '2026-11-30', '令和8年度', '働き方改革推進支援助成金 令和8年度'),
  ('work',    'comp_limit',   '事業完了期限',   '2027-01-31', '令和8年度', '働き方改革推進支援助成金 令和8年度'),
  ('work',    'sup_max',      '支給申請上限',   '2027-02-05', '令和8年度', '働き方改革推進支援助成金 令和8年度'),
  ('reskill', 'program_end',  '制度終了',       '2027-03-31', '令和8年度', '人材開発支援助成金 事業展開等リスキリング支援コース')
ON CONFLICT (subsidy_type, deadline_key) DO NOTHING;

SELECT subsidy_type, deadline_key, label, deadline_date, fiscal_year_label, updated_at
FROM program_deadlines
ORDER BY subsidy_type, deadline_key;
