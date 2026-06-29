-- v11: 権限ロールを「管理者 / 経理 / メンバー」に整理
-- 所属（建築/デザイン/SE等）は departments / profile_departments 側で管理する。

alter type public.user_role add value if not exists 'メンバー';

