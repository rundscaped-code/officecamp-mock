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

  // 自分自身は削除できない（ログイン不能になっての締め出し防止）
  if (id === authData.user.id) {
    return json({ error: '自分自身は削除できません' }, 400);
  }

  const { data: target, error: targetError } = await adminClient
    .from('profiles')
    .select('id, name, email, role')
    .eq('id', id)
    .single();
  if (targetError || !target) return json({ error: '対象ユーザーが見つかりません' }, 404);

  // 最後の管理者を消して全員が締め出されるのを防ぐ
  if (target.role === '管理者') {
    const { count, error: countError } = await adminClient
      .from('profiles')
      .select('id', { count: 'exact', head: true })
      .eq('role', '管理者');
    if (countError) return json({ error: countError.message }, 500);
    if ((count ?? 0) <= 1) {
      return json({ error: '最後の管理者は削除できません（先に別の管理者を作成してください）' }, 400);
    }
  }

  // ログインは必ず即時無効化する
  const { error: authDeleteError } = await adminClient.auth.admin.deleteUser(id);
  if (authDeleteError && !/not.?found/i.test(authDeleteError.message || '')) {
    return json({ error: 'ログイン無効化に失敗しました: ' + authDeleteError.message }, 500);
  }

  // profiles 行の削除を試みる。経費/タスク/発注/案件の履歴が残っている場合は
  // 外部キー制約(NO ACTION)で失敗する。これは想定内なので、履歴保持のまま
  // 「ログインだけ無効化された」状態として正常応答する。
  const { error: profileError } = await adminClient.from('profiles').delete().eq('id', id);
  const historyKept = !!profileError;

  return json({
    ok: true,
    id,
    name: target.name,
    authDeleted: true,
    profileDeleted: !historyKept,
    historyKept,
  });
});
