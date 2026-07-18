/* shared.js — オフィスキャンプ 共有データ層
 * スマホ(app.html)とPC(pc.html)で同じSupabaseバックエンド・同じクエリ・同じ計算を使うための単一の窓口。
 * 依存: window.OC_CONFIG (config.js) と window.supabase (supabase-js UMD) を先に読み込むこと。
 * UIは持たない。データの取得・更新・整形だけ。 */
(function () {
  const cfg = window.OC_CONFIG || {};
  const configured = !!cfg.SUPABASE_URL && !cfg.SUPABASE_URL.includes('YOUR-PROJECT');
  const OC = (window.OC = {
    cfg, configured, sb: null,
    me: null, meName: '', myRole: null, myDept: null, myDepts: [],
    impersonatingId: null, impersonatingUser: null,
    people: [], peopleById: {}, peopleDepts: {}, departments: [], vendors: [],
    projects: [], projOpts: [],
  });

  OC.init = function () {
    if (!configured) return false;
    OC.sb = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY);
    return true;
  };

  // ---- 認証 ----
  OC.session   = async () => (await OC.sb.auth.getSession()).data.session;
  OC.onAuth    = (cb) => OC.sb.auth.onAuthStateChange((_e, s) => cb(s));
  OC.signIn    = (email, password) => OC.sb.auth.signInWithPassword({ email, password });
  OC.signOut   = () => OC.sb.auth.signOut();
  OC.sendMagic = (email) => OC.sb.auth.signInWithOtp({ email, options: { emailRedirectTo: location.href } });
  OC.setPassword = (password) => OC.sb.auth.updateUser({ password });
  OC.createMember = async function (payload) {
    const { data: { session } } = await OC.sb.auth.getSession();
    if (!session?.access_token) throw new Error('ログイン状態を確認できません');
    const res = await fetch(`${cfg.SUPABASE_URL}/functions/v1/create-member`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${session.access_token}`,
      },
      body: JSON.stringify(payload),
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(body.error || 'メンバーを作成できませんでした');
    return body;
  };
  // 代理操作（ラッピング）方式に一本化したため、実ログイン切替用の adminLoginLink は廃止。
  OC.updateMember = async function (payload) {
    const { data: { session } } = await OC.sb.auth.getSession();
    if (!session?.access_token) throw new Error('ログイン状態を確認できません');
    const res = await fetch(`${cfg.SUPABASE_URL}/functions/v1/update-member`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${session.access_token}`,
      },
      body: JSON.stringify(payload),
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(body.error || 'メンバーを更新できませんでした');
    return body;
  };
  OC.deleteMember = async function (id) {
    const { data: { session } } = await OC.sb.auth.getSession();
    if (!session?.access_token) throw new Error('ログイン状態を確認できません');
    const res = await fetch(`${cfg.SUPABASE_URL}/functions/v1/delete-member`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${session.access_token}`,
      },
      body: JSON.stringify({ id }),
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(body.error || 'メンバーを削除できませんでした');
    return body;
  };
  OC.resetMemberPassword = async function (id) {
    const { data: { session } } = await OC.sb.auth.getSession();
    if (!session?.access_token) throw new Error('ログイン状態を確認できません');
    const res = await fetch(`${cfg.SUPABASE_URL}/functions/v1/reset-member-password`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${session.access_token}`,
      },
      body: JSON.stringify({ id }),
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(body.error || 'パスワードを初期化できませんでした');
    return body;
  };

  // ---- 整形ヘルパ ----
  OC.yen = (n) => '¥' + Number(n || 0).toLocaleString();
  // 万円表記。1万円未満は円表記へフォールバック（¥4,900が「¥0万」になる誤認防止）。
  // 端数のある万円は小数1桁まで残す（¥14,900 → ¥1.5万）。
  OC.man = (n) => {
    n = Number(n || 0);
    if (Math.abs(n) < 10000) return OC.yen(n);
    const v = Math.round(n / 1000) / 10;
    return '¥' + (Number.isInteger(v) ? v : v.toFixed(1)) + '万';
  };
  OC.deptName = (id) => (OC.departments.find((d) => d.id === id) || {}).name || '部門';
  OC.personName = (id) => { const p = OC.peopleById[id]; return p ? (p.name || p.email) : '—'; };
  OC.fmtDate = (d) => (d ? new Date(d.length <= 10 ? d + 'T00:00:00' : d).toLocaleDateString('ja-JP') : '—');
  OC.loadImpersonation = function () {
    let id = null;
    try { id = localStorage.getItem('oc_impersonating_user_id'); } catch (e) {}
    // 代理操作は実管理者のみ。非管理者の localStorage 残骸は無視する（多層防御）。
    OC.impersonatingId = (id && OC.peopleById[id] && OC.isActualAdmin()) ? id : null;
    OC.impersonatingUser = OC.impersonatingId ? OC.peopleById[OC.impersonatingId] : null;
    return OC.impersonatingUser;
  };
  OC.startImpersonation = function (id) {
    if (!OC.isActualAdmin()) throw new Error('代理操作は管理者のみ可能です');
    if (!OC.peopleById[id]) throw new Error('対象ユーザーが見つかりません');
    try { localStorage.setItem('oc_impersonating_user_id', id); } catch (e) {}
    OC.loadImpersonation();
  };
  OC.stopImpersonation = function () {
    try { localStorage.removeItem('oc_impersonating_user_id'); } catch (e) {}
    OC.impersonatingId = null;
    OC.impersonatingUser = null;
  };
  OC.effectiveUser = () => OC.impersonatingUser || OC.me;
  OC.effectiveUserId = () => (OC.effectiveUser() || {}).id;
  OC.effectiveRole = () => (OC.impersonatingUser ? OC.impersonatingUser.role : OC.myRole);
  OC.effectiveDepts = () => OC.impersonatingId
    ? (OC.peopleDepts[OC.impersonatingId] || [])
    : (OC.myDepts || []);
  OC.isActualAdmin = () => OC.myRole === '管理者';
  OC.isManager = () => OC.effectiveRole() === '経理' || OC.effectiveRole() === '管理者';
  OC.isAccounting = OC.isManager;

  // ---- 代理操作の鏡像スコープ ----
  // 代理操作は管理者セッションのまま動くため、DBのRLSは管理者基準（全件見える）。
  // 「対象ユーザーが自分で見たのと同じ範囲」に揃えるため、代理中かつ対象が
  // 経理/管理者でない時だけ、対象が見える案件ID集合をフロントで算出して絞る。
  // 集合は can_see_project（= メンバー or 所有者）と一致させる。
  OC._visKey = undefined; OC._visIds = null;
  OC._ensureVisible = async function () {
    const key = (OC.impersonatingId && !OC.isManager()) ? OC.impersonatingId : null;
    if (key === OC._visKey) return OC._visIds;       // null===null＝絞り込み無しもキャッシュ
    OC._visKey = key;
    if (!key) { OC._visIds = null; return null; }
    const uid = OC.effectiveUserId();
    const [{ data: owned }, { data: mem }, { data: ta }] = await Promise.all([
      OC.sb.from('projects').select('id').eq('owner_id', uid),
      OC.sb.from('project_members').select('project_id').eq('user_id', uid),
      OC.sb.from('task_assignees').select('task:task_id(project_id)').eq('user_id', uid),
    ]);
    const s = new Set();
    (owned || []).forEach((r) => s.add(r.id));
    (mem || []).forEach((r) => s.add(r.project_id));
    // タスク担当だけの案件も可視集合へ（自分のタスク＋案件名は見える。
    // 経理ビュー project_costs は can_see_project で別途締まるので金額は出ない）
    (ta || []).forEach((r) => { const pid = r.task && r.task.project_id; if (pid) s.add(pid); });
    OC._visIds = s;
    return s;
  };
  OC.projectVisible = (pid) => !OC._visIds || OC._visIds.has(pid);
  // 代理操作の切替時に呼ぶ：案件キャッシュと可視集合を破棄して再取得させる。
  OC.resetScope = function () { OC._visKey = undefined; OC._visIds = null; OC.projects = []; OC.projOpts = []; };

  // ---- ユーザー/マスタ ----
  OC.loadMe = async function () {
    const { data: { user } } = await OC.sb.auth.getUser();
    OC.me = user;
    // セッション失効/未ログイン時は user=null。以降の user.id で落とさない。
    if (!user) { OC.myRole = null; OC.myDept = null; OC.meName = ''; OC.myDepts = []; return null; }
    const { data, error } = await OC.sb.from('profiles').select('name,role,department_id').eq('id', user.id).single();
    if (error) console.error('[OC] loadMe: profiles 取得失敗', error);
    OC.myRole = data?.role || null;
    OC.myDept = data?.department_id || null;
    OC.meName = data?.name || user.email;
    return OC.me;
  };
  OC.loadPeople = async function () {
    const { data, error } = await OC.sb.from('profiles').select('id,name,email,role,department_id').order('name');
    if (error) console.error('[OC] loadPeople 失敗', error);
    OC.people = data || [];
    OC.peopleById = {}; OC.people.forEach((p) => (OC.peopleById[p.id] = p));
    const { data: pd } = await OC.sb.from('profile_departments').select('profile_id,department_id');
    OC.peopleDepts = {};
    (pd || []).forEach((r) => { (OC.peopleDepts[r.profile_id] = OC.peopleDepts[r.profile_id] || []).push(r.department_id); });
    OC.people.forEach((p) => { if (p.department_id) { const a = (OC.peopleDepts[p.id] = OC.peopleDepts[p.id] || []); if (!a.includes(p.department_id)) a.push(p.department_id); } });
    if (OC.me) OC.myDepts = OC.peopleDepts[OC.me.id] || (OC.myDept ? [OC.myDept] : []);
    OC.loadImpersonation();
    return OC.people;
  };
  OC.loadDepartments = async function () {
    const { data, error } = await OC.sb.from('departments').select('id,name').order('name');
    if (error) console.error('[OC] loadDepartments 失敗', error);
    OC.departments = data || []; return OC.departments;
  };
  OC.loadVendors = async function () {
    const { data, error } = await OC.sb.from('vendors').select('id,name,kind').order('name');
    if (error) console.error('[OC] loadVendors 失敗', error);
    OC.vendors = data || []; return OC.vendors;
  };

  // ---- 案件 ----
  OC.loadProjects = async function () {
    await OC._ensureVisible();
    const [{ data: costs, error: e1 }, { data: meta, error: e2 }] = await Promise.all([
      OC.sb.from('project_costs').select('*').order('profit', { ascending: false }),
      OC.sb.from('projects').select('id,status,client,delivery_date,start_date,leader_id'),
    ]);
    if (e1 || e2) throw (e1 || e2);
    const m = Object.fromEntries((meta || []).map((x) => [x.id, x]));
    let rows = (costs || []).map((p) => ({ ...p, ...(m[p.id] || {}) }));
    if (OC._visIds) rows = rows.filter((p) => OC._visIds.has(p.id));
    OC.projects = rows;
    return OC.projects;
  };
  OC.projectOptions = async function () {
    await OC._ensureVisible();
    const { data } = await OC.sb.from('projects').select('id,name').neq('status', '失注').order('created_at', { ascending: false });
    let rows = data || [];
    if (OC._visIds) rows = rows.filter((p) => OC._visIds.has(p.id));
    OC.projOpts = rows; return OC.projOpts;
  };
  OC.loadProjectDetail = async function (id) {
    const [{ data: p }, { data: pmeta }, { data: exps }, { data: ords }, { data: members }, { data: tasks }] = await Promise.all([
      OC.sb.from('project_costs').select('*').eq('id', id).single(),
      OC.sb.from('projects').select('status,delivery_date,start_date,client,leader_id,note').eq('id', id).single(),
      OC.sb.from('expenses').select('amount,note,spent_at,status,kind,receipt_url,author:user_id(name,email),vendor:vendor_id(name)').eq('project_id', id).order('spent_at', { ascending: false }),
      OC.sb.from('orders').select('id,kind,amount,title,status,from_user,to_user_id,to_dept_id,vendor:vendor_id(name)').eq('project_id', id).order('created_at', { ascending: false }),
      OC.sb.from('project_members').select('user_id').eq('project_id', id),
      OC.sb.from('tasks').select('id,title,status,start_date,end_date,progress,leader_id,parent_task_id,task_assignees(user_id)').eq('project_id', id).order('start_date', { nullsFirst: false }),
    ]);
    return { p: { ...(p || {}), ...(pmeta || {}) }, expenses: exps || [], orders: ords || [], members: members || [], tasks: tasks || [] };
  };
  OC.addProject = (payload) => OC.sb.from('projects').insert(payload);
  OC.updateProject = (id, patch) => OC.sb.from('projects').update(patch).eq('id', id);
  // 案件メンバーの明示追加/削除（タスク担当の自動昇格は廃止＝v14。メンバーは全タスクを見られる）
  OC.addProjectMember = (project_id, user_id) => OC.sb.from('project_members').insert({ project_id, user_id });
  OC.removeProjectMember = (project_id, user_id) => OC.sb.from('project_members').delete().match({ project_id, user_id });
  // 案件削除（P0-B）。RLS projects_delete = owner or is_manager（db/schema.sql:153）。
  // expenses.project_id が on delete restrict のため、経費が残る案件は error.code==='23503' を呼び出し側で文言変換する。
  OC.deleteProject = (id) => OC.sb.from('projects').delete().eq('id', id);

  // ---- 経費 ----
  OC.loadExpenses = async function (limit) {
    await OC._ensureVisible();
    let q = OC.sb.from('expenses')
      .select('id,amount,note,spent_at,status,kind,project_id,user_id,receipt_url,proj:project_id(name,code),author:user_id(name,email),vendor:vendor_id(name)')
      .order('spent_at', { ascending: false });
    if (limit && !OC._visIds) q = q.limit(limit);
    const { data, error } = await q;
    if (error) throw error;
    let rows = data || [];
    if (OC._visIds) { rows = rows.filter((e) => OC._visIds.has(e.project_id)); if (limit) rows = rows.slice(0, limit); }
    return rows;
  };
  OC.addExpense = (project_id, amount, note) => OC.sb.from('expenses').insert({ project_id, amount, note, user_id: OC.effectiveUserId() });
  // 経費の編集・削除（P0-B）。RLS expenses_update/expenses_delete = 本人 or is_manager（db/schema.sql:163,167）。
  OC.updateExpense = (id, patch) => OC.sb.from('expenses').update(patch).eq('id', id);
  OC.deleteExpense = (id) => OC.sb.from('expenses').delete().eq('id', id);

  // ---- タスク ----
  OC.updateTask = (id, patch) => OC.sb.from('tasks').update(patch).eq('id', id);
  OC.addTask = (payload) => OC.sb.from('tasks').insert({ created_by: OC.effectiveUserId(), ...payload }).select().single();
  OC.assignTask = (task_id, user_id) => OC.sb.from('task_assignees').insert({ task_id, user_id });
  OC.unassignTask = (task_id, user_id) => OC.sb.from('task_assignees').delete().match({ task_id, user_id });
  // タスク削除（P0-B）。RLS tasks_cud for all（db/v2.sql:193）。parent_task_id は on delete cascade（db/v8.sql:2）なのでサブタスクは自動削除される。
  OC.deleteTask = (id) => OC.sb.from('tasks').delete().eq('id', id);
  OC.loadAllTasks = async function () {
    await OC._ensureVisible();
    if (OC._visIds && OC._visIds.size === 0) return [];
    // 取得は created_at 降順＋limit(2000)（start_date昇順のままだと日付未設定＝NULLS LASTで
    // 新規タスクから先に切り捨てられるため）。表示順は取得後に start_date 昇順へ並べ替える。
    let q = OC.sb.from('tasks')
      .select('id,project_id,title,start_date,end_date,status,progress,leader_id,parent_task_id,task_assignees(user_id)')
      .order('created_at', { ascending: false })
      .limit(2000);
    if (OC._visIds) q = q.in('project_id', [...OC._visIds]);
    const { data, error } = await q;
    if (error) throw error;
    let rows = (data || []).sort((a, b) => {
      if (!a.start_date && !b.start_date) return 0;
      if (!a.start_date) return 1;
      if (!b.start_date) return -1;
      return a.start_date < b.start_date ? -1 : a.start_date > b.start_date ? 1 : 0;
    });
    // 案件名/日付は project_task_labels 経由（メンバー外のタスク担当者にも安全に返る。金額/客先は含まない・v17）。
    // projects への直埋め込みだと、案件メンバーでない担当者には行ごとRLSでnullになり案件名が消える。
    const projIds = [...new Set(rows.map((t) => t.project_id).filter(Boolean))];
    if (projIds.length) {
      const { data: labels } = await OC.sb.from('project_task_labels')
        .select('id,name,code,status,start_date,end_date,delivery_date')
        .in('id', projIds);
      const byId = {};
      (labels || []).forEach((p) => (byId[p.id] = p));
      rows.forEach((t) => (t.proj = byId[t.project_id] || null));
    }
    return rows;
  };

  // ---- 変更履歴（audit_log、M-9） ----
  // app.html の diffHTML/logLabel を共有層へ移設した版。pc.html の案件詳細で使用
  //（app.html は shared.js 未読込のためローカル実装を併存＝M-7の段階移行で統合予定）。
  OC.esc = (s) => String(s == null ? '' : s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  OC.loadAuditLog = async function (project_id, limit) {
    const { data, error } = await OC.sb.from('audit_log')
      .select('table_name,action,actor_id,summary,diff,created_at')
      .eq('project_id', project_id).order('created_at', { ascending: false }).limit(limit || 40);
    if (error) { console.error('[OC] loadAuditLog 失敗', error); return []; }
    return data || [];
  };
  OC.FIELD_JP = { name: '案件名', title: 'タイトル', amount: '金額', status: '状態', note: 'メモ',
    start_date: '開始日', end_date: '終了日', delivery_date: '納品日', client: '受注元',
    progress: '進捗', leader_id: 'リーダー', kind: '種別', vendor_id: '外注先',
    to_dept_id: '内注先', spent_at: '日付', profit: '粗利', parent_task_id: '親タスク' };
  OC.fieldLabel = (k) => OC.FIELD_JP[k] || k;
  // 値の表示整形。自由入力値（名前・メモ等）が混ざるため必ずエスケープして返す
  OC.fmtVal = function (k, v) {
    if (v === null || v === undefined || v === '') return '空';
    if (k === 'leader_id' || k === 'to_user_id' || k === 'user_id' || k === 'from_user') return OC.esc(OC.personName(v));
    if (k === 'to_dept_id') return OC.esc(OC.deptName(v));
    if (k === 'amount') return OC.yen(v);
    return OC.esc(String(v));
  };
  OC.diffHTML = function (l) {
    const o = l.diff?.old || {}, n = l.diff?.new || {};
    const skip = new Set(['id', 'created_at', 'updated_at', 'owner_id', 'receipt_url', 'user_id', 'from_user']);
    const keys = [...new Set([...Object.keys(o), ...Object.keys(n)])].filter((k) => !skip.has(k));
    const changed = keys.filter((k) => JSON.stringify(o[k]) !== JSON.stringify(n[k]));
    if (l.action === 'INSERT') {
      const list = keys.filter((k) => n[k] !== null && n[k] !== '').map((k) => `<div class="dl"><span class="dk">${OC.fieldLabel(k)}</span><span class="dn">${OC.fmtVal(k, n[k])}</span></div>`).join('');
      return list || '<div class="muted">—</div>';
    }
    if (l.action === 'DELETE') {
      const list = keys.filter((k) => o[k] !== null && o[k] !== '').map((k) => `<div class="dl"><span class="dk">${OC.fieldLabel(k)}</span><span class="do">${OC.fmtVal(k, o[k])}</span></div>`).join('');
      return list || '<div class="muted">—</div>';
    }
    if (!changed.length) return '<div class="muted">変更なし</div>';
    return changed.map((k) => `<div class="dl"><span class="dk">${OC.fieldLabel(k)}</span>
      <span class="do">${OC.fmtVal(k, o[k])}</span> → <span class="dn">${OC.fmtVal(k, n[k])}</span></div>`).join('');
  };
  OC.logLabel = function (l) {
    const t = { projects: '案件', expenses: '経費', tasks: 'タスク', orders: '発注' }[l.table_name] || OC.esc(l.table_name);
    const n = l.diff?.new || l.diff?.old || {};
    if (l.table_name === 'expenses') return `${t}：${OC.esc(n.note || '（メモなし）')} ${n.amount ? OC.yen(n.amount) : ''}`;
    if (l.table_name === 'tasks') return `${t}：${OC.esc(n.title)}`;
    if (l.table_name === 'orders') return `${t}：${OC.esc(n.title)} ${n.amount ? OC.yen(n.amount) : ''}`;
    if (l.table_name === 'projects') return `${t}：${OC.esc(n.name)}`;
    return t;
  };

  // ---- 発注 ----
  OC.addOrder = (payload) => OC.sb.from('orders').insert({ from_user: OC.effectiveUserId(), ...payload });
  // 発注削除（P0-B）。RLS orders_delete = from_user or is_manager（db/v3.sql:40）。
  OC.deleteOrder = (id) => OC.sb.from('orders').delete().eq('id', id);
  // 発注の金額・依頼内容のその場編集（P3）。RLS orders_update = from_user/to_user_id/is_manager（db/v3.sql）。
  OC.updateOrder = (id, patch) => OC.sb.from('orders').update(patch).eq('id', id);
  OC.loadOrders = async function () {
    const sel = 'id,project_id,kind,amount,title,status,from_user,to_user_id,to_dept_id,created_at,vendor:vendor_id(name),proj:project_id(name)';
    const effectiveId = OC.effectiveUserId();
    // 実効ユーザーIDが未確定（未ログイン等）なら不正な .or(...eq.undefined) を投げず空で返す。
    if (!effectiveId) return { out: [], inbound: [] };
    const deptList = OC.effectiveDepts();
    const inFilter = ['to_user_id.eq.' + effectiveId].concat(deptList.map((d) => 'to_dept_id.eq.' + d)).join(',');
    // 取消・完了も含めて永久に積み上がるのを防ぐため直近300件に制限（P3）。
    const [{ data: out }, { data: inb }] = await Promise.all([
      OC.sb.from('orders').select(sel).eq('from_user', effectiveId).order('created_at', { ascending: false }).limit(300),
      OC.sb.from('orders').select(sel).or(inFilter).order('created_at', { ascending: false }).limit(300),
    ]);
    return { out: out || [], inbound: inb || [] };
  };
})();
