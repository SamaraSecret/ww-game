'use strict';
(function () {
  // ---------- setup ----------
  const cfg = window.WW_CONFIG;
  const sb = window.supabase.createClient(cfg.url, cfg.key, { auth: { persistSession: false, autoRefreshToken: false } });
  const $ = (id) => document.getElementById(id);
  const mem = { ls: {}, ss: {} };
  const wrap = (which) => ({
    get(k) {
      try { return (which === 'ss' ? sessionStorage : localStorage).getItem(k); }
      catch (e) { return mem[which][k] || null; }
    },
    set(k, v) {
      try { (which === 'ss' ? sessionStorage : localStorage).setItem(k, v); }
      catch (e) { mem[which][k] = v; }
    },
    del(k) {
      try { (which === 'ss' ? sessionStorage : localStorage).removeItem(k); }
      catch (e) { delete mem[which][k]; }
    }
  });
  const ls = wrap('ls');
  const ss = wrap('ss');
  // Players persist in localStorage so they stay signed in. Admin tokens live in
  // sessionStorage so closing the tab drops the client copy (the server still
  // expires admin sessions after 2 hours idle or 12 hours maximum).
  function readToken() { return ss.get('ww_token') || ls.get('ww_token'); }
  function writeToken(tok, isAdmin) {
    if (isAdmin) { ss.set('ww_token', tok); ls.del('ww_token'); }
    else { ls.set('ww_token', tok); ss.del('ww_token'); }
  }
  function clearToken() { ss.del('ww_token'); ls.del('ww_token'); }
  let token = readToken();
  // Random per-browser device id, used only for login throttling (no IPs are stored).
  let device = ls.get('ww_device');
  if (!device || !/^[0-9a-f]{32}$/.test(device)) {
    const b = new Uint8Array(16); crypto.getRandomValues(b);
    device = Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
    ls.set('ww_device', device);
  }
  let me = null;
  let timers = [];

  // Build DOM safely: strings always become text nodes (never HTML).
  function h(tag, attrs, ...kids) {
    const el = document.createElement(tag);
    if (attrs) for (const k in attrs) {
      const v = attrs[k];
      if (v == null || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
      else if (k === 'text') el.textContent = v;
      else el.setAttribute(k, v === true ? '' : v);
    }
    for (const c of kids.flat()) {
      if (c == null || c === false) continue;
      el.appendChild(typeof c === 'object' ? c : document.createTextNode(String(c)));
    }
    return el;
  }
  const money = (n) => '$' + Number(n || 0).toLocaleString('en-US');
  const num = (n) => Number(n || 0).toLocaleString('en-US', { maximumFractionDigits: 2 });
  const when = (t) => { const d = new Date(t); return d.toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }); };
  const mmss = (s) => { s = Math.max(0, Math.round(s)); return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); };

  function toast(msg, err) {
    const t = $('toast'); t.textContent = msg; t.className = 'toast' + (err ? ' err' : '');
    clearTimeout(toast._t); toast._t = setTimeout(() => t.classList.add('hidden'), 4000);
  }

  async function call(fn, args) {
    const { data, error } = await sb.rpc(fn, Object.assign({ p_token: token }, args || {}));
    if (error) {
      const m = error.message || 'Request failed';
      if (/Session expired|Not logged in|banned/i.test(m) && fn !== 'login') { logoutLocal(m); }
      throw new Error(m);
    }
    if (data && data.me) setMe(data.me);
    return data;
  }
  async function act(fn, args, after) {
    try {
      const d = await call(fn, args);
      if (d && d.reauth) { logoutLocal(d.message || 'Please log in again.'); return d; }
      if (d && d.message) toast(d.message);
      if (after) await after(d);
      return d;
    } catch (e) { toast(e.message, true); return null; }
  }

  // ---------- auth ----------
  let authMode = 'login';
  function setAuthMode(m) {
    authMode = m;
    ['login', 'register'].forEach((x) => $('tab-' + x).classList.toggle('active', x === m));
    $('auth-submit').textContent = m === 'register' ? 'Register' : 'Log in';
    $('auth-hint').textContent = m === 'register' ? 'Pick a username (3-16 letters, numbers, _) and a password (8+ characters, not a common one).'
      : 'Welcome back, soldier.';
    $('auth-pass').setAttribute('autocomplete', m === 'register' ? 'new-password' : 'current-password');
    $('auth-msg').textContent = '';
  }
  ['login', 'register'].forEach((m) => $('tab-' + m).addEventListener('click', () => setAuthMode(m)));
  $('auth-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const u = $('auth-user').value.trim(), p = $('auth-pass').value;
    const msg = $('auth-msg'); msg.className = 'msg'; msg.textContent = 'Please wait...';
    $('auth-submit').disabled = true;
    try {
      const { data, error } = await sb.rpc(authMode === 'register' ? 'register' : 'login', { p_username: u, p_password: p, p_device: device });
      if (error) throw new Error(error.message);
      if (data.error) throw new Error(data.error);
      token = data.token; writeToken(token, !!data.is_admin);
      const m = await call('get_me'); setMe(m);
      $('auth-pass').value = '';
      startGame('home');
    } catch (err) { msg.textContent = err.message; }
    finally { $('auth-submit').disabled = false; }
  });

  function logoutLocal(reason) {
    token = null; me = null; clearToken();
    timers.forEach(clearInterval); timers = [];
    $('game').classList.add('hidden'); $('auth').classList.remove('hidden');
    setAuthMode('login');
    if (reason) { $('auth-msg').className = 'msg'; $('auth-msg').textContent = reason; }
  }

  // ---------- sidebar ----------
  function setBar(id, v, max) { $(id).style.width = Math.max(0, Math.min(100, (v / max) * 100)) + '%'; }
  function setMe(m) {
    me = m; me._at = Date.now();
    if (token) writeToken(token, !!m.is_admin);
    $('sb-name').textContent = m.username; $('sb-rank').textContent = m.rank;
    $('sb-level').textContent = m.level; $('sb-cash').textContent = money(m.cash);
    const pts = $('sb-pts'); if (pts) pts.textContent = num(m.stat_points);
    const st = $('sb-status'); st.textContent = m.status; st.className = 'status-' + m.status;
    $('top-user').textContent = m.username + ' · Lv ' + m.level;
    setBar('sb-energy', m.energy, m.max_energy); setBar('sb-nerve', m.nerve, m.max_nerve);
    setBar('sb-hp', m.hp, m.max_hp);
    const atCap = m.max_level && m.level >= m.max_level;
    if (atCap) { setBar('sb-xp', 1, 1); $('sb-xp-t').textContent = 'MAX'; }
    else { setBar('sb-xp', m.xp - m.xp_prev, m.xp_next - m.xp_prev); $('sb-xp-t').textContent = num(m.xp) + ' / ' + num(m.xp_next); }
    $('sb-hp-t').textContent = m.hp + ' / ' + m.max_hp;
    updateTimers();
    renderNav();
  }
  function updateTimers() {
    if (!me) return;
    const el = (Date.now() - me._at) / 1000;
    $('sb-energy-t').textContent = me.energy + ' / ' + me.max_energy + (me.energy_next != null ? ' (+5 in ' + mmss(me.energy_next - el) + ')' : '');
    $('sb-nerve-t').textContent = me.nerve + ' / ' + me.max_nerve + (me.nerve_next != null ? ' (+1 in ' + mmss(me.nerve_next - el) + ')' : '');
    if ((me.energy_next != null && me.energy_next - el <= 0) || (me.nerve_next != null && me.nerve_next - el <= 0)) {
      if (!updateTimers._busy) { updateTimers._busy = true; refreshMe().finally(() => { updateTimers._busy = false; }); }
    }
  }
  async function refreshMe() { try { setMe(await call('get_me')); } catch (e) { /* handled */ } }

  const pages = [
    ['home', 'Home'], ['training', 'Training Camp'], ['missions', 'Missions'], ['battlefield', 'Battlefield'], ['command', 'Army Command'],
    ['hospital', 'Field Hospital'], ['armory', 'Armory'], ['bank', 'Bank'], ['army', 'Army'],
    ['players', 'Soldiers'], ['leaderboards', 'Leaderboards'], ['events', 'Events'], ['chat', 'Radio Chat'],
    ['settings', 'Security']
  ];
  function renderNav() {
    const nav = $('nav'); nav.textContent = '';
    const cur = (location.hash.slice(1) || 'home').split('/')[0];
    const list = pages.slice(); if (me && me.is_admin) list.push(['admin', 'Admin Panel']);
    for (const [k, label] of list) {
      nav.appendChild(h('a', { href: '#' + k, class: cur === k ? 'active' : null }, label,
        k === 'events' && me && me.unread > 0 ? h('span', { class: 'badge' }, me.unread) : null));
    }
    nav.appendChild(h('a', { onclick: async () => { await sb.rpc('logout', { p_token: token }); logoutLocal('Logged out.'); } }, 'Log out'));
  }
  $('menu-btn').addEventListener('click', () => $('sidebar').classList.toggle('open'));

  // ---------- routing ----------
  let pageTimer = null;
  async function route() {
    if (!token) return;
    $('sidebar').classList.remove('open');
    if (pageTimer) { clearInterval(pageTimer); pageTimer = null; }
    const [page, arg] = (location.hash.slice(1) || 'home').split('/');
    renderNav();
    const host = $('main'); host.textContent = '';
    const main = h('div'); host.appendChild(main);   // stale renders go to a detached node
    const fn = views[page] || views.home;
    try { await fn(main, arg); } catch (e) { main.appendChild(h('div', { class: 'notice red' }, e.message)); }
  }
  window.addEventListener('hashchange', route);
  const go = (p) => { if (location.hash === '#' + p) route(); else location.hash = p; };

  function statusNotice(main) {
    if (!me) return;
    if (me.status === 'Hospital') main.appendChild(h('div', { class: 'notice red' }, 'You are in the field hospital until ' + when(me.hospital_until) + '. ', h('a', { href: '#hospital' }, 'Go to hospital')));
    if (me.status === 'Stockade') main.appendChild(h('div', { class: 'notice red' }, 'You are held in the stockade until ' + when(me.jail_until) + '. ', h('a', { href: '#hospital' }, 'Pay for release')));
  }
  function playerLink(p) { return h('a', { href: '#profile/' + p.id }, p.username); }

  // Original in-repo SVG icons only. Slugs are validated so a bad catalog value cannot become a URL.
  function itemIcon(slug, name, small) {
    const s = (slug && /^[a-z0-9-]+$/.test(slug)) ? slug : 'unknown';
    return h('img', { class: 'item-icon' + (small ? ' sm' : ''), src: 'assets/icons/' + s + '.svg', alt: name || '', width: small ? '28' : '40', height: small ? '28' : '40' });
  }
  function itemCell(icon, name, extra, desc) {
    return h('div', { class: 'item-cell' }, itemIcon(icon, name),
      h('div', { class: 'meta' }, h('b', null, name), extra || null, desc ? h('div', { class: 'muted small' }, desc) : null));
  }

  // ---------- views ----------
  const views = {};

  views.home = async (main) => {
    const m = await call('get_me'); setMe(m);
    main.appendChild(h('h2', null, 'Headquarters'));
    if (m.announcement) main.appendChild(h('div', { class: 'notice' }, h('b', null, 'Command announcement: '), m.announcement.message));
    statusNotice(main);
    main.appendChild(h('div', { class: 'grid' },
      h('div', { class: 'panel' }, h('h3', null, 'Soldier'), h('div', { class: 'kv' },
        h('span', null, 'Name'), h('span', null, m.username), h('span', null, 'Rank'), h('span', null, m.rank),
        h('span', null, 'Level'), h('span', null, m.level), h('span', null, 'Army'), h('span', null, m.faction ? m.faction.name + ' [' + m.faction.tag + ']' : 'None'),
        h('span', null, 'Force'), h('a', { href: '#command' }, m.force_class + ' · ' + num(m.troops) + ' troops'),
        h('span', null, 'Record'), h('span', null, m.wins + ' wins / ' + m.losses + ' losses'),
        h('span', null, 'Missions'), h('span', null, m.missions_done + ' completed'))),
      h('div', { class: 'panel' }, h('h3', null, 'Finances'), h('div', { class: 'kv' },
        h('span', null, 'Cash'), h('span', { class: 'money' }, money(m.cash)), h('span', null, 'Bank'), h('span', { class: 'money' }, money(m.bank)))),
      h('div', { class: 'panel' }, h('h3', null, 'Battle stats'), h('div', { class: 'kv' },
        h('span', null, 'Strength'), h('span', null, num(m.str)), h('span', null, 'Defense'), h('span', null, num(m.def)),
        h('span', null, 'Speed'), h('span', null, num(m.spd)), h('span', null, 'Dexterity'), h('span', null, num(m.dex)),
        h('span', null, 'Total'), h('b', null, num(m.total)),
        h('span', null, 'Unspent points'), h('span', null, num(m.stat_points), ' ', h('a', { href: '#training' }, 'spend →')))),
      h('div', { class: 'panel' }, h('h3', null, 'Equipment'), h('div', { class: 'kv' },
        h('span', null, 'Weapon'), h('span', { class: 'eq-line' }, itemIcon(m.weapon ? m.weapon.icon : 'fists', m.weapon ? m.weapon.name : 'Bare fists', true),
          m.weapon ? m.weapon.name + ' (+' + m.weapon.power + ')' : 'Bare fists'),
        h('span', null, 'Armor'), h('span', { class: 'eq-line' }, m.armor ? itemIcon(m.armor.icon, m.armor.name, true) : null,
          m.armor ? m.armor.name + ' (+' + m.armor.power + ')' : 'None')))
    ));
    const ev = h('div', { class: 'panel' }, h('h3', null, 'Latest events'));
    if (!m.recent_events.length) ev.appendChild(h('p', { class: 'muted' }, 'Nothing yet.'));
    m.recent_events.forEach((e) => ev.appendChild(h('div', { class: 'ev' + (e.seen ? '' : ' unseen') }, h('div', { class: 't' }, when(e.created_at)), e.message)));
    ev.appendChild(h('a', { href: '#events' }, 'All events →'));
    main.appendChild(ev);
  };

  views.training = async (main) => {
    main.appendChild(h('h2', null, 'Training Camp'));
    statusNotice(main);
    const ptsLabel = h('b', null, num(me.stat_points));
    main.appendChild(h('div', { class: 'notice' },
      h('b', null, 'Stat points: '), ptsLabel, ' unspent. Every level-up grants 5 points. Spend them below, or keep drilling with energy.'));
    main.appendChild(h('p', { class: 'muted' }, 'Each drill costs 5 energy. Gains shrink as a stat grows, and every session has a little luck.'));
    const times = h('input', { type: 'number', min: '1', max: '20', value: '1', class: 'mw90' });
    const grid = h('div', { class: 'grid' });
    const stats = [['str', 'Strength', 'Hit harder in battle.'], ['def', 'Defense', 'Take less damage.'], ['spd', 'Speed', 'Strike first and land more hits.'], ['dex', 'Dexterity', 'Dodge attacks and succeed at missions.']];
    const vals = {};
    const refreshPts = () => { ptsLabel.textContent = num(me.stat_points); };
    const spend = (stat, n) => {
      const have = me.stat_points || 0;
      const amt = n === 'max' ? have : Math.min(n, have);
      if (amt < 1) { toast('You have no unspent stat points.', true); return; }
      const args = { p_str: 0, p_def: 0, p_spd: 0, p_dex: 0 };
      args['p_' + stat] = amt;
      return act('spend_stats', args, (d) => { vals[stat].textContent = num(d.me[stat]); refreshPts(); });
    };
    for (const [k, label, desc] of stats) {
      vals[k] = h('div', { class: 'stat-big' }, num(me[k]));
      grid.appendChild(h('div', { class: 'panel' }, h('h3', null, label), vals[k], h('p', { class: 'muted small' }, desc),
        h('div', { class: 'inline mb8' },
          h('button', { class: 'btn small primary', onclick: () => spend(k, 1) }, '+1'),
          h('button', { class: 'btn small primary', onclick: () => spend(k, 5) }, '+5'),
          h('button', { class: 'btn small primary', onclick: () => spend(k, 10) }, '+10'),
          h('button', { class: 'btn small', onclick: () => spend(k, 'max') }, 'Max')),
        h('button', { class: 'btn primary', onclick: () => act('train', { p_stat: k, p_times: parseInt(times.value, 10) || 1 }, (d) => { vals[k].textContent = num(d.value); }) }, 'Train ' + label)));
    }
    main.appendChild(h('div', { class: 'panel inline' }, h('span', null, 'Drills per click (1-20):'), times,
      h('button', { class: 'btn small', onclick: () => { times.value = Math.max(1, Math.min(20, Math.floor(me.energy / 5))); } }, 'Use all energy')));
    main.appendChild(grid);
  };

  views.missions = async (main) => {
    main.appendChild(h('h2', null, 'Missions'));
    statusNotice(main);
    main.appendChild(h('p', { class: 'muted' }, 'Missions cost nerve. Failure can wound you or land you in the stockade. Dexterity and level improve your odds.'));
    const out = h('div');
    const list = await call('list_missions');
    const tb = h('tbody');
    list.forEach((m) => tb.appendChild(h('tr', null,
      h('td', null, h('b', null, m.name), h('div', { class: 'muted small' }, m.description)),
      h('td', null, m.nerve_cost), h('td', null, 'Lv ' + m.min_level), h('td', null, money(m.cash_min) + '-' + money(m.cash_max)),
      h('td', null, m.xp), h('td', null, m.locked ? '—' : m.chance + '%'),
      h('td', null, h('button', { class: 'btn primary small', disabled: m.locked, onclick: () => act('do_mission', { p_mission: m.id }, (d) => {
        out.textContent = ''; out.appendChild(h('div', { class: 'notice' + (d.result === 'success' ? '' : ' red') }, d.message));
      }) }, m.locked ? 'Locked' : 'Go')))));
    main.appendChild(out);
    main.appendChild(h('div', { class: 'panel table-wrap' }, h('table', null,
      h('thead', null, h('tr', null, ['Mission', 'Nerve', 'Req.', 'Reward', 'XP', 'Chance', ''].map((x) => h('th', null, x)))), tb)));
  };

  views.battlefield = async (main) => {
    main.appendChild(h('h2', null, 'Battlefield'));
    statusNotice(main);
    main.appendChild(h('p', { class: 'muted' }, 'Attacking costs 25 energy. The loser is hospitalized; the winner takes a share of their cash and earns XP. Recruits below level 3 are protected, and you can attack the same soldier once every 10 minutes.'));
    const out = h('div');
    main.appendChild(out);
    const list = await call('list_targets');
    const tb = h('tbody');
    list.forEach((t) => {
      const blocked = t.protected || t.status !== 'Okay' || (t.cooldown && t.cooldown > 0);
      tb.appendChild(h('tr', null,
        h('td', null, playerLink(t), t.npc ? h('span', { class: 'muted small' }, ' (training target)') : null, t.faction ? h('span', { class: 'muted small' }, ' [' + t.faction + ']') : null),
        h('td', null, t.level), h('td', null, t.rank), h('td', { class: 'status-' + t.status }, t.status),
        h('td', null, h('button', { class: 'btn danger small', disabled: blocked, onclick: () => attack(t.id, out) },
          t.cooldown > 0 ? 'Cooldown ' + mmss(t.cooldown) : 'Attack'))));
    });
    main.appendChild(h('div', { class: 'panel table-wrap' }, h('table', null,
      h('thead', null, h('tr', null, ['Soldier', 'Lv', 'Rank', 'Status', ''].map((x) => h('th', null, x)))), tb)));
  };
  async function attack(id, out) {
    const d = await act('attack', { p_target: id });
    if (!d) return;
    out.textContent = '';
    out.appendChild(h('div', { class: 'notice' + (d.result === 'win' ? '' : ' red') }, d.message));
    out.appendChild(h('div', { class: 'log' }, d.log.map((l) => h('div', null, l))));
    out.appendChild(h('p', null, h('a', { onclick: () => go('battlefield') }, 'Back to the battlefield')));
    window.scrollTo(0, 0);
  }

  views.command = async (main) => {
    main.appendChild(h('h2', null, 'Army Command'));
    statusNotice(main);
    const a = await call('get_army');
    const pw = a.power;
    main.appendChild(h('div', { class: 'grid' },
      h('div', { class: 'panel' }, h('h3', null, 'Force'), h('div', { class: 'kv' },
        h('span', null, 'Force class'), h('b', null, a.force_class),
        h('span', null, 'Troops'), h('span', null, num(a.troops) + ' / ' + num(a.max_troops)),
        h('span', null, 'Free (level-up)'), h('span', null, num(me.troops_free_granted) + ' / 300'),
        h('span', null, 'Armed troops'), h('span', null, num(pw.armed) + ' / ' + num(a.troops)),
        h('span', null, 'Vehicles'), h('span', null, num(pw.vehicles)))),
      h('div', { class: 'panel' }, h('h3', null, 'Army Power'), h('div', { class: 'stat-big' }, num(pw.power)), h('div', { class: 'kv' },
        h('span', null, 'Attack'), h('span', null, num(pw.attack)), h('span', null, 'Defense'), h('span', null, num(pw.defense))),
        h('p', { class: 'muted small' }, 'Army power boosts your battle damage (up to +50%) and blunts the enemy\'s. Only your force class is public.'))));
    // Recruit
    const cnt = h('input', { type: 'number', min: '1', max: '1000', placeholder: 'Troops', class: 'mw120' });
    main.appendChild(h('div', { class: 'notice' }, h('b', null, 'Free troops: '), '+2 troops every level-up (' + num(me.troops_free_granted) + ' / 300 free troops received). ',
      'Everything beyond that is bought in Supplies, up to a maximum army size of 1,000 troops.'));
    main.appendChild(h('h2', null, 'Supplies'));
    main.appendChild(h('div', { class: 'panel' }, h('h3', null, 'Recruit troops'),
      h('p', { class: 'muted small' }, 'Each recruit costs a bit more as your force grows, plus 1 energy per 20 troops. Maximum army size: 1,000 troops.'),
      h('div', { class: 'inline' },
        h('button', { class: 'btn primary', disabled: a.cost10 == null, onclick: () => act('recruit_troops', { p_count: 10 }, () => go('command')) }, 'Recruit 10' + (a.cost10 != null ? ' (' + money(a.cost10) + ')' : '')),
        h('button', { class: 'btn primary', disabled: a.cost100 == null, onclick: () => act('recruit_troops', { p_count: 100 }, () => go('command')) }, 'Recruit 100' + (a.cost100 != null ? ' (' + money(a.cost100) + ')' : '')),
        cnt, h('button', { class: 'btn', onclick: () => act('recruit_troops', { p_count: parseInt(cnt.value, 10) }, () => go('command')) }, 'Recruit'),
        h('button', { class: 'btn danger', onclick: () => { if (confirm('Dismiss ' + (cnt.value || 0) + ' troops? There is no refund.')) act('dismiss_troops', { p_count: parseInt(cnt.value, 10) }, () => go('command')); } }, 'Dismiss'))));
    // Weapons
    const wtb = h('tbody');
    a.weapons.forEach((w) => {
      const q = h('input', { type: 'number', min: '1', value: '10', class: 'mw80' });
      const locked = a.level < w.min_level;
      wtb.appendChild(h('tr', null, h('td', null, itemCell(w.icon, w.name, null, w.description)),
        h('td', null, '+' + w.attack + ' / +' + w.defense), h('td', null, money(w.price)), h('td', null, 'Lv ' + w.min_level), h('td', null, num(w.owned)),
        h('td', { class: 'inline' }, q,
          h('button', { class: 'btn small primary', disabled: locked, onclick: () => act('buy_troop_weapon', { p_weapon: w.id, p_qty: parseInt(q.value, 10) }, () => go('command')) }, 'Buy'),
          w.owned > 0 ? h('button', { class: 'btn small danger', onclick: () => act('sell_troop_weapon', { p_weapon: w.id, p_qty: parseInt(q.value, 10) }, () => go('command')) }, 'Sell') : null)));
    });
    main.appendChild(h('div', { class: 'panel table-wrap' }, h('h3', null, 'Supplies: army weapons'),
      h('p', { class: 'muted small' }, 'Each troop carries one weapon; the best weapons are issued first. Extra weapons sit in storage. Sell for 50%.'),
      h('table', null, h('thead', null, h('tr', null, ['Weapon', 'Atk / Def per troop', 'Price', 'Req.', 'Owned', ''].map((x) => h('th', null, x)))), wtb)));
    // Vehicles
    const vtb = h('tbody');
    let anyDamaged = false;
    a.vehicles.forEach((v) => {
      const locked = a.level < v.min_level;
      const units = h('div');
      v.units.forEach((u, i) => {
        if (u.condition < 100) anyDamaged = true;
        units.appendChild(h('div', { class: 'inline small' }, '#' + (i + 1) + ' · ' + u.condition + '% condition',
          u.condition < 100 ? h('button', { class: 'btn small', onclick: () => act('repair_vehicle', { p_unit: u.id }, () => go('command')) }, 'Repair ' + money(u.repair_cost)) : null,
          h('button', { class: 'btn small danger', onclick: () => { if (confirm('Sell this ' + v.name + ' for ' + money(u.sell_value) + '?')) act('sell_vehicle', { p_unit: u.id }, () => go('command')); } }, 'Sell ' + money(u.sell_value))));
      });
      vtb.appendChild(h('tr', null, h('td', null, itemCell(v.icon, v.name, null, v.description), units),
        h('td', null, v.attack + ' / ' + v.defense), h('td', null, money(v.price)), h('td', null, 'Lv ' + v.min_level),
        h('td', null, v.units.length + ' / ' + v.cap),
        h('td', null, h('button', { class: 'btn small primary', disabled: locked || v.units.length >= v.cap, onclick: () => act('buy_vehicle', { p_vehicle: v.id }, () => go('command')) }, locked ? 'Locked' : 'Buy'))));
    });
    main.appendChild(h('div', { class: 'panel table-wrap' }, h('h3', null, 'Supplies: vehicles'),
      h('p', { class: 'muted small' }, 'Vehicles wear down in battle and fight at reduced strength until repaired. Selling refunds 40% of the price, scaled by condition. More of each type unlocks as you level up.'),
      anyDamaged ? h('button', { class: 'btn', onclick: () => act('repair_all_vehicles', null, () => go('command')) }, 'Repair all') : null,
      h('table', null, h('thead', null, h('tr', null, ['Vehicle', 'Atk / Def', 'Price', 'Req.', 'Owned / cap', ''].map((x) => h('th', null, x)))), vtb)));
  };

  views.hospital = async (main) => {
    main.appendChild(h('h2', null, 'Field Hospital & Stockade'));
    const m = await call('get_me'); setMe(m);
    if (m.status === 'Hospital') {
      const left = (new Date(m.hospital_until) - Date.now()) / 1000;
      main.appendChild(h('div', { class: 'notice red' }, 'You are recovering for another ' + mmss(left) + '. You will be discharged at full health.',
        h('div', null, h('button', { class: 'btn primary', onclick: () => act('revive', null, () => go('hospital')) }, 'Pay for emergency treatment (about ' + money(50 * m.level + Math.ceil(left / 60) * 25) + ')'))));
    } else if (m.status === 'Stockade') {
      const left = (new Date(m.jail_until) - Date.now()) / 1000;
      main.appendChild(h('div', { class: 'notice red' }, 'You are held for another ' + mmss(left) + '.',
        h('div', null, h('button', { class: 'btn primary', onclick: () => act('pay_bail', null, () => go('hospital')) }, 'Pay for release (about ' + money(75 * m.level + Math.ceil(left / 60) * 30) + ')'))));
    } else {
      main.appendChild(h('div', { class: 'notice' }, 'You are fit for duty. Health regenerates 10% every 5 minutes.'));
    }
    const list = await call('hospital_list');
    const p = h('div', { class: 'panel' }, h('h3', null, 'Currently hospitalized'));
    if (!list.length) p.appendChild(h('p', { class: 'muted' }, 'The wards are empty.'));
    list.forEach((x) => p.appendChild(h('div', { class: 'ev' }, playerLink(x), ' (Lv ' + x.level + ') until ' + when(x.until))));
    main.appendChild(p);
  };

  views.armory = async (main) => {
    main.appendChild(h('h2', null, 'Armory'));
    main.appendChild(h('p', { class: 'muted' }, 'Weapons add damage, armor reduces damage taken. Items sell back for half price.'));
    const items = await call('list_items');
    for (const kind of ['weapon', 'armor']) {
      const tb = h('tbody');
      items.filter((i) => i.kind === kind).forEach((i) => tb.appendChild(h('tr', null,
        h('td', null, itemCell(i.icon, i.name, i.equipped ? h('span', { class: 'money small' }, ' (equipped)') : null, i.description)),
        h('td', null, '+' + i.power), h('td', null, money(i.price)), h('td', null, 'Lv ' + i.min_level), h('td', null, i.owned),
        h('td', { class: 'inline' },
          h('button', { class: 'btn small primary', disabled: me.level < i.min_level, onclick: () => act('buy_item', { p_item: i.id }, () => go('armory')) }, 'Buy'),
          i.owned > 0 && !i.equipped ? h('button', { class: 'btn small', onclick: () => act('equip_item', { p_item: i.id }, () => go('armory')) }, 'Equip') : null,
          i.equipped ? h('button', { class: 'btn small', onclick: () => act('unequip_item', { p_kind: kind }, () => go('armory')) }, 'Unequip') : null,
          i.owned > 0 ? h('button', { class: 'btn small danger', onclick: () => act('sell_item', { p_item: i.id }, () => go('armory')) }, 'Sell') : null))));
      main.appendChild(h('div', { class: 'panel table-wrap' }, h('h3', null, kind === 'weapon' ? 'Weapons' : 'Armor'), h('table', null,
        h('thead', null, h('tr', null, ['Item', 'Power', 'Price', 'Req.', 'Owned', ''].map((x) => h('th', null, x)))), tb)));
    }
  };

  views.bank = async (main) => {
    main.appendChild(h('h2', null, 'War Bank'));
    const m = await call('get_me'); setMe(m);
    main.appendChild(h('p', { class: 'muted' }, 'Cash in the bank cannot be taken when you lose a battle. Deposits cost a 1% fee; withdrawals are free.'));
    const bal = h('div', { class: 'kv' }, h('span', null, 'Cash'), h('span', { class: 'money' }, money(m.cash)), h('span', null, 'Bank'), h('span', { class: 'money' }, money(m.bank)));
    const amt = h('input', { type: 'number', min: '1', placeholder: 'Amount' });
    const val = () => parseInt(amt.value, 10);
    main.appendChild(h('div', { class: 'panel' }, bal));
    main.appendChild(h('div', { class: 'panel inline' }, amt,
      h('button', { class: 'btn primary', onclick: () => act('bank_deposit', { p_amount: val() }, () => go('bank')) }, 'Deposit'),
      h('button', { class: 'btn', onclick: () => act('bank_withdraw', { p_amount: val() }, () => go('bank')) }, 'Withdraw'),
      h('button', { class: 'btn small', onclick: () => { amt.value = me.cash; } }, 'All cash'),
      h('button', { class: 'btn small', onclick: () => { amt.value = me.bank; } }, 'All bank')));
  };

  views.players = async (main) => {
    main.appendChild(h('h2', null, 'Soldiers'));
    const q = h('input', { placeholder: 'Search username', maxlength: '16' });
    let page = 0;
    const tb = h('tbody');
    const load = async () => {
      const list = await call('list_players', { p_search: q.value, p_page: page });
      tb.textContent = '';
      if (!list.length) tb.appendChild(h('tr', null, h('td', { colspan: '5', class: 'muted' }, 'No soldiers found.')));
      list.forEach((p) => tb.appendChild(h('tr', null, h('td', null, playerLink(p), p.npc ? h('span', { class: 'muted small' }, ' (NPC)') : null, p.staff ? h('span', { class: 'status-Hospital small' }, ' (Staff)') : null),
        h('td', null, p.level), h('td', null, p.rank), h('td', null, p.faction ? p.faction.tag : '—'), h('td', { class: 'status-' + p.status }, p.status + (p.online ? ' · online' : '')))));
    };
    main.appendChild(h('div', { class: 'panel inline' }, q, h('button', { class: 'btn', onclick: () => { page = 0; load(); } }, 'Search'),
      h('button', { class: 'btn small', onclick: () => { if (page > 0) { page--; load(); } } }, '‹ Prev'),
      h('button', { class: 'btn small', onclick: () => { page++; load(); } }, 'Next ›')));
    main.appendChild(h('div', { class: 'panel table-wrap' }, h('table', null, h('thead', null, h('tr', null, ['Soldier', 'Lv', 'Rank', 'Army', 'Status'].map((x) => h('th', null, x)))), tb)));
    await load();
  };

  views.profile = async (main, id) => {
    const p = await call('get_profile', { p_player: parseInt(id, 10) });
    main.appendChild(h('h2', null, p.username));
    main.appendChild(h('div', { class: 'panel' }, h('div', { class: 'kv' },
      h('span', null, 'Rank'), h('span', null, p.rank + (p.staff ? ' · Command Staff' : '') + (p.npc ? ' · Training target' : '')),
      h('span', null, 'Level'), h('span', null, p.level),
      h('span', null, 'Force class'), h('span', null, p.force),
      h('span', null, 'Army'), p.faction ? h('a', { href: '#army/' + p.faction.id }, p.faction.name + ' [' + p.faction.tag + ']') : h('span', null, 'None'),
      h('span', null, 'Status'), h('span', { class: 'status-' + p.status }, p.status + (p.online ? ' · online' : '')),
      h('span', null, 'Record'), h('span', null, p.wins + ' wins / ' + p.losses + ' losses'),
      h('span', null, 'Enlisted'), h('span', null, p.joined))));
    main.appendChild(h('p', { class: 'muted small' }, 'Battle stats, force size, cash and bank balances are private.'));
    if (p.id !== me.id && !p.staff && p.status === 'Okay' && (p.npc || p.level >= 3)) {
      const out = h('div');
      main.appendChild(h('button', { class: 'btn danger', onclick: () => attack(p.id, out) }, 'Attack ' + p.username + ' (25 energy)'));
      main.appendChild(out);
    }
  };

  views.leaderboards = async (main, kind) => {
    kind = kind || 'level';
    main.appendChild(h('h2', null, 'Leaderboards'));
    const tabs = [['level', 'Level'], ['wins', 'Battle wins'], ['stats', 'Battle strength'], ['army', 'Army power'], ['wealth', 'Wealth']];
    main.appendChild(h('div', { class: 'tabs' }, tabs.map(([k, l]) => h('button', { class: 'tab' + (k === kind ? ' active' : ''), onclick: () => go('leaderboards/' + k) }, l))));
    if (kind === 'stats' || kind === 'wealth' || kind === 'army') main.appendChild(h('p', { class: 'muted small' }, 'Only the order is shown. Exact numbers are private.'));
    const list = await call('leaderboard', { p_kind: kind });
    const tb = h('tbody');
    list.forEach((p, i) => tb.appendChild(h('tr', null, h('td', null, '#' + (i + 1)), h('td', null, playerLink(p)), h('td', null, p.rank), h('td', null, p.value == null ? '—' : num(p.value)))));
    if (!list.length) tb.appendChild(h('tr', null, h('td', { colspan: '4', class: 'muted' }, 'No soldiers yet.')));
    main.appendChild(h('div', { class: 'panel table-wrap' }, h('table', null, h('thead', null, h('tr', null, ['#', 'Soldier', 'Rank', kind === 'wins' ? 'Wins' : kind === 'level' ? 'Level' : ''].map((x) => h('th', null, x)))), tb)));
  };

  views.events = async (main) => {
    main.appendChild(h('h2', null, 'Events'));
    const list = await call('get_events');
    const p = h('div', { class: 'panel' });
    if (!list.length) p.appendChild(h('p', { class: 'muted' }, 'No events yet.'));
    list.forEach((e) => p.appendChild(h('div', { class: 'ev' + (e.seen ? '' : ' unseen') }, h('div', { class: 't' }, when(e.created_at) + ' · ' + e.kind), e.message)));
    main.appendChild(p);
    me.unread = 0; renderNav();
  };

  views.chat = async (main) => {
    main.appendChild(h('h2', null, 'Radio Chat'));
    const box = h('div', { class: 'chat-box' });
    const input = h('input', { maxlength: '200', placeholder: 'Message (max 200 characters)' });
    let lastId = 0;
    const load = async () => {
      try {
        const list = await call('get_chat');
        const newest = list.length ? list[list.length - 1].id : 0;
        if (newest === lastId) return;
        lastId = newest; box.textContent = '';
        list.forEach((c) => box.appendChild(h('div', { class: 'chat-line' }, h('span', { class: 't' }, when(c.created_at)),
          c.player_id ? h('a', { class: 'u' + (c.staff ? ' staff' : ''), href: '#profile/' + c.player_id }, c.username + ':') : h('span', { class: 'u staff' }, c.username + ':'),
          h('span', null, c.message))));
        box.scrollTop = box.scrollHeight;
      } catch (e) { /* ignore */ }
    };
    const send = async () => { const m = input.value.trim(); if (!m) return; const ok = await act('send_chat', { p_message: m }); if (ok) { input.value = ''; load(); } };
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter') send(); });
    main.appendChild(box);
    main.appendChild(h('div', { class: 'inline' }, input, h('button', { class: 'btn primary', onclick: send }, 'Send')));
    main.appendChild(h('p', { class: 'muted small' }, 'Be respectful. One message every 4 seconds. Staff can ban abusive players.'));
    await load();
    pageTimer = setInterval(load, 5000);
  };

  views.army = async (main, id) => {
    if (id) {
      const f = await call('get_faction', { p_faction: parseInt(id, 10) });
      main.appendChild(h('h2', null, f.name + ' [' + f.tag + ']'));
      if (f.description) main.appendChild(h('div', { class: 'panel' }, f.description));
      const inIt = me.faction && me.faction.id === f.id;
      main.appendChild(h('div', { class: 'inline mb10' },
        !me.faction ? h('button', { class: 'btn primary', onclick: () => act('join_faction', { p_faction: f.id }, () => refreshMe().then(() => go('army/' + f.id))) }, 'Enlist in this army') : null,
        inIt ? h('button', { class: 'btn danger', onclick: () => { if (confirm('Leave ' + f.name + '?')) act('leave_faction', null, () => refreshMe().then(() => go('army'))); } }, 'Leave army') : null,
        h('a', { href: '#army' }, 'All armies')));
      const tb = h('tbody');
      f.members.forEach((p) => tb.appendChild(h('tr', null, h('td', null, playerLink(p), p.id === f.leader_id ? h('span', { class: 'money small' }, ' (Commander)') : null),
        h('td', null, p.level), h('td', null, p.rank), h('td', { class: 'status-' + p.status }, p.status))));
      main.appendChild(h('div', { class: 'panel table-wrap' }, h('h3', null, 'Members (' + f.members.length + ')'), h('table', null, h('thead', null, h('tr', null, ['Soldier', 'Lv', 'Rank', 'Status'].map((x) => h('th', null, x)))), tb)));
      return;
    }
    main.appendChild(h('h2', null, 'Armies'));
    if (me.faction) main.appendChild(h('div', { class: 'notice' }, 'You serve in ', h('a', { href: '#army/' + me.faction.id }, me.faction.name + ' [' + me.faction.tag + ']'), '.'));
    const list = await call('list_factions');
    const tb = h('tbody');
    list.forEach((f) => tb.appendChild(h('tr', null, h('td', null, h('a', { href: '#army/' + f.id }, f.name), ' [' + f.tag + ']'), h('td', null, f.leader || '—'), h('td', null, f.members), h('td', null, f.total_level))));
    if (!list.length) tb.appendChild(h('tr', null, h('td', { colspan: '4', class: 'muted' }, 'No armies yet. Found the first one!')));
    main.appendChild(h('div', { class: 'panel table-wrap' }, h('table', null, h('thead', null, h('tr', null, ['Army', 'Commander', 'Members', 'Total levels'].map((x) => h('th', null, x)))), tb)));
    if (!me.faction) {
      const n = h('input', { placeholder: 'Army name (3-24)', maxlength: '24' }), t = h('input', { placeholder: 'Tag (2-5)', maxlength: '5' }), d = h('input', { placeholder: 'Short description (optional)', maxlength: '300' });
      main.appendChild(h('div', { class: 'panel' }, h('h3', null, 'Found an army ($10,000)'), n, t, d,
        h('button', { class: 'btn primary mt8', onclick: () => act('create_faction', { p_name: n.value, p_tag: t.value, p_description: d.value }, (r) => refreshMe().then(() => go('army/' + r.id))) }, 'Found army')));
    }
  };

  views.settings = async (main) => {
    main.appendChild(h('h2', null, 'Security'));
    const o = h('input', { type: 'password', placeholder: 'Current password', autocomplete: 'current-password', minlength: '8', maxlength: '72' });
    const n = h('input', { type: 'password', placeholder: 'New password (8+ characters)', autocomplete: 'new-password', minlength: '8', maxlength: '72' });
    const c = h('input', { type: 'password', placeholder: 'Confirm new password', autocomplete: 'new-password', minlength: '8', maxlength: '72' });
    main.appendChild(h('div', { class: 'panel' },
      h('h3', null, 'Change password'),
      h('p', { class: 'muted small' }, 'Use 8-72 characters. Do not reuse a password from another site, and avoid very common passwords. Changing your password signs other devices out. If you are Command Staff, every session including this one ends and you must log in again.'),
      o, n, c,
      h('button', { class: 'btn primary mt8', onclick: () => {
        if (n.value !== c.value) { toast('The new passwords do not match.', true); return; }
        act('change_password', { p_old: o.value, p_new: n.value }, () => { o.value = ''; n.value = ''; c.value = ''; });
      } }, 'Change password')));
    main.appendChild(h('div', { class: 'panel' },
      h('h3', null, 'Sessions'),
      h('p', { class: 'muted small' }, 'Sign out on this device from the sidebar. Use the button below to end every session, including this one.'),
      h('button', { class: 'btn danger', onclick: () => { if (confirm('Sign out on every device?')) act('logout_everywhere'); } }, 'Sign out everywhere')));
    main.appendChild(h('div', { class: 'panel muted small' },
      'Your data: we store only your username, a scrambled (bcrypt) password hash and your game progress. No email address or IP address is stored. ',
      'Player sessions are kept in this browser until they expire (7 days) or you sign out. Command Staff sessions are kept only until you close this tab, and the server ends them after 2 hours idle or 12 hours at most.'));
  };

  views.admin = async (main) => {
    if (!me.is_admin) { main.appendChild(h('div', { class: 'notice red' }, 'Command Staff only.')); return; }
    main.appendChild(h('h2', null, 'Admin Panel'));
    const m0 = await call('get_me'); setMe(m0);
    const after = () => go('admin');
    const fld = (ph, v) => h('input', { type: 'number', placeholder: ph, value: v == null ? '' : String(v), class: 'mw130' });
    const sStr = fld('Strength', m0.str), sDef = fld('Defense', m0.def), sSpd = fld('Speed', m0.spd), sDex = fld('Dexterity', m0.dex), sLvl = fld('Level', m0.level);
    const gCash = fld('Cash'), gTroops = fld('Troops'), gWq = fld('Qty'), gVq = fld('Qty');
    const army = await call('get_army');
    const wSel = h('select', { class: 'mw200' }, army.weapons.map((w) => h('option', { value: String(w.id) }, w.name)));
    const vSel = h('select', { class: 'mw200' }, army.vehicles.map((v) => h('option', { value: String(v.id) }, v.name)));
    const ord = h('input', { maxlength: '300', placeholder: 'Command Order sent to every soldier\'s Events inbox' });
    const val = (el) => (el.value === '' ? null : Number(el.value));
    main.appendChild(h('div', { class: 'panel' }, h('h3', null, 'Command Powers (your own soldier)'),
      h('div', { class: 'inline' },
        h('button', { class: 'btn primary', onclick: () => act('admin_power_refill', null, after) }, 'Refill energy / nerve / health'),
        h('button', { class: 'btn', onclick: () => act('admin_power_release', null, after) }, 'Instant release (hospital / stockade)'),
        h('button', { class: 'btn ' + (m0.immortal ? 'danger' : ''), onclick: () => act('admin_power_toggle', { p_power: 'immortal', p_on: !m0.immortal }, after) }, 'Immortal: ' + (m0.immortal ? 'ON' : 'OFF')),
        h('button', { class: 'btn ' + (m0.god_strike ? 'danger' : ''), onclick: () => act('admin_power_toggle', { p_power: 'god_strike', p_on: !m0.god_strike }, after) }, 'God strike: ' + (m0.god_strike ? 'ON' : 'OFF'))),
      h('h3', null, 'Set stats and level'), h('p', { class: 'muted small' }, 'Levels have no ordinary cap (a safety ceiling of 1,000,000 avoids overflow). Raising your level grants any missing stat points (5 per level-up) and free troops (still capped at 300).'),
        h('div', { class: 'inline' }, sStr, sDef, sSpd, sDex, sLvl,
        h('button', { class: 'btn', onclick: () => act('admin_power_set_stats', { p_str: val(sStr), p_def: val(sDef), p_spd: val(sSpd), p_dex: val(sDex), p_level: val(sLvl) }, after) }, 'Apply')),
      h('h3', null, 'Grant yourself'), h('div', { class: 'inline' }, gCash, gTroops,
        h('button', { class: 'btn', onclick: () => act('admin_power_grant', { p_cash: val(gCash) || 0, p_troops: val(gTroops) || 0 }, after) }, 'Grant cash / troops')),
      h('div', { class: 'inline mt6' }, wSel, gWq, h('button', { class: 'btn', onclick: () => act('admin_power_grant', { p_weapon: Number(wSel.value), p_weapon_qty: val(gWq) || 0 }, after) }, 'Grant weapons'),
        vSel, gVq, h('button', { class: 'btn', onclick: () => act('admin_power_grant', { p_vehicle: Number(vSel.value), p_vehicle_qty: val(gVq) || 0 }, after) }, 'Grant vehicles')),
      h('h3', null, 'Command Order (broadcast)'), h('div', { class: 'inline' }, ord,
        h('button', { class: 'btn primary', onclick: () => act('admin_command_order', { p_message: ord.value }, () => { ord.value = ''; }) }, 'Send order')),
      h('p', { class: 'muted small' }, 'You are hidden from the Battlefield, Soldiers list and leaderboards. Your name shows as "Command HQ" in chat and in other players\' battle reports.')));
    const ann = h('input', { maxlength: '300', placeholder: 'Announcement shown on everyone\'s Home page (empty = clear)' });
    main.appendChild(h('div', { class: 'panel' }, h('h3', null, 'Global announcement'), h('div', { class: 'inline' }, ann,
      h('button', { class: 'btn primary', onclick: () => act('admin_announce', { p_message: ann.value }) }, 'Post'))));
    const q = h('input', { placeholder: 'Search players' });
    const tb = h('tbody');
    const detail = h('div');
    const load = async () => {
      const list = await call('admin_list_players', { p_search: q.value });
      tb.textContent = '';
      list.forEach((p) => tb.appendChild(h('tr', null, h('td', null, p.id), h('td', null, h('a', { onclick: () => showP(p.id) }, p.username), p.npc ? ' (NPC)' : '', p.is_admin ? ' (admin)' : ''),
        h('td', null, p.level), h('td', null, money(p.cash)), h('td', null, money(p.bank)), h('td', { class: p.banned ? 'status-Hospital' : 'status-Okay' }, p.banned ? 'BANNED' : 'ok'),
        h('td', null, when(p.last_action)))));
    };
    const showP = async (id) => {
      const p = await call('admin_get_player', { p_player: id });
      detail.textContent = '';
      const amt = h('input', { type: 'number', placeholder: '+/- cash' });
      detail.appendChild(h('div', { class: 'panel' }, h('h3', null, p.username + ' (#' + p.id + ')'), h('div', { class: 'kv' },
        h('span', null, 'Level / XP'), h('span', null, p.level + ' / ' + num(p.xp)), h('span', null, 'Cash / Bank'), h('span', null, money(p.cash) + ' / ' + money(p.bank)),
        h('span', null, 'Stats'), h('span', null, 'STR ' + num(p.str) + ' · DEF ' + num(p.def) + ' · SPD ' + num(p.spd) + ' · DEX ' + num(p.dex)),
        h('span', null, 'HP / Energy / Nerve'), h('span', null, p.hp + ' / ' + p.energy + ' / ' + p.nerve), h('span', null, 'Status'), h('span', null, p.status + (p.banned ? ' · BANNED' : '')),
        h('span', null, 'Record'), h('span', null, p.wins + 'W / ' + p.losses + 'L'), h('span', null, 'Failed logins'), h('span', null, p.failed_logins),
        h('span', null, 'Active sessions'), h('span', null, p.sessions), h('span', null, 'Created'), h('span', null, when(p.created_at))),
        h('div', { class: 'inline mt10' },
          h('button', { class: 'btn danger', onclick: () => act('admin_set_ban', { p_player: id, p_banned: !p.banned }, () => { load(); showP(id); }) }, p.banned ? 'Unban' : 'Ban'),
          amt, h('button', { class: 'btn', onclick: () => act('admin_adjust_cash', { p_player: id, p_delta: parseInt(amt.value, 10) }, () => { load(); showP(id); }) }, 'Give/take cash'),
          h('button', { class: 'btn danger', onclick: () => { if (confirm('Reset ' + p.username + ' to a fresh level 1 soldier?')) act('admin_reset_player', { p_player: id }, () => { load(); showP(id); }); } }, 'Reset player'))));
      detail.scrollIntoView();
    };
    main.appendChild(h('div', { class: 'panel inline' }, q, h('button', { class: 'btn', onclick: load }, 'Search')));
    main.appendChild(detail);
    main.appendChild(h('div', { class: 'panel table-wrap' }, h('table', null, h('thead', null, h('tr', null, ['#', 'Player', 'Lv', 'Cash', 'Bank', 'Status', 'Last active'].map((x) => h('th', null, x)))), tb)));
    const evp = h('div', { class: 'panel' }, h('h3', null, 'Recent events (all players)'));
    main.appendChild(evp);
    await load();
    const aud = await call('admin_audit_log_list');
    const audp = h('div', { class: 'panel' }, h('h3', null, 'Admin audit log'));
    if (!aud.length) audp.appendChild(h('p', { class: 'muted' }, 'No admin actions yet.'));
    aud.slice(0, 60).forEach((l) => audp.appendChild(h('div', { class: 'ev' }, h('div', { class: 't' }, when(l.created_at) + ' · ' + (l.admin || '?') + (l.target ? ' → ' + l.target : '')),
      l.action + (l.details ? ' ' + JSON.stringify(l.details) : ''))));
    main.insertBefore(audp, evp);
    const evs = await call('admin_recent_events');
    evs.slice(0, 50).forEach((e) => evp.appendChild(h('div', { class: 'ev' }, h('div', { class: 't' }, when(e.created_at) + ' · ' + e.username + ' · ' + e.kind), e.message)));
  };

  // ---------- start ----------
  function startGame(page) {
    $('auth').classList.add('hidden'); $('game').classList.remove('hidden');
    timers.forEach(clearInterval);
    timers = [setInterval(updateTimers, 1000), setInterval(refreshMe, 60000)];
    if (page && location.hash !== '#' + page) location.hash = page; else route();
  }
  (async function init() {
    setAuthMode('login');
    if (!token) { $('auth').classList.remove('hidden'); return; }
    try { setMe(await call('get_me')); startGame(); }
    catch (e) { logoutLocal(); }
  })();
})();
