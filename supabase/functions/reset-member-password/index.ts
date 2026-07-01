import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

// pc.html の genPassword() と同系統（紛らわしい文字(0/O/1/I/l)を避けた読み上げやすいパスワード）
function genPassword(): string {
  const chars = 'ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
  const bytes = new Uint8Array(12);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => chars[b % chars.length]).join('');
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

  const body = await req.json().catch(() => null) as { id?: string } | null;
  const id = (body?.id || '').trim();
  if (!id) return json({ error: '対象ユーザーが指定されていません' }, 400);

  const { data: target, error: targetError } = await adminClient
    .from('profiles')
    .select('id, name, email')
    .eq('id', id)
    .single();
  if (targetError || !target) return json({ error: '対象ユーザーが見つかりません' }, 404);

  const password = genPassword();
  const { error: updateError } = await adminClient.auth.admin.updateUserById(id, { password });
  if (updateError) return json({ error: 'パスワード初期化に失敗しました: ' + updateError.message }, 500);

  return json({ ok: true, id, name: target.name, email: target.email, password });
});
