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

  // ---- 整形ヘルパ ----
  OC.yen = (n) => '¥' + Number(n || 0).toLocaleString();
  OC.man = (n) => '¥' + Math.round(Number(n || 0) / 10000) + '万';
  OC.deptName = (id) => (OC.departments.find((d) => d.id === id) || {}).name || '部門';
  OC.personName = (id) => { const p = OC.peopleById[id]; return p ? (p.name || p.email) : '—'; };
  OC.fmtDate = (d) => (d ? new Date(d.length <= 10 ? d + 'T00:00:00' : d).toLocaleDateString('ja-JP') : '—');
  OC.isManager = () => OC.myRole === '経理' || OC.myRole === '管理者';
  OC.isAccounting = OC.isManager;

  // ---- ユーザー/マスタ ----
  OC.loadMe = async function () {
    const { data: { user } } = await OC.sb.auth.getUser();
    OC.me = user;
    const { data } = await OC.sb.from('profiles').select('name,role,department_id').eq('id', user.id).single();
    OC.myRole = data?.role || null;
    OC.myDept = data?.department_id || null;
    OC.meName = data?.name || user.email;
    return OC.me;
  };
  OC.loadPeople = async function () {
    const { data } = await OC.sb.from('profiles').select('id,name,email,role,department_id').order('name');
    OC.people = data || [];
    OC.peopleById = {}; OC.people.forEach((p) => (OC.peopleById[p.id] = p));
    const { data: pd } = await OC.sb.from('profile_departments').select('profile_id,department_id');
    OC.peopleDepts = {};
    (pd || []).forEach((r) => { (OC.peopleDepts[r.profile_id] = OC.peopleDepts[r.profile_id] || []).push(r.department_id); });
    OC.people.forEach((p) => { if (p.department_id) { const a = (OC.peopleDepts[p.id] = OC.peopleDepts[p.id] || []); if (!a.includes(p.department_id)) a.push(p.department_id); } });
    if (OC.me) OC.myDepts = OC.peopleDepts[OC.me.id] || (OC.myDept ? [OC.myDept] : []);
    return OC.people;
  };
  OC.loadDepartments = async function () {
    const { data } = await OC.sb.from('departments').select('id,name').order('name');
    OC.departments = data || []; return OC.departments;
  };
  OC.loadVendors = async function () {
    const { data } = await OC.sb.from('vendors').select('id,name,kind').order('name');
    OC.vendors = data || []; return OC.vendors;
  };

  // ---- 案件 ----
  OC.loadProjects = async function () {
    const [{ data: costs }, { data: meta }] = await Promise.all([
      OC.sb.from('project_costs').select('*').order('profit', { ascending: false }),
      OC.sb.from('projects').select('id,status,client,delivery_date,start_date,leader_id'),
    ]);
    const m = Object.fromEntries((meta || []).map((x) => [x.id, x]));
    OC.projects = (costs || []).map((p) => ({ ...p, ...(m[p.id] || {}) }));
    return OC.projects;
  };
  OC.projectOptions = async function () {
    const { data } = await OC.sb.from('projects').select('id,name').neq('status', '失注').order('created_at', { ascending: false });
    OC.projOpts = data || []; return OC.projOpts;
  };
  OC.loadProjectDetail = async function (id) {
    const [{ data: p }, { data: pmeta }, { data: exps }, { data: ords }, { data: members }] = await Promise.all([
      OC.sb.from('project_costs').select('*').eq('id', id).single(),
      OC.sb.from('projects').select('status,delivery_date,start_date,client,leader_id,note').eq('id', id).single(),
      OC.sb.from('expenses').select('amount,note,spent_at,status,kind,author:user_id(name,email),vendor:vendor_id(name)').eq('project_id', id).order('spent_at', { ascending: false }),
      OC.sb.from('orders').select('id,kind,amount,title,status,from_user,to_user_id,to_dept_id,vendor:vendor_id(name)').eq('project_id', id).order('created_at', { ascending: false }),
      OC.sb.from('project_members').select('user_id').eq('project_id', id),
    ]);
    return { p: { ...(p || {}), ...(pmeta || {}) }, expenses: exps || [], orders: ords || [], members: members || [] };
  };
  OC.addProject = (payload) => OC.sb.from('projects').insert(payload);

  // ---- 経費 ----
  OC.loadExpenses = async function (limit) {
    let q = OC.sb.from('expenses')
      .select('id,amount,note,spent_at,status,kind,project_id,proj:project_id(name,code),author:user_id(name,email),vendor:vendor_id(name)')
      .order('spent_at', { ascending: false });
    if (limit) q = q.limit(limit);
    const { data } = await q; return data || [];
  };
  OC.addExpense = (project_id, amount, note) => OC.sb.from('expenses').insert({ project_id, amount, note });

  // ---- 発注 ----
  OC.loadOrders = async function () {
    const sel = 'id,project_id,kind,amount,title,status,from_user,to_user_id,to_dept_id,created_at,vendor:vendor_id(name),proj:project_id(name)';
    const deptList = (OC.myDepts && OC.myDepts.length) ? OC.myDepts : (OC.myDept ? [OC.myDept] : []);
    const inFilter = ['to_user_id.eq.' + OC.me.id].concat(deptList.map((d) => 'to_dept_id.eq.' + d)).join(',');
    const [{ data: out }, { data: inb }] = await Promise.all([
      OC.sb.from('orders').select(sel).eq('from_user', OC.me.id).order('created_at', { ascending: false }),
      OC.sb.from('orders').select(sel).or(inFilter).order('created_at', { ascending: false }),
    ]);
    return { out: out || [], inbound: inb || [] };
  };
})();
