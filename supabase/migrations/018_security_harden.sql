-- 018_security_harden.sql
-- Lock down privileges, harden auth/sessions/passwords, add rate limits, hide admin identity.

-- ---------------------------------------------------------------------------
-- 1. Session idle tracking
-- ---------------------------------------------------------------------------
alter table game.sessions add column if not exists last_seen timestamptz not null default now();
create index if not exists sessions_player_idx on game.sessions (player_id);
create index if not exists sessions_last_seen_idx on game.sessions (last_seen);

-- ---------------------------------------------------------------------------
-- 2. Per-player action throttle (authenticated RPCs)
-- ---------------------------------------------------------------------------
create table if not exists game.rpc_throttle (
  player_id bigint not null references game.players(id) on delete cascade,
  action text not null,
  window_start timestamptz not null default now(),
  hits int not null default 0,
  last_at timestamptz not null default now(),
  primary key (player_id, action)
);
alter table game.rpc_throttle enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'game.login_throttle'::regclass and conname = 'login_throttle_kind_check'
  ) then
    -- drop any existing kind check, then re-add the expanded one
    perform 1;
  end if;
  begin
    alter table game.login_throttle drop constraint if exists login_throttle_kind_check;
  exception when undefined_object then null;
  end;
end $$;

do $$
declare r record;
begin
  for r in
    select conname from pg_constraint
     where conrelid = 'game.login_throttle'::regclass and contype = 'c'
       and pg_get_constraintdef(oid) ilike '%kind%'
  loop
    execute format('alter table game.login_throttle drop constraint %I', r.conname);
  end loop;
end $$;

alter table game.login_throttle
  add constraint login_throttle_kind_check
  check (kind = any (array['ud'::text, 'd'::text, 'u'::text, 'reg_d'::text, 'admin_g'::text, 'admin_d'::text]));

-- ---------------------------------------------------------------------------
-- 3. Deny-all RLS policies (owner/SECURITY DEFINER still bypasses; no FORCE RLS)
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select n.nspname, c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'game' and c.relkind = 'r'
  loop
    execute format('drop policy if exists no_direct_access on %I.%I', r.nspname, r.relname);
    execute format(
      'create policy no_direct_access on %I.%I for all to public using (false) with check (false)',
      r.nspname, r.relname
    );
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Helpers: rate limit, password policy, password hash
-- ---------------------------------------------------------------------------
create or replace function game.rate_limit(
  pid bigint, act text, max_hits int, win interval, min_gap interval default interval '0'
) returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare r game.rpc_throttle;
begin
  if pid is null then return; end if;
  insert into game.rpc_throttle (player_id, action) values (pid, act)
    on conflict (player_id, action) do nothing;
  select * into r from game.rpc_throttle where player_id = pid and action = act for update;
  if min_gap > interval '0' and r.last_at > now() - min_gap then
    raise exception 'Slow down, soldier. Try again in a moment.';
  end if;
  if r.window_start <= now() - win then
    r.hits := 0;
    r.window_start := now();
  end if;
  r.hits := r.hits + 1;
  if r.hits > max_hits then
    raise exception 'Too many requests. Wait a little and try again.';
  end if;
  update game.rpc_throttle
     set hits = r.hits, window_start = r.window_start, last_at = now()
   where player_id = pid and action = act;
end
$fn$;
revoke all on function game.rate_limit(bigint, text, int, interval, interval) from public, anon, authenticated;

create or replace function game.password_ok(pw text, uname text)
returns void
language plpgsql
immutable
set search_path = ''
as $fn$
declare
  common text[] := array[
    'password','password1','password12','password123','passw0rd','passw0rd1',
    '12345678','123456789','1234567890','12345678901','87654321',
    'qwerty','qwerty1','qwerty12','qwerty123','qwertyui','qwertyuiop',
    'asdfghjk','asdfasdf','zxcvbnm','abc12345','abcd1234','abcdefg','abcdefgh',
    'iloveyou','letmein','letmein1','welcome','welcome1','admin123','admin1234',
    '11111111','00000000','12121212','11223344',
    '1q2w3e4r','q1w2e3r4','1qaz2wsx','qazwsxedc',
    'monkey12','monkey123','dragon12','dragon123','baseball','football',
    'princess','sunshine','shadow12','master12','starwars','trustno1',
    'login','admin','root','changeme','secret','pass1234','pass12345',
    'whatever','superman','michael','jessica','charlie1','charlie12',
    'pokemon','letmein123','welcome123','adminadmin','rootroot',
    'passwort','p@ssw0rd','p@ssword','azerty12','azerty123'
  ];
begin
  if pw is null or char_length(pw) < 8 or char_length(pw) > 72 or octet_length(pw) > 72 then
    raise exception 'Password must be 8-72 characters.';
  end if;
  if trim(pw) = '' or pw ~ '^[[:space:]]+$' then
    raise exception 'Password cannot be only spaces.';
  end if;
  if pw ~ '^(.)\1+$' then
    raise exception 'Please choose a less simple password.';
  end if;
  if uname is not null and lower(pw) = lower(trim(uname)) then
    raise exception 'Password cannot be the same as your username.';
  end if;
  if lower(pw) = any (common) then
    raise exception 'Please choose a less common password.';
  end if;
end
$fn$;
revoke all on function game.password_ok(text, text) from public, anon, authenticated;

create or replace function game.hash_password(pw text)
returns text
language sql
security definer
set search_path = ''
as $fn$
  select extensions.crypt(pw, extensions.gen_salt('bf', 10))
$fn$;
revoke all on function game.hash_password(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Sessions + auth (admin: 2h idle / 12h max; everyone: hashed tokens)
-- ---------------------------------------------------------------------------
create or replace function game.new_session(pid bigint)
returns text
language plpgsql
security definer
set search_path = ''
as $fn$
declare tok text; admin boolean; expiry interval;
begin
  select is_admin into admin from game.players where id = pid;
  expiry := case when admin then interval '12 hours' else interval '7 days' end;
  tok := encode(extensions.gen_random_bytes(32), 'hex');
  insert into game.sessions (token_hash, player_id, expires_at, last_seen)
       values (sha256(convert_to(tok, 'UTF8')), pid, now() + expiry, now());
  delete from game.sessions where expires_at < now() or last_seen < now() - interval '8 days';
  -- Players may keep 5 sessions; admin may keep 2 (shorter, tighter).
  delete from game.sessions where player_id = pid and token_hash not in
    (select token_hash from game.sessions where player_id = pid
      order by created_at desc limit case when admin then 2 else 5 end);
  return tok;
end
$fn$;
revoke all on function game.new_session(bigint) from public, anon, authenticated;

create or replace function game.auth(tok text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $fn$
declare pid bigint; b boolean; admin boolean; created timestamptz; seen timestamptz; exp timestamptz;
begin
  if tok is null or tok !~ '^[0-9a-f]{64}$' then raise exception 'Not logged in.'; end if;
  select s.player_id, p.banned, p.is_admin, s.created_at, s.last_seen, s.expires_at
    into pid, b, admin, created, seen, exp
    from game.sessions s join game.players p on p.id = s.player_id
   where s.token_hash = sha256(convert_to(tok, 'UTF8'));
  if pid is null then raise exception 'Session expired. Please log in again.'; end if;
  if exp <= now() or (admin and (seen < now() - interval '2 hours' or created < now() - interval '12 hours')) then
    delete from game.sessions where token_hash = sha256(convert_to(tok, 'UTF8'));
    raise exception 'Session expired. Please log in again.';
  end if;
  if b then raise exception 'This account has been banned.'; end if;
  -- Global per-player RPC cap (covers every authenticated endpoint).
  perform game.rate_limit(pid, 'rpc', 80, interval '20 seconds', interval '0');
  update game.sessions set last_seen = now()
   where token_hash = sha256(convert_to(tok, 'UTF8'));
  update game.players set last_action = now()
   where id = pid and last_action < now() - interval '30 seconds';
  return pid;
end
$fn$;
revoke all on function game.auth(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Login / register / password / logout
-- ---------------------------------------------------------------------------
create or replace function public.login(p_username text, p_password text, p_device text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  p game.players;
  u text := lower(trim(coalesce(p_username, '')));
  dev text := game.norm_device(p_device);
  k_ud bytea := game.bucket('ud:' || u || ':' || dev);
  k_d bytea := game.bucket('d:' || dev);
  k_u bytea := game.bucket('u:' || u);
  k_ag bytea := game.bucket('admin_g');
  k_ad bytea := game.bucket('admin_d:' || dev);
  generic constant text := 'Login failed. Check your username and password, or wait a few minutes and try again.';
  good boolean;
  aiming_admin boolean := false;
begin
  delete from game.login_throttle
   where window_start < now() - interval '1 day'
     and (blocked_until is null or blocked_until < now());
  if game.soft_fails(k_u) >= 30 then perform pg_sleep(2); end if;

  -- Look up first so we can apply admin caps without changing the generic error.
  select * into p from game.players where lower(username) = u and not is_npc;
  aiming_admin := found and p.is_admin;

  if game.is_blocked(k_d) or game.is_blocked(k_ud)
     or (aiming_admin and (game.is_blocked(k_ag) or game.is_blocked(k_ad))) then
    perform extensions.crypt(coalesce(p_password, ''), extensions.gen_salt('bf', 10));
    return jsonb_build_object('error', generic);
  end if;

  if found and p.pass_hash is not null then
    good := extensions.crypt(coalesce(p_password, ''), p.pass_hash) = p.pass_hash;
  else
    perform extensions.crypt(coalesce(p_password, ''), extensions.gen_salt('bf', 10));
    good := false;
  end if;

  if not good then
    perform game.note_fail(k_ud, 'ud', 5, 5);
    perform game.note_fail(k_d, 'd', 20, 15);
    perform game.note_fail(k_u, 'u', 0, 0);
    if aiming_admin then
      -- Stricter: 3 failures on a device → 15 min (then 45); 8 global failures → 60 min (then 180).
      perform game.note_fail(k_ad, 'admin_d', 3, 15);
      perform game.note_fail(k_ag, 'admin_g', 8, 60);
    end if;
    return jsonb_build_object('error', generic);
  end if;
  if p.banned then
    return jsonb_build_object('error', 'This account has been banned.');
  end if;
  delete from game.login_throttle where key_hash = k_ud;
  if aiming_admin then
    delete from game.login_throttle where key_hash in (k_ad, k_ag);
  end if;
  update game.players set last_action = now() where id = p.id;
  return jsonb_build_object('token', game.new_session(p.id), 'is_admin', p.is_admin);
end
$fn$;

create or replace function public.register(p_username text, p_password text, p_device text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare pid bigint; u text := trim(coalesce(p_username, '')); dev text := game.norm_device(p_device);
  k bytea := game.bucket('reg:' || dev); r game.login_throttle;
begin
  if u !~ '^[A-Za-z0-9_]{3,16}$' then
    raise exception 'Username must be 3-16 characters: letters, numbers or underscore.';
  end if;
  perform game.password_ok(p_password, u);
  if game.reserved_name(u) then raise exception 'That username is not allowed. Please pick another.'; end if;
  insert into game.login_throttle (key_hash, kind) values (k, 'reg_d') on conflict (key_hash) do nothing;
  select * into r from game.login_throttle where key_hash = k for update;
  if r.window_start < now() - interval '1 hour' then r.fails := 0; r.window_start := now(); end if;
  if r.fails >= (case when dev = 'no-device' then 10 else 3 end) then
    raise exception 'Too many new accounts from this device. Try again later.';
  end if;
  if (select count(*) from game.players where not is_npc and created_at > now() - interval '10 minutes') >= 300 then
    raise exception 'Too many new recruits right now. Try again in a few minutes.';
  end if;
  begin
    insert into game.players (username, pass_hash)
    values (u, game.hash_password(p_password))
    returning id into pid;
  exception when unique_violation then
    raise exception 'That username is taken.';
  end;
  update game.login_throttle set fails = r.fails + 1, window_start = r.window_start where key_hash = k;
  perform game.add_event(pid, 'system', 'Welcome to the front, recruit! Train at the camp, run missions and climb the ranks.');
  return jsonb_build_object('token', game.new_session(pid), 'is_admin', false);
end
$fn$;

create or replace function public.change_password(p_token text, p_old text, p_new text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare pid bigint := game.auth(p_token); h text; uname text; admin boolean; tok bytea;
begin
  perform game.rate_limit(pid, 'change_password', 5, interval '15 minutes', interval '2 seconds');
  select username, pass_hash, is_admin into uname, h, admin from game.players where id = pid for update;
  if extensions.crypt(coalesce(p_old, ''), h) <> h then raise exception 'Current password is wrong.'; end if;
  perform game.password_ok(p_new, uname);
  if p_old = p_new then raise exception 'Pick a new password that is different from the current one.'; end if;
  update game.players set pass_hash = game.hash_password(p_new) where id = pid;
  tok := sha256(convert_to(p_token, 'UTF8'));
  if admin then
    -- Admin password change ends every session, including this one.
    delete from game.sessions where player_id = pid;
    perform game.audit(pid, 'change password', pid, jsonb_build_object('sessions_cleared', true));
    return jsonb_build_object('message', 'Password changed. Please log in again.', 'reauth', true);
  end if;
  delete from game.sessions where player_id = pid and token_hash <> tok;
  return jsonb_build_object('message', 'Password changed. Other devices were signed out.', 'reauth', false);
end
$fn$;

create or replace function public.logout(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  if p_token ~ '^[0-9a-f]{64}$' then
    delete from game.sessions where token_hash = sha256(convert_to(p_token, 'UTF8'));
  end if;
  return jsonb_build_object('ok', true);
end
$fn$;

create or replace function public.logout_everywhere(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare pid bigint := game.auth(p_token);
begin
  delete from game.sessions where player_id = pid;
  return jsonb_build_object('message', 'Signed out everywhere. Please log in again.', 'reauth', true);
end
$fn$;

-- ---------------------------------------------------------------------------
-- 7. Hide admin identity in public outputs; audit player-list views
-- ---------------------------------------------------------------------------
create or replace function game.public_player(p game.players)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  select jsonb_build_object(
    'id', p.id,
    'username', case when p.is_admin then 'Command HQ' else p.username end,
    'level', p.level, 'rank', game.rank_title(p.level),
    'npc', p.is_npc,
    'status', case when p.banned then 'Discharged' when p.is_npc then 'Okay' else game.status_of(p.hospital_until, p.jail_until) end,
    'faction', (select jsonb_build_object('id', f.id, 'name', f.name, 'tag', f.tag) from game.factions f where f.id = p.faction_id),
    'force', game.force_class((game.army_power(p.id)->>'power')::numeric),
    'wins', p.wins, 'losses', p.losses, 'joined', p.created_at::date,
    'online', (not p.is_npc and not p.is_admin and p.last_action > now() - interval '15 minutes')
  )
$fn$;
revoke all on function game.public_player(game.players) from public, anon, authenticated;

create or replace function public.get_faction(p_token text, p_faction bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare pid bigint := game.auth(p_token); f game.factions; leader_admin boolean;
begin
  select * into f from game.factions where id = p_faction;
  if not found then raise exception 'Army not found.'; end if;
  select coalesce(is_admin, false) into leader_admin from game.players where id = f.leader_id;
  return jsonb_build_object('id', f.id, 'name', f.name, 'tag', f.tag, 'description', f.description,
    'leader_id', case when leader_admin then null else f.leader_id end,
    'leader', (select case when is_admin then 'Command HQ' else username end from game.players where id = f.leader_id),
    'created_at', f.created_at::date,
    'members', coalesce((select jsonb_agg(game.public_player(p) order by p.level desc)
                           from game.players p where p.faction_id = f.id and not p.is_admin), '[]'::jsonb));
end
$fn$;

create or replace function public.admin_list_players(p_token text, p_search text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare pid bigint := game.auth(p_token); q text := nullif(regexp_replace(coalesce(p_search, ''), '[^A-Za-z0-9_]', '', 'g'), '');
begin
  perform game.require_admin(pid);
  perform game.rate_limit(pid, 'admin_list', 30, interval '5 minutes', interval '1 second');
  perform game.audit(pid, 'list players', null, jsonb_build_object('search', coalesce(q, '')));
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'username', username, 'level', level, 'cash', cash,
            'bank', bank, 'banned', banned, 'is_admin', is_admin, 'npc', is_npc, 'wins', wins, 'losses', losses,
            'created_at', created_at, 'last_action', last_action) order by id)
     from (select * from game.players where q is null or username ilike '%' || q || '%' order by id limit 200) x), '[]'::jsonb);
end
$fn$;

-- ---------------------------------------------------------------------------
-- 8. Write-path rate limits (bank, founding an army)
-- ---------------------------------------------------------------------------
create or replace function public.bank_deposit(p_token text, p_amount bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare pid bigint := game.auth(p_token); p game.players; fee bigint;
begin
  perform game.rate_limit(pid, 'bank', 30, interval '5 minutes', interval '1 second');
  if p_amount is null or p_amount < 1 then raise exception 'Enter a positive amount.'; end if;
  p := game.tick(pid);
  if p.cash < p_amount then raise exception 'You only have $% in cash.', p.cash; end if;
  fee := ceil(p_amount * 0.01);
  update game.players set cash = cash - p_amount, bank = bank + (p_amount - fee) where id = pid;
  return jsonb_build_object('message', format('Deposited $%s (fee $%s).', p_amount - fee, fee), 'me', game.me_json(pid));
end
$fn$;

create or replace function public.bank_withdraw(p_token text, p_amount bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare pid bigint := game.auth(p_token); p game.players;
begin
  perform game.rate_limit(pid, 'bank', 30, interval '5 minutes', interval '1 second');
  if p_amount is null or p_amount < 1 then raise exception 'Enter a positive amount.'; end if;
  p := game.tick(pid);
  if p.bank < p_amount then raise exception 'You only have $% in the bank.', p.bank; end if;
  update game.players set cash = cash + p_amount, bank = bank - p_amount where id = pid;
  return jsonb_build_object('message', format('Withdrew $%s.', p_amount), 'me', game.me_json(pid));
end
$fn$;

create or replace function public.create_faction(p_token text, p_name text, p_tag text, p_description text default '')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare pid bigint := game.auth(p_token); p game.players; n text := trim(coalesce(p_name, '')); t text := upper(trim(coalesce(p_tag, '')));
  d text := left(trim(regexp_replace(coalesce(p_description, ''), '[[:cntrl:]]', ' ', 'g')), 300); fid bigint;
begin
  perform game.rate_limit(pid, 'create_faction', 3, interval '1 hour', interval '10 seconds');
  if n !~ '^[A-Za-z0-9 _-]{3,24}$' then raise exception 'Army name must be 3-24 letters, numbers, spaces, - or _.'; end if;
  if t !~ '^[A-Z0-9]{2,5}$' then raise exception 'Tag must be 2-5 letters or numbers.'; end if;
  p := game.tick(pid);
  if p.faction_id is not null then raise exception 'Leave your current army first.'; end if;
  if p.cash < 10000 then raise exception 'Founding an army costs $10,000 in cash.'; end if;
  begin
    insert into game.factions (name, tag, description, leader_id) values (n, t, d, pid) returning id into fid;
  exception when unique_violation then raise exception 'That army name or tag is taken.'; end;
  update game.players set cash = cash - 10000, faction_id = fid where id = pid;
  perform game.add_event(pid, 'faction', format('You founded the army %s [%s].', n, t));
  return jsonb_build_object('message', format('Army %s [%s] founded.', n, t), 'id', fid);
end
$fn$;

-- ---------------------------------------------------------------------------
-- 9. Attack: uniform target errors + rate limit (body otherwise unchanged)
-- ---------------------------------------------------------------------------
create or replace function public.attack(p_token text, p_target bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  pid bigint := game.auth(p_token);
  a game.players; d game.players;
  a_w text; a_wp int := 0; a_ap int := 0;
  d_w text; d_wp int := 0; d_ap int := 0;
  a_hp int; d_hp int; a_max int; d_max int;
  v_log text[] := '{}';
  r int; s int; a_first boolean; atk_is_a boolean;
  chance numeric; dmg int; crit boolean;
  a_disp text; outcome text; v_cash bigint := 0; v_xp int := 0; mins int; msg text;
  a_army jsonb; d_army jsonb; fa numeric; fd numeric;
  a_lp numeric; d_lp numeric; a_w1 int; a_w2 int; d_w1 int; d_w2 int; a_lost int := 0; d_lost int := 0; d_note text := '';
begin
  perform game.rate_limit(pid, 'attack', 8, interval '5 minutes', interval '3 seconds');
  if p_target is null or p_target = pid then raise exception 'You cannot attack yourself.'; end if;
  -- Same error for missing, banned and admin targets so IDs cannot be enumerated.
  if not exists (select 1 from game.players where id = p_target and not banned and not is_admin) then
    raise exception 'That target is not available.';
  end if;
  -- lock both rows in a fixed order to avoid deadlocks / double-spends
  if pid < p_target then a := game.tick(pid); d := game.tick(p_target);
  else d := game.tick(p_target); a := game.tick(pid); end if;

  perform game.require_free(a);
  a_disp := case when a.is_admin then 'Command HQ' else a.username end;
  if a.energy < 25 then raise exception 'Attacking costs 25 energy (you have %).', a.energy; end if;
  a_max := game.max_hp(a.level); d_max := game.max_hp(d.level);
  if a.hp < ceil(a_max * 0.2) then raise exception 'You are too wounded to fight. Rest or visit the hospital.'; end if;
  if d.banned or d.is_admin then raise exception 'That target is not available.'; end if;
  if not d.is_npc then
    if d.level < 3 then raise exception 'New recruits below level 3 are protected.'; end if;
    if d.hospital_until is not null then raise exception '% is already in the hospital.', d.username; end if;
    if d.jail_until is not null then raise exception '% is held in the stockade.', d.username; end if;
    if exists (select 1 from game.attacks where attacker_id = pid and defender_id = p_target
                and created_at > now() - interval '10 minutes') then
      raise exception 'You attacked % recently. Wait for the 10 minute cooldown.', d.username;
    end if;
  end if;

  select name, power into a_w, a_wp from game.items where id = a.weapon_id;
  select power into a_ap from game.items where id = a.armor_id;
  select name, power into d_w, d_wp from game.items where id = d.weapon_id;
  select power into d_ap from game.items where id = d.armor_id;
  a_wp := coalesce(a_wp, 0); a_ap := coalesce(a_ap, 0); d_wp := coalesce(d_wp, 0); d_ap := coalesce(d_ap, 0);
  a_w := coalesce(a_w, 'bare fists'); d_w := coalesce(d_w, 'bare fists');

  -- Army Command: army power scales damage between x0.6 and x1.5
  a_army := game.army_power(a.id); d_army := game.army_power(d.id);
  fa := least(1.5, greatest(0.6, 1 + 0.5 * ((a_army->>'attack')::numeric - (d_army->>'defense')::numeric)
                                      / ((a_army->>'attack')::numeric + (d_army->>'defense')::numeric + 200)));
  fd := least(1.5, greatest(0.6, 1 + 0.5 * ((d_army->>'attack')::numeric - (a_army->>'defense')::numeric)
                                      / ((d_army->>'attack')::numeric + (a_army->>'defense')::numeric + 200)));

  a_hp := a.hp; d_hp := case when d.is_npc then d_max else d.hp end;
  a_first := a.spd * (0.8 + random() * 0.4) >= d.spd * (0.8 + random() * 0.4);
  v_log := v_log || format('%s engages %s. %s moves first.', a_disp, d.username,
                       case when a_first then a_disp else d.username end);
  v_log := v_log || format('Forces: %s leads a %s, %s leads a %s. Army support: %s damage x%s, %s damage x%s.',
                           a_disp, game.force_class((a_army->>'power')::numeric), d.username, game.force_class((d_army->>'power')::numeric),
                           a_disp, round(fa, 2), d.username, round(fd, 2));

  <<rounds>>
  for r in 1..12 loop
    for s in 0..1 loop
      atk_is_a := (s = 0) = a_first;
      if atk_is_a then
        chance := least(0.95, greatest(0.25, a.spd / (a.spd + d.dex) * 1.1 + 0.05));
        if random() < chance then
          crit := random() < 0.15;
          dmg := greatest(1, round((10 + a.str * 0.8 + a_wp) * (0.8 + random() * 0.4)
                         * (100.0 / (100.0 + d.def * 0.5 + d_ap * 2)) * case when crit then 1.5 else 1 end * fa));
          d_hp := greatest(0, d_hp - dmg);
          v_log := v_log || format('R%s: %s hits %s with %s for %s%s. (%s HP left)', r, a_disp, d.username, a_w, dmg,
                               case when crit then ' (critical!)' else '' end, d_hp);
        else
          v_log := v_log || format('R%s: %s attacks with %s but %s evades.', r, a_disp, a_w, d.username);
        end if;
      else
        chance := least(0.95, greatest(0.25, d.spd / (d.spd + a.dex) * 1.1 + 0.05));
        if random() < chance then
          crit := random() < 0.15;
          dmg := greatest(1, round((10 + d.str * 0.8 + d_wp) * (0.8 + random() * 0.4)
                         * (100.0 / (100.0 + a.def * 0.5 + a_ap * 2)) * case when crit then 1.5 else 1 end * fd));
          a_hp := greatest(0, a_hp - dmg);
          v_log := v_log || format('R%s: %s hits %s with %s for %s%s. (%s HP left)', r, d.username, a_disp, d_w, dmg,
                               case when crit then ' (critical!)' else '' end, a_hp);
        else
          v_log := v_log || format('R%s: %s attacks with %s but %s evades.', r, d.username, d_w, a_disp);
        end if;
      end if;
      exit rounds when a_hp <= 0 or d_hp <= 0;
    end loop;
  end loop;

  -- Command Powers
  if a.god_strike and d_hp > 0 then
    d_hp := 0; a_hp := greatest(a_hp, 1);
    v_log := v_log || format('GOD STRIKE: Command artillery obliterates %s.', d.username);
  end if;
  if a.immortal and a_hp <= 0 then
    a_hp := 1;
    v_log := v_log || format('%s is shielded by Command immunity and withdraws.', a_disp);
  end if;

  if d_hp <= 0 then
    outcome := 'win';
    v_xp := 10 + d.level * 8;
    if d.is_npc then
      v_cash := d.level * 40 + floor(random() * (d.level * 20 + 1))::bigint;
    else
      v_cash := floor(d.cash * (0.03 + random() * 0.05))::bigint;
      mins := 5 + floor(random() * 6)::int + d.level / 4;
      update game.players set hp = 0, cash = cash - v_cash, losses = losses + 1,
        hospital_until = now() + make_interval(mins => mins) where id = d.id;
      perform game.add_event(d.id, 'battle', format('%s attacked you and won. You lost $%s and were hospitalized for %s minutes.', a_disp, v_cash, mins));
    end if;
    update game.players set hp = a_hp, energy = energy - 25, cash = cash + v_cash, wins = wins + 1,
      energy_at = case when energy >= 100 then now() else energy_at end,
      hp_at = case when hp >= a_max then now() else hp_at end where id = pid;
    perform game.add_xp(pid, v_xp);
    msg := format('Victory over %s! You took $%s and earned %s XP.', d.username, v_cash, v_xp);
    v_log := v_log || format('%s is defeated.', d.username);
  elsif a_hp <= 0 then
    outcome := 'loss';
    mins := 5 + floor(random() * 6)::int + a.level / 4;
    update game.players set hp = 0, energy = energy - 25, losses = losses + 1,
      energy_at = case when energy >= 100 then now() else energy_at end,
      hospital_until = now() + make_interval(mins => mins) where id = pid;
    if not d.is_npc then
      update game.players set hp = d_hp, wins = wins + 1,
        hp_at = case when hp >= d_max then now() else hp_at end where id = d.id;
      perform game.add_xp(d.id, 5 + a.level * 2);
      perform game.add_event(d.id, 'battle', format('%s attacked you and lost. You held your ground!', a_disp));
    end if;
    msg := format('Defeat. %s beat you and you were hospitalized for %s minutes.', d.username, mins);
    v_log := v_log || format('%s is defeated.', a_disp);
  else
    outcome := 'stalemate';
    update game.players set hp = a_hp, energy = energy - 25,
      energy_at = case when energy >= 100 then now() else energy_at end,
      hp_at = case when hp >= a_max then now() else hp_at end where id = pid;
    if not d.is_npc then
      update game.players set hp = d_hp, hp_at = case when hp >= d_max then now() else hp_at end where id = d.id;
      perform game.add_event(d.id, 'battle', format('%s attacked you but withdrew after a stalemate.', a_disp));
    end if;
    msg := format('Stalemate. Neither side broke, and you withdrew from %s.', d.username);
    v_log := v_log || 'Both sides withdraw.'::text;
  end if;

  -- Casualties and vehicle wear (NPC forces always regroup)
  if outcome = 'win' then a_lp := 0.01 + random() * 0.03; d_lp := 0.06 + random() * 0.06; a_w1 := 1; a_w2 := 5; d_w1 := 4; d_w2 := 10;
  elsif outcome = 'loss' then a_lp := 0.06 + random() * 0.06; d_lp := 0.01 + random() * 0.03; a_w1 := 4; a_w2 := 10; d_w1 := 1; d_w2 := 5;
  else a_lp := 0.02 + random() * 0.03; d_lp := 0.02 + random() * 0.03; a_w1 := 2; a_w2 := 6; d_w1 := 2; d_w2 := 6; end if;
  if a.immortal or a.god_strike then a_lp := 0; a_w1 := 0; a_w2 := 0; end if;
  a_lost := floor(a.troops * a_lp);
  update game.players set troops = greatest(0, troops - a_lost) where id = a.id;
  update game.player_vehicles set condition = greatest(0, condition - (a_w1 + floor(random() * (a_w2 - a_w1 + 1)))::int) where player_id = a.id;
  if a.troops > 0 or (a_army->>'vehicles')::int > 0 then
    v_log := v_log || format('Casualties: %s lost %s troops%s.', a_disp, a_lost,
                             case when (a_army->>'vehicles')::int > 0 then format(' and vehicles took %s-%s%% wear', a_w1, a_w2) else '' end);
  end if;
  if not d.is_npc then
    d_lost := floor(d.troops * d_lp);
    update game.players set troops = greatest(0, troops - d_lost) where id = d.id;
    update game.player_vehicles set condition = greatest(0, condition - (d_w1 + floor(random() * (d_w2 - d_w1 + 1)))::int) where player_id = d.id;
    if d_lost > 0 then d_note := format(' You lost %s troops.', d_lost); end if;
    if d.troops > 0 then
      v_log := v_log || format('%s suffered %s casualties.', d.username, case when d_lp >= 0.06 then 'heavy' else 'light' end);
    end if;
    update game.events set message = message || d_note
     where id = (select max(id) from game.events where player_id = d.id and kind = 'battle');
  end if;
  if a_lost > 0 then msg := msg || format(' You lost %s troops.', a_lost); end if;

  insert into game.attacks (attacker_id, defender_id, result) values (pid, d.id, outcome);
  perform game.add_event(pid, 'battle', msg);
  return jsonb_build_object('result', outcome, 'message', msg, 'log', to_jsonb(v_log),
                            'cash', v_cash, 'xp', v_xp, 'me', game.me_json(pid));
end $function$;

-- ---------------------------------------------------------------------------
-- 10. Lock the API: revoke everything, grant only the game RPCs to anon
-- ---------------------------------------------------------------------------
revoke all on all tables in schema game from public, anon, authenticated;
revoke all on all sequences in schema game from public, anon, authenticated;
revoke all on all functions in schema game from public, anon, authenticated;
revoke all on all tables in schema public from public, anon, authenticated;
revoke all on all sequences in schema public from public, anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;

alter default privileges in schema game revoke all on tables from public, anon, authenticated;
alter default privileges in schema game revoke all on sequences from public, anon, authenticated;
alter default privileges in schema game revoke all on functions from public, anon, authenticated;
alter default privileges in schema public revoke all on tables from public, anon, authenticated;
alter default privileges in schema public revoke all on sequences from public, anon, authenticated;
alter default privileges in schema public revoke all on functions from public, anon, authenticated;

do $g$
declare
  fn text;
  fns text[] := array[
    'login','register','logout','logout_everywhere','change_password',
    'get_me','get_profile','get_chat','send_chat','get_events','get_army','get_faction',
    'list_factions','list_players','list_targets','list_items','list_missions','leaderboard','hospital_list',
    'attack','train','spend_stats','do_mission',
    'bank_deposit','bank_withdraw',
    'buy_item','sell_item','equip_item','unequip_item',
    'buy_troop_weapon','sell_troop_weapon','buy_vehicle','sell_vehicle','repair_vehicle','repair_all_vehicles',
    'recruit_troops','dismiss_troops',
    'create_faction','join_faction','leave_faction',
    'pay_bail','revive',
    'admin_adjust_cash','admin_announce','admin_audit_log_list','admin_command_order',
    'admin_get_player','admin_list_players','admin_power_grant','admin_power_refill',
    'admin_power_release','admin_power_set_stats','admin_power_toggle','admin_recent_events',
    'admin_reset_player','admin_set_ban'
  ];
begin
  foreach fn in array fns loop
    execute format('grant execute on function public.%I to anon', fn);
  end loop;
  grant execute on all functions in schema public to service_role;
end
$g$;

-- GraphQL: the extension is disabled, but revoke anyway so anon cannot probe the schema.
do $gql$
begin
  revoke usage on schema graphql_public from public, anon, authenticated;
  revoke usage on schema graphql from public, anon, authenticated;
  revoke all on all functions in schema graphql_public from public, anon, authenticated;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'graphql_public' and p.proname = 'graphql') then
    revoke all on function graphql_public.graphql(text, text, jsonb, jsonb) from public, anon, authenticated;
  end if;
exception when insufficient_privilege or undefined_function or invalid_schema_name then
  raise notice 'graphql revoke skipped: %', sqlerrm;
end
$gql$;

-- Storage: this game uses no buckets. Revoke table privileges from public roles.
do $st$
begin
  revoke all on all tables in schema storage from public, anon, authenticated;
  revoke all on all sequences in schema storage from public, anon, authenticated;
  revoke all on all functions in schema storage from public, anon, authenticated;
exception when insufficient_privilege then
  raise notice 'storage revoke skipped: %', sqlerrm;
end
$st$;

-- pgcrypto should not be callable by anon even if the extensions schema is ever exposed.
do $ext$
begin
  revoke all on all functions in schema extensions from public, anon, authenticated;
exception when insufficient_privilege then
  raise notice 'extensions revoke skipped: %', sqlerrm;
end
$ext$;

-- Best-effort: hide OpenAPI from the authenticator role (hosted projects may ignore this;
-- the gateway already rejects OpenAPI without the service_role key).
do $oa$
begin
  execute $cmd$alter role authenticator set pgrst.openapi_mode = 'disabled'$cmd$;
  perform pg_notify('pgrst', 'reload config');
exception when others then
  raise notice 'openapi_mode not set: %', sqlerrm;
end
$oa$;

-- Defense in depth: reject any row inserted into auth.users (this game does not use Supabase Auth).
-- Signups should also be disabled in the dashboard (Authentication -> Providers -> Email).
do $auth$
begin
  execute $t$
    create or replace function auth.reject_new_users()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
    as $f$
    begin
      raise exception 'Signups are disabled.';
    end
    $f$;
  $t$;
  execute 'drop trigger if exists reject_new_users on auth.users';
  execute 'create trigger reject_new_users before insert on auth.users for each row execute function auth.reject_new_users()';
  execute 'revoke all on function auth.reject_new_users() from public, anon, authenticated';
exception when others then
  raise notice 'auth signup trigger not installed: %', sqlerrm;
end
$auth$;
