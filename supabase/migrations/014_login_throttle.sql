-- Login throttling that a stranger cannot use to lock out the real owner.
-- Buckets are keyed by SHA-256 hashes: (username + device), device, username. No IPs are stored.
--  * username+device: 5 failures in 15 min  -> that device is blocked for that username (5 min, then 15 min)
--  * device (global): 20 failures in 15 min -> that device is blocked for every login (15 min)
--  * username (soft): 30 failures in 15 min -> every attempt for that username waits 2 seconds (never blocked)
-- Unknown usernames are throttled exactly like real ones, and every failure returns the same message.

create table if not exists game.login_throttle (
  key_hash bytea primary key,
  kind text not null check (kind in ('ud','d','u','reg_d')),
  fails int not null default 0,
  window_start timestamptz not null default now(),
  strikes int not null default 0,
  blocked_until timestamptz
);
alter table game.login_throttle enable row level security;
revoke all on table game.login_throttle from public, anon, authenticated;

-- Players no longer carry a hard per-account lock.
update game.players set failed_logins = 0, locked_until = null;

create or replace function game.bucket(k text) returns bytea
language sql immutable set search_path = '' as $$ select sha256(convert_to(k, 'UTF8')) $$;

create or replace function game.norm_device(d text) returns text
language sql immutable set search_path = '' as $$
  select case when d ~ '^[0-9a-f]{32,64}$' then d else 'no-device' end $$;

-- Is this bucket currently blocked?
create or replace function game.is_blocked(k bytea) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from game.login_throttle where key_hash = k and blocked_until > now()) $$;

-- Record a failure; block when the threshold is reached (progressive: 5 min, then 15 min).
create or replace function game.note_fail(k bytea, kd text, threshold int, base_minutes int) returns void
language plpgsql security definer set search_path = '' as $$
declare r game.login_throttle;
begin
  insert into game.login_throttle (key_hash, kind) values (k, kd) on conflict (key_hash) do nothing;
  select * into r from game.login_throttle where key_hash = k for update;
  if r.window_start < now() - interval '15 minutes' then
    r.fails := 0; r.window_start := now();
    if r.blocked_until is null or r.blocked_until < now() - interval '1 hour' then r.strikes := 0; end if;
  end if;
  r.fails := r.fails + 1;
  if threshold > 0 and r.fails >= threshold then
    r.strikes := r.strikes + 1;
    r.blocked_until := now() + make_interval(mins => base_minutes * case when r.strikes > 1 then 3 else 1 end);
    r.fails := 0; r.window_start := now();
  end if;
  update game.login_throttle set fails = r.fails, window_start = r.window_start, strikes = r.strikes,
         blocked_until = r.blocked_until where key_hash = k;
end $$;

create or replace function game.soft_fails(k bytea) returns int
language sql stable security definer set search_path = '' as $$
  select coalesce((select fails from game.login_throttle where key_hash = k and window_start > now() - interval '15 minutes'), 0) $$;

revoke all on all functions in schema game from public, anon, authenticated;

drop function if exists public.login(text, text);
drop function if exists public.register(text, text);

create or replace function public.login(p_username text, p_password text, p_device text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p game.players;
  u text := lower(trim(coalesce(p_username, '')));
  dev text := game.norm_device(p_device);
  k_ud bytea := game.bucket('ud:' || u || ':' || dev);
  k_d bytea := game.bucket('d:' || dev);
  k_u bytea := game.bucket('u:' || u);
  generic constant text := 'Login failed. Check your username and password, or wait a few minutes and try again.';
  good boolean;
begin
  delete from game.login_throttle where window_start < now() - interval '1 day' and (blocked_until is null or blocked_until < now());
  -- Soft cap per username: slow down, never block.
  if game.soft_fails(k_u) >= 30 then perform pg_sleep(2); end if;
  -- Blocked device, or blocked (username, device) pair: same generic answer, no password check.
  if game.is_blocked(k_d) or game.is_blocked(k_ud) then
    perform extensions.crypt(coalesce(p_password, ''), extensions.gen_salt('bf', 8));
    return jsonb_build_object('error', generic);
  end if;
  select * into p from game.players where lower(username) = u and not is_npc;
  if found and p.pass_hash is not null then
    good := extensions.crypt(coalesce(p_password, ''), p.pass_hash) = p.pass_hash;
  else
    perform extensions.crypt(coalesce(p_password, ''), extensions.gen_salt('bf', 8)); -- similar timing
    good := false;
  end if;
  if not good then
    perform game.note_fail(k_ud, 'ud', 5, 5);
    perform game.note_fail(k_d, 'd', 20, 15);
    perform game.note_fail(k_u, 'u', 0, 0);
    return jsonb_build_object('error', generic);
  end if;
  if p.banned then
    return jsonb_build_object('error', 'This account has been banned.');
  end if;
  delete from game.login_throttle where key_hash = k_ud;
  update game.players set last_action = now() where id = p.id;
  return jsonb_build_object('token', game.new_session(p.id), 'is_admin', p.is_admin);
end $$;

-- Registration: max 3 accounts per device per hour, and a high global cap (300 per 10 minutes).
create or replace function public.register(p_username text, p_password text, p_device text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint; u text := trim(coalesce(p_username, '')); dev text := game.norm_device(p_device);
  k bytea := game.bucket('reg:' || dev); r game.login_throttle;
begin
  if u !~ '^[A-Za-z0-9_]{3,16}$' then
    raise exception 'Username must be 3-16 characters: letters, numbers or underscore.';
  end if;
  if p_password is null or length(p_password) < 6 or length(p_password) > 72 then
    raise exception 'Password must be 6-72 characters.';
  end if;
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
    values (u, extensions.crypt(p_password, extensions.gen_salt('bf', 8)))
    returning id into pid;
  exception when unique_violation then
    raise exception 'That username is taken.';
  end;
  update game.login_throttle set fails = r.fails + 1, window_start = r.window_start where key_hash = k;
  perform game.add_event(pid, 'system', 'Welcome to the front, recruit! Train at the camp, run missions and climb the ranks.');
  return jsonb_build_object('token', game.new_session(pid), 'is_admin', false);
end $$;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on all functions in schema public to anon, authenticated;
