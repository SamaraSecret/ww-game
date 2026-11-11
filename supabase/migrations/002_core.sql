-- Internal helper functions (schema "game", not callable by API roles).

create or replace function game.max_hp(lvl int) returns int
language sql immutable set search_path = '' as $$ select 100 + (lvl - 1) * 20 $$;

-- Total XP needed to advance from level lvl to lvl+1 (cumulative).
create or replace function game.xp_for(lvl int) returns bigint
language sql immutable set search_path = '' as $$ select (50 * lvl * lvl)::bigint $$;

create or replace function game.rank_title(lvl int) returns text
language sql immutable set search_path = '' as $$
  select case
    when lvl >= 50 then 'Field Marshal'
    when lvl >= 40 then 'General'
    when lvl >= 30 then 'Brigadier'
    when lvl >= 25 then 'Colonel'
    when lvl >= 20 then 'Major'
    when lvl >= 15 then 'Captain'
    when lvl >= 11 then 'Lieutenant'
    when lvl >= 8  then 'Sergeant'
    when lvl >= 5  then 'Corporal'
    when lvl >= 3  then 'Private'
    else 'Recruit' end $$;

create or replace function game.status_of(h timestamptz, j timestamptz) returns text
language sql stable set search_path = '' as $$
  select case when h is not null and h > now() then 'Hospital'
              when j is not null and j > now() then 'Stockade'
              else 'Okay' end $$;

create or replace function game.add_event(pid bigint, k text, msg text) returns void
language sql security definer set search_path = '' as $$
  insert into game.events (player_id, kind, message) values (pid, k, msg) $$;

-- Lock a player row (FOR UPDATE) and apply lazy regeneration from timestamps.
create or replace function game.tick(pid bigint) returns game.players
language plpgsql security definer set search_path = '' as $$
declare
  p game.players;
  n int;
  mx int;
  t timestamptz := now();
begin
  select * into p from game.players where id = pid for update;
  if not found then raise exception 'Player not found.'; end if;
  mx := game.max_hp(p.level);

  -- Energy: +5 every 5 minutes, max 100
  if p.energy >= 100 then p.energy_at := t;
  else
    n := floor(extract(epoch from (t - p.energy_at)) / 300);
    if n > 0 then
      p.energy := least(100, p.energy + n * 5);
      p.energy_at := case when p.energy >= 100 then t else p.energy_at + make_interval(secs => n * 300) end;
    end if;
  end if;

  -- Nerve: +1 every 5 minutes, max 10
  if p.nerve >= 10 then p.nerve_at := t;
  else
    n := floor(extract(epoch from (t - p.nerve_at)) / 300);
    if n > 0 then
      p.nerve := least(10, p.nerve + n);
      p.nerve_at := case when p.nerve >= 10 then t else p.nerve_at + make_interval(secs => n * 300) end;
    end if;
  end if;

  if p.jail_until is not null and p.jail_until <= t then p.jail_until := null; end if;

  -- Health
  if p.is_npc then
    p.hp := mx; p.hp_at := t; p.hospital_until := null;
  elsif p.hospital_until is not null then
    if p.hospital_until <= t then
      p.hospital_until := null; p.hp := mx; p.hp_at := t;   -- discharged at full health
    else
      p.hp_at := t;
    end if;
  elsif p.hp >= mx then
    p.hp := mx; p.hp_at := t;
  else
    n := floor(extract(epoch from (t - p.hp_at)) / 300);  -- +10% max HP every 5 minutes
    if n > 0 then
      p.hp := least(mx, p.hp + n * ceil(mx * 0.1)::int);
      p.hp_at := case when p.hp >= mx then t else p.hp_at + make_interval(secs => n * 300) end;
    end if;
  end if;

  update game.players set
    energy = p.energy, energy_at = p.energy_at, nerve = p.nerve, nerve_at = p.nerve_at,
    hp = p.hp, hp_at = p.hp_at, hospital_until = p.hospital_until, jail_until = p.jail_until
  where id = pid;
  return p;
end $$;

-- Resolve a session token to a player id. Raises if invalid, expired or banned.
create or replace function game.auth(tok text) returns bigint
language plpgsql security definer set search_path = '' as $$
declare pid bigint; b boolean;
begin
  if tok is null or tok !~ '^[0-9a-f]{64}$' then raise exception 'Not logged in.'; end if;
  select s.player_id, p.banned into pid, b
    from game.sessions s join game.players p on p.id = s.player_id
   where s.token_hash = sha256(convert_to(tok, 'UTF8')) and s.expires_at > now();
  if pid is null then raise exception 'Session expired. Please log in again.'; end if;
  if b then raise exception 'This account has been banned.'; end if;
  update game.players set last_action = now() where id = pid and last_action < now() - interval '30 seconds';
  return pid;
end $$;

create or replace function game.require_free(p game.players) returns void
language plpgsql stable set search_path = '' as $$
begin
  if p.hospital_until is not null and p.hospital_until > now() then
    raise exception 'You are in the field hospital for another % minute(s).', ceil(extract(epoch from (p.hospital_until - now())) / 60);
  end if;
  if p.jail_until is not null and p.jail_until > now() then
    raise exception 'You are held in the stockade for another % minute(s).', ceil(extract(epoch from (p.jail_until - now())) / 60);
  end if;
end $$;

create or replace function game.require_admin(pid bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from game.players where id = pid and is_admin and not banned) then
    raise exception 'Access denied: Command Staff only.';
  end if;
end $$;

-- Add XP and handle level-ups. Returns number of levels gained.
create or replace function game.add_xp(pid bigint, amt bigint) returns int
language plpgsql security definer set search_path = '' as $$
declare lvl int; x bigint; gained int := 0;
begin
  update game.players set xp = xp + greatest(amt, 0) where id = pid returning level, xp into lvl, x;
  while x >= game.xp_for(lvl) and lvl < 100 loop
    lvl := lvl + 1; gained := gained + 1;
  end loop;
  if gained > 0 then
    update game.players set level = lvl,
      hp = case when hospital_until is null then game.max_hp(lvl) else hp end
     where id = pid;
    perform game.add_event(pid, 'promotion', format('Promoted to level %s (%s)!', lvl, game.rank_title(lvl)));
  end if;
  return gained;
end $$;

create or replace function game.new_session(pid bigint) returns text
language plpgsql security definer set search_path = '' as $$
declare tok text;
begin
  tok := encode(extensions.gen_random_bytes(32), 'hex');
  insert into game.sessions (token_hash, player_id, expires_at)
       values (sha256(convert_to(tok, 'UTF8')), pid, now() + interval '7 days');
  delete from game.sessions where expires_at < now();
  delete from game.sessions where player_id = pid and token_hash not in
    (select token_hash from game.sessions where player_id = pid order by created_at desc limit 5);
  return tok;
end $$;

-- Full private state of the calling player (only ever returned to that player).
create or replace function game.me_json(pid bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id, 'username', p.username, 'is_admin', p.is_admin,
    'level', p.level, 'rank', game.rank_title(p.level),
    'xp', p.xp, 'xp_prev', case when p.level = 1 then 0 else game.xp_for(p.level - 1) end, 'xp_next', game.xp_for(p.level),
    'cash', p.cash, 'bank', p.bank,
    'hp', p.hp, 'max_hp', game.max_hp(p.level),
    'energy', p.energy, 'max_energy', 100, 'nerve', p.nerve, 'max_nerve', 10,
    'energy_next', case when p.energy >= 100 then null else greatest(0, 300 - extract(epoch from (now() - p.energy_at)))::int end,
    'nerve_next', case when p.nerve >= 10 then null else greatest(0, 300 - extract(epoch from (now() - p.nerve_at)))::int end,
    'str', p.str, 'def', p.def, 'spd', p.spd, 'dex', p.dex, 'total', p.str + p.def + p.spd + p.dex,
    'weapon', (select jsonb_build_object('id', i.id, 'name', i.name, 'power', i.power) from game.items i where i.id = p.weapon_id),
    'armor', (select jsonb_build_object('id', i.id, 'name', i.name, 'power', i.power) from game.items i where i.id = p.armor_id),
    'status', game.status_of(p.hospital_until, p.jail_until),
    'hospital_until', case when p.hospital_until > now() then p.hospital_until end,
    'jail_until', case when p.jail_until > now() then p.jail_until end,
    'faction', (select jsonb_build_object('id', f.id, 'name', f.name, 'tag', f.tag, 'leader', f.leader_id = p.id) from game.factions f where f.id = p.faction_id),
    'wins', p.wins, 'losses', p.losses, 'missions_done', p.missions_done,
    'server_time', now()
  ) from game.players p where p.id = pid $$;

revoke all on all functions in schema game from public, anon, authenticated;
