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

  const body = await req.json().catch(() => null) as {
    target_user_id?: string;
    redirect_to?: string;
  } | null;
  const targetUserId = (body?.target_user_id || '').trim();
  if (!targetUserId) return json({ error: '対象ユーザーが指定されていません' }, 400);
  if (targetUserId === authData.user.id) return json({ error: '自分自身への切り替えは不要です' }, 400);

  const { data: target, error: targetError } = await adminClient
    .from('profiles')
    .select('email,name')
    .eq('id', targetUserId)
    .single();
  if (targetError || !target?.email) return json({ error: '対象ユーザーが見つかりません' }, 404);

  const fallbackRedirect = 'https://rundscaped-code.github.io/officecamp-mock/pc.html';
  const requestedRedirect = body?.redirect_to || fallbackRedirect;
  const redirectTo = requestedRedirect.startsWith('https://rundscaped-code.github.io/officecamp-mock/')
    ? requestedRedirect
    : fallbackRedirect;

  const { data: linkData, error: linkError } = await adminClient.auth.admin.generateLink({
    type: 'magiclink',
    email: target.email,
    options: { redirectTo },
  });
  const actionLink = linkData?.properties?.action_link;
  if (linkError || !actionLink) {
    return json({ error: linkError?.message || 'ログインリンクを発行できませんでした' }, 500);
  }

  return json({ ok: true, action_link: actionLink, email: target.email, name: target.name || target.email });
});
