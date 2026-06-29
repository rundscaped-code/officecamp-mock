import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const roles = new Set(['建築', 'デザイン', 'SE', '経理', '管理者']);

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const serviceRoleKey = Deno.env.get('OFFICECAMP_SERVICE_ROLE_KEY') || Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return json({ error: 'Function environment is not configured' }, 500);
  }

  const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
  if (!token) return json({ error: 'ログインが必要です' }, 401);

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
  const adminClient = createClient(supabaseUrl, serviceRoleKey);

  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData.user) return json({ error: 'ログイン状態を確認できません' }, 401);

  const { data: actor, error: actorError } = await userClient
    .from('profiles')
    .select('role')
    .eq('id', authData.user.id)
    .single();
  if (actorError || actor?.role !== '管理者') {
    return json({ error: '管理者のみ実行できます' }, 403);
  }

  const body = await req.json().catch(() => null) as {
    name?: string;
    email?: string;
    password?: string;
    role?: string;
    department_ids?: string[];
  } | null;
  const name = (body?.name || '').trim();
  const email = (body?.email || '').trim().toLowerCase();
  const password = body?.password || '';
  const role = body?.role || 'SE';
  const departmentIds = Array.from(new Set(body?.department_ids || [])).filter(Boolean).slice(0, 3);

  if (!name) return json({ error: '名前を入力してください' }, 400);
  if (!email || !email.includes('@')) return json({ error: 'メールを入力してください' }, 400);
  if (!password || password.length < 6) return json({ error: 'パスワードは6文字以上にしてください' }, 400);
  if (!roles.has(role)) return json({ error: 'ロールが不正です' }, 400);
  if ((body?.department_ids || []).length > 3) return json({ error: '所属部署は最大3つまでです' }, 400);

  const { data: created, error: createError } = await adminClient.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { name },
  });
  if (createError || !created.user) {
    const msg = createError?.message || 'ユーザーを作成できませんでした';
    return json({ error: msg.includes('already') ? 'このメールは既に登録されています' : msg }, 400);
  }

  const userId = created.user.id;
  const { error: profileError } = await adminClient.from('profiles').upsert({
    id: userId,
    name,
    email,
    role,
    department_id: departmentIds[0] || null,
  });
  if (profileError) return json({ error: profileError.message }, 500);

  await adminClient.from('profile_departments').delete().eq('profile_id', userId);
  if (departmentIds.length) {
    const { error: deptError } = await adminClient.from('profile_departments').insert(
      departmentIds.map((department_id) => ({ profile_id: userId, department_id })),
    );
    if (deptError) return json({ error: deptError.message }, 500);
  }

  return json({ ok: true, id: userId, email, name, role, department_ids: departmentIds });
});
