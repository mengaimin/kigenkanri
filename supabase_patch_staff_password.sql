-- パッチ: パスワード変更（本人・管理者）
-- supabase_add_features_23568.sql 実行済みの場合はこのファイルだけ Run 可

DROP FUNCTION IF EXISTS staff_change_own_password(text, text, text);
CREATE FUNCTION staff_change_own_password(
  p_login_id text,
  p_current_password text,
  p_new_password text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  lid text := lower(trim(p_login_id));
BEGIN
  IF length(p_new_password) < 8 THEN
    RAISE EXCEPTION '新しいパスワードは8文字以上にしてください';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM staff_members sm
    WHERE sm.login_id = lid
      AND sm.is_active = true
      AND sm.password_hash = extensions.crypt(p_current_password, sm.password_hash)
  ) THEN
    RAISE EXCEPTION '現在のパスワードが正しくありません';
  END IF;
  UPDATE staff_members
  SET password_hash = extensions.crypt(p_new_password, extensions.gen_salt('bf'))
  WHERE login_id = lid AND is_active = true;
  RETURN FOUND;
END;
$$;

GRANT EXECUTE ON FUNCTION staff_change_own_password(text, text, text) TO anon, authenticated;

DROP FUNCTION IF EXISTS staff_admin_reset_password(text, text, text, text);
CREATE FUNCTION staff_admin_reset_password(
  p_admin_login_id text,
  p_admin_password text,
  p_target_login_id text,
  p_new_password text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  lid text := lower(trim(p_target_login_id));
BEGIN
  IF NOT _verify_admin(p_admin_login_id, p_admin_password) THEN
    RAISE EXCEPTION '権限がありません';
  END IF;
  IF length(p_new_password) < 8 THEN
    RAISE EXCEPTION '新しいパスワードは8文字以上にしてください';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM staff_members WHERE login_id = lid AND is_active = true) THEN
    RAISE EXCEPTION '対象アカウントが見つかりません';
  END IF;
  UPDATE staff_members
  SET password_hash = extensions.crypt(p_new_password, extensions.gen_salt('bf'))
  WHERE login_id = lid AND is_active = true;
  RETURN FOUND;
END;
$$;

GRANT EXECUTE ON FUNCTION staff_admin_reset_password(text, text, text, text) TO anon, authenticated;
