-- パッチ: 作成時に管理者権限を付与 + 既存アカウントの権限変更
-- （supabase_add_features_23568.sql 実行済みの場合はこのファイルだけ Run 可）

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

CREATE OR REPLACE FUNCTION staff_delete_account(
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
