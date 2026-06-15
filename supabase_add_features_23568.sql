-- ============================================================
--  Supabase 追加：機能 2・3・5・6・8
--  2: 社内担当者  5: ログイン（ID+パスワード）  6: 変更履歴  8: 書類チェックリスト
--  （3: 今週期限ビュー は index.html のみ）
--
--  SQL Editor で Run → ブラウザ再読み込み
--  初期管理者のみ（本番では必ずパスワードを変更してください）:
--    admin / Admin1234
--  追加アカウントは管理者ログイン後「アカウント管理」から作成
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

ALTER TABLE companies ADD COLUMN IF NOT EXISTS internal_assignee text;
COMMENT ON COLUMN companies.internal_assignee IS '社内担当者（事務所側）';

-- 5. 担当者ログイン用（ID + パスワード）
CREATE TABLE IF NOT EXISTS staff_members (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name           text NOT NULL,
  login_id       text NOT NULL UNIQUE,
  password_hash  text NOT NULL,
  role           text NOT NULL DEFAULT 'staff' CHECK (role IN ('admin', 'staff')),
  is_active      boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE staff_members ADD COLUMN IF NOT EXISTS role text NOT NULL DEFAULT 'staff';
ALTER TABLE staff_members DROP CONSTRAINT IF EXISTS staff_members_role_check;
ALTER TABLE staff_members ADD CONSTRAINT staff_members_role_check CHECK (role IN ('admin', 'staff'));

COMMENT ON TABLE staff_members IS '操作ログイン用担当者（password_hash は bcrypt）';
COMMENT ON COLUMN staff_members.login_id IS 'ログインID';
COMMENT ON COLUMN staff_members.role IS 'admin=管理者（アカウント作成可） / staff=一般';

-- admin 以外を削除し、管理者のみ残す
DELETE FROM staff_members WHERE login_id <> 'admin';

INSERT INTO staff_members (name, login_id, password_hash, role) VALUES
  ('管理者', 'admin', extensions.crypt('Admin1234', extensions.gen_salt('bf')), 'admin')
ON CONFLICT (login_id) DO UPDATE SET
  name = EXCLUDED.name,
  password_hash = EXCLUDED.password_hash,
  role = 'admin',
  is_active = true;

-- 管理者認証ヘルパ（内部用）
CREATE OR REPLACE FUNCTION _verify_admin(p_admin_login_id text, p_admin_password text)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, extensions
AS $$
  SELECT EXISTS (
    SELECT 1 FROM staff_members sm
    WHERE sm.login_id = p_admin_login_id
      AND sm.role = 'admin'
      AND sm.is_active = true
      AND sm.password_hash = extensions.crypt(p_admin_password, sm.password_hash)
  );
$$;

DROP FUNCTION IF EXISTS staff_login(text, text);
CREATE FUNCTION staff_login(p_login_id text, p_password text)
RETURNS TABLE(id uuid, name text, login_id text, role text)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, extensions
AS $$
  SELECT sm.id, sm.name, sm.login_id, sm.role
  FROM staff_members sm
  WHERE sm.login_id = p_login_id
    AND sm.is_active = true
    AND sm.password_hash = extensions.crypt(p_password, sm.password_hash);
$$;

GRANT EXECUTE ON FUNCTION staff_login(text, text) TO anon, authenticated;

DROP FUNCTION IF EXISTS staff_list_accounts(text, text);
CREATE FUNCTION staff_list_accounts(p_admin_login_id text, p_admin_password text)
RETURNS TABLE(id uuid, name text, login_id text, role text, is_active boolean, created_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, extensions
AS $$
BEGIN
  IF NOT _verify_admin(p_admin_login_id, p_admin_password) THEN
    RAISE EXCEPTION '権限がありません';
  END IF;
  RETURN QUERY
    SELECT sm.id, sm.name, sm.login_id, sm.role, sm.is_active, sm.created_at
    FROM staff_members sm
    ORDER BY sm.role DESC, sm.login_id;
END;
$$;

GRANT EXECUTE ON FUNCTION staff_list_accounts(text, text) TO anon, authenticated;

DROP FUNCTION IF EXISTS staff_create_account(text, text, text, text, text);
DROP FUNCTION IF EXISTS staff_create_account(text, text, text, text, text, text);
CREATE FUNCTION staff_create_account(
  p_admin_login_id text,
  p_admin_password text,
  p_name text,
  p_new_login_id text,
  p_new_password text,
  p_role text DEFAULT 'staff'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  new_id uuid;
  lid text := lower(trim(p_new_login_id));
  r text := lower(trim(coalesce(p_role, 'staff')));
BEGIN
  IF NOT _verify_admin(p_admin_login_id, p_admin_password) THEN
    RAISE EXCEPTION '権限がありません';
  END IF;
  IF r NOT IN ('admin', 'staff') THEN
    RAISE EXCEPTION '権限の種別が不正です';
  END IF;
  IF length(lid) < 3 THEN
    RAISE EXCEPTION 'ログインIDは3文字以上にしてください';
  END IF;
  IF length(p_new_password) < 8 THEN
    RAISE EXCEPTION 'パスワードは8文字以上にしてください';
  END IF;
  IF lid = 'admin' THEN
    RAISE EXCEPTION 'このログインIDは使用できません';
  END IF;
  INSERT INTO staff_members (name, login_id, password_hash, role)
  VALUES (trim(p_name), lid, extensions.crypt(p_new_password, extensions.gen_salt('bf')), r)
  RETURNING staff_members.id INTO new_id;
  RETURN new_id;
END;
$$;

GRANT EXECUTE ON FUNCTION staff_create_account(text, text, text, text, text, text) TO anon, authenticated;

DROP FUNCTION IF EXISTS staff_set_account_role(text, text, text, text);
CREATE FUNCTION staff_set_account_role(
  p_admin_login_id text,
  p_admin_password text,
  p_target_login_id text,
  p_role text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  lid text := lower(trim(p_target_login_id));
  r text := lower(trim(p_role));
BEGIN
  IF NOT _verify_admin(p_admin_login_id, p_admin_password) THEN
    RAISE EXCEPTION '権限がありません';
  END IF;
  IF r NOT IN ('admin', 'staff') THEN
    RAISE EXCEPTION '権限の種別が不正です';
  END IF;
  IF lid = 'admin' THEN
    RAISE EXCEPTION '初期管理者の権限は変更できません';
  END IF;
  UPDATE staff_members SET role = r WHERE login_id = lid;
  RETURN FOUND;
END;
$$;

GRANT EXECUTE ON FUNCTION staff_set_account_role(text, text, text, text) TO anon, authenticated;

DROP FUNCTION IF EXISTS staff_delete_account(text, text, text);
CREATE FUNCTION staff_delete_account(
  p_admin_login_id text,
  p_admin_password text,
  p_target_login_id text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF NOT _verify_admin(p_admin_login_id, p_admin_password) THEN
    RAISE EXCEPTION '権限がありません';
  END IF;
  IF lower(trim(p_target_login_id)) = 'admin' THEN
    RAISE EXCEPTION '初期管理者（admin）は削除できません';
  END IF;
  DELETE FROM staff_members
  WHERE login_id = lower(trim(p_target_login_id));
  RETURN FOUND;
END;
$$;

GRANT EXECUTE ON FUNCTION staff_delete_account(text, text, text) TO anon, authenticated;

-- 6. 変更履歴
CREATE TABLE IF NOT EXISTS audit_logs (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id  uuid REFERENCES companies(id) ON DELETE SET NULL,
  table_name  text NOT NULL,
  record_id   uuid,
  action      text NOT NULL CHECK (action IN ('insert','update','delete')),
  summary     text NOT NULL,
  changed_by  text,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_audit_company ON audit_logs(company_id);
CREATE INDEX IF NOT EXISTS idx_audit_created ON audit_logs(created_at DESC);

-- 8. 書類チェックリスト
CREATE TABLE IF NOT EXISTS document_checklists (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id      uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  subsidy_type    text NOT NULL,
  application_id  uuid NOT NULL,
  doc_key         text NOT NULL,
  doc_label       text NOT NULL,
  is_checked      boolean NOT NULL DEFAULT false,
  checked_date    date,
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (subsidy_type, application_id, doc_key)
);
CREATE INDEX IF NOT EXISTS idx_doccheck_company ON document_checklists(company_id);

-- RLS + ポリシー
ALTER TABLE staff_members DISABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs DISABLE ROW LEVEL SECURITY;
ALTER TABLE document_checklists DISABLE ROW LEVEL SECURITY;

DO $$ DECLARE pol record; BEGIN
  FOR pol IN SELECT policyname, tablename FROM pg_policies
    WHERE schemaname = 'public' AND tablename IN ('staff_members','audit_logs','document_checklists')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', pol.policyname, pol.tablename);
  END LOOP;
END $$;

ALTER TABLE staff_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE document_checklists ENABLE ROW LEVEL SECURITY;

CREATE POLICY "staff_anon_deny" ON staff_members FOR ALL TO anon USING (false) WITH CHECK (false);
CREATE POLICY "staff_auth_all" ON staff_members FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "audit_anon_all" ON audit_logs FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY "doccheck_anon_all" ON document_checklists FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY "audit_auth_all" ON audit_logs FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "doccheck_auth_all" ON document_checklists FOR ALL TO authenticated USING (true) WITH CHECK (true);

SELECT 'staff_members' AS tbl, COUNT(*) AS cnt FROM staff_members
UNION ALL SELECT 'audit_logs', COUNT(*) FROM audit_logs
UNION ALL SELECT 'document_checklists', COUNT(*) FROM document_checklists;
