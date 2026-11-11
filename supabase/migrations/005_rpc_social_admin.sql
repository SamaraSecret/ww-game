-- Public RPCs: players, profiles, leaderboards, events, chat, factions, admin.
-- Other players only ever see PUBLIC info: username, level, rank, faction, status, wins/losses, join date.

create or replace function game.public_player(p game.players) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id, 'username', p.username, 'level', p.level, 'rank', game.rank_title(p.level),
    'npc', p.is_npc, 'staff', p.is_admin,
    'status', case when p.banned then 'Discharged' when p.is_npc then 'Okay' else game.status_of(p.hospital_until, p.jail_until) end,
    'faction', (select jsonb_build_object('id', f.id, 'name', f.name, 'tag', f.tag) from game.factions f where f.id = p.faction_id),
    'wins', p.wins, 'losses', p.losses, 'joined', p.created_at::date,
    'online', (not p.is_npc and p.last_action > now() - interval '15 minutes')
  ) $$;
revoke all on function game.public_player(game.players) from public, anon, authenticated;

create or replace function public.list_players(p_token text, p_search text default null, p_page int default 0) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); q text := nullif(trim(coalesce(p_search, '')), '');
begin
  if q is not null then q := regexp_replace(q, '[^A-Za-z0-9_ ]', '', 'g'); end if;
  return coalesce((select jsonb_agg(game.public_player(x) order by x.level desc, x.id) from (
      select * from game.players p
       where (q is null or p.username ilike '%' || q || '%')
       order by p.level desc, p.id
       limit 25 offset greatest(0, least(coalesce(p_page, 0), 1000)) * 25) x), '[]'::jsonb);
end $$;

create or replace function public.get_profile(p_token text, p_player bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players;
begin
  select * into p from game.players where id = p_player;
  if not found then raise exception 'Soldier not found.'; end if;
  return game.public_player(p);
end $$;

create or replace function public.leaderboard(p_token text, p_kind text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token);
begin
  if p_kind not in ('level','wins','stats','wealth') then raise exception 'Unknown leaderboard.'; end if;
  -- For 'stats' and 'wealth' only the ORDER is public; exact numbers stay private.
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'username', username, 'level', level,
          'rank', game.rank_title(level), 'value', case p_kind when 'level' then level when 'wins' then wins else null end)
          order by pos) from (
      select id, username, level, wins, row_number() over (order by
          case p_kind when 'level' then level::numeric when 'wins' then wins::numeric
                      when 'stats' then (str + def + spd + dex) else (cash + bank)::numeric end desc, xp desc, id) as pos
        from game.players where not is_npc and not is_admin and not banned) r where pos <= 20), '[]'::jsonb);
end $$;

create or replace function public.get_events(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); res jsonb;
begin
  select coalesce(jsonb_agg(e order by e.id desc), '[]'::jsonb) into res from
    (select id, kind, message, created_at, seen from game.events where player_id = pid order by id desc limit 60) e;
  update game.events set seen = true where player_id = pid and not seen;
  delete from game.events where player_id = pid and id < (select min(id) from
    (select id from game.events where player_id = pid order by id desc limit 200) k);
  return res;
end $$;

create or replace function public.send_chat(p_token text, p_message text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); v_last timestamptz; m text;
begin
  m := trim(regexp_replace(coalesce(p_message, ''), '[[:cntrl:]]', ' ', 'g'));
  if length(m) < 1 then raise exception 'Message is empty.'; end if;
  if length(m) > 200 then raise exception 'Messages are limited to 200 characters.'; end if;
  select last_chat_at into v_last from game.players where id = pid for update;
  if v_last is not null and v_last > now() - interval '4 seconds' then
    raise exception 'Slow down, soldier. One message every 4 seconds.';
  end if;
  update game.players set last_chat_at = now() where id = pid;
  insert into game.chat_messages (player_id, message) values (pid, m);
  delete from game.chat_messages where id < (select min(id) from (select id from game.chat_messages order by id desc limit 500) k);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.get_chat(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token);
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'player_id', c.player_id, 'username', p.username,
            'staff', p.is_admin, 'message', c.message, 'created_at', c.created_at) order by c.id)
     from (select * from game.chat_messages order by id desc limit 50) c
     join game.players p on p.id = c.player_id), '[]'::jsonb);
end $$;

-- Factions ("Armies")
create or replace function public.list_factions(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token);
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'name', f.name, 'tag', f.tag,
            'description', f.description, 'leader', (select username from game.players where id = f.leader_id),
            'members', (select count(*) from game.players where faction_id = f.id),
            'total_level', (select coalesce(sum(level), 0) from game.players where faction_id = f.id)) order by f.id)
     from game.factions f), '[]'::jsonb);
end $$;

create or replace function public.get_faction(p_token text, p_faction bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); f game.factions;
begin
  select * into f from game.factions where id = p_faction;
  if not found then raise exception 'Army not found.'; end if;
  return jsonb_build_object('id', f.id, 'name', f.name, 'tag', f.tag, 'description', f.description,
    'leader_id', f.leader_id, 'created_at', f.created_at::date,
    'members', coalesce((select jsonb_agg(game.public_player(p) order by p.level desc) from game.players p where p.faction_id = f.id), '[]'::jsonb));
end $$;

create or replace function public.create_faction(p_token text, p_name text, p_tag text, p_description text default '') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players; n text := trim(coalesce(p_name, '')); t text := upper(trim(coalesce(p_tag, '')));
  d text := left(trim(regexp_replace(coalesce(p_description, ''), '[[:cntrl:]]', ' ', 'g')), 300); fid bigint;
begin
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
end $$;

create or replace function public.join_faction(p_token text, p_faction bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players; f game.factions;
begin
  select * into f from game.factions where id = p_faction for update;
  if not found then raise exception 'Army not found.'; end if;
  p := game.tick(pid);
  if p.faction_id is not null then raise exception 'Leave your current army first.'; end if;
  if (select count(*) from game.players where faction_id = f.id) >= 50 then raise exception 'That army is full (50 members).'; end if;
  update game.players set faction_id = f.id where id = pid;
  perform game.add_event(pid, 'faction', format('You enlisted in %s [%s].', f.name, f.tag));
  if f.leader_id is not null then
    perform game.add_event(f.leader_id, 'faction', format('%s enlisted in your army.', p.username));
  end if;
  return jsonb_build_object('message', format('You joined %s.', f.name));
end $$;

create or replace function public.leave_faction(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players; f game.factions; heir bigint;
begin
  p := game.tick(pid);
  if p.faction_id is null then raise exception 'You are not in an army.'; end if;
  select * into f from game.factions where id = p.faction_id for update;
  update game.players set faction_id = null where id = pid;
  if f.leader_id = pid then
    select id into heir from game.players where faction_id = f.id order by level desc, id limit 1;
    if heir is null then
      delete from game.factions where id = f.id;
      return jsonb_build_object('message', format('You left and %s was disbanded.', f.name));
    end if;
    update game.factions set leader_id = heir where id = f.id;
    perform game.add_event(heir, 'faction', format('You are now the commander of %s.', f.name));
  end if;
  return jsonb_build_object('message', format('You left %s.', f.name));
end $$;

-- ===== Admin (Command Staff). Every function checks is_admin on the server. =====

create or replace function public.admin_list_players(p_token text, p_search text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); q text := nullif(regexp_replace(coalesce(p_search, ''), '[^A-Za-z0-9_]', '', 'g'), '');
begin
  perform game.require_admin(pid);
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'username', username, 'level', level, 'cash', cash,
            'bank', bank, 'banned', banned, 'is_admin', is_admin, 'npc', is_npc, 'wins', wins, 'losses', losses,
            'created_at', created_at, 'last_action', last_action) order by id)
     from (select * from game.players where q is null or username ilike '%' || q || '%' order by id limit 200) x), '[]'::jsonb);
end $$;

create or replace function public.admin_get_player(p_token text, p_player bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token);
begin
  perform game.require_admin(pid);
  if not exists (select 1 from game.players where id = p_player) then raise exception 'Player not found.'; end if;
  perform game.tick(p_player);
  return game.me_json(p_player) || (select jsonb_build_object('banned', banned, 'npc', is_npc,
           'failed_logins', failed_logins, 'locked_until', locked_until, 'created_at', created_at, 'last_action', last_action,
           'sessions', (select count(*) from game.sessions s where s.player_id = p.id and s.expires_at > now()))
         from game.players p where id = p_player);
end $$;

create or replace function public.admin_set_ban(p_token text, p_player bigint, p_banned boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); t game.players;
begin
  perform game.require_admin(pid);
  select * into t from game.players where id = p_player for update;
  if not found then raise exception 'Player not found.'; end if;
  if t.id = pid then raise exception 'You cannot ban yourself.'; end if;
  if t.is_admin then raise exception 'You cannot ban another admin.'; end if;
  update game.players set banned = coalesce(p_banned, false) where id = p_player;
  if p_banned then delete from game.sessions where player_id = p_player; end if;
  insert into game.admin_log (admin_id, target_id, action) values (pid, p_player, case when p_banned then 'ban' else 'unban' end);
  return jsonb_build_object('message', format('%s is now %s.', t.username, case when p_banned then 'banned' else 'unbanned' end));
end $$;

create or replace function public.admin_adjust_cash(p_token text, p_player bigint, p_delta bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); t game.players; newc bigint;
begin
  perform game.require_admin(pid);
  if p_delta is null or p_delta = 0 or abs(p_delta) > 1000000000 then raise exception 'Amount must be non-zero and at most 1,000,000,000.'; end if;
  t := game.tick(p_player);
  newc := greatest(0, t.cash + p_delta);
  update game.players set cash = newc where id = p_player;
  insert into game.admin_log (admin_id, target_id, action) values (pid, p_player, format('cash %s', p_delta));
  perform game.add_event(p_player, 'system', case when p_delta > 0 then format('Command Staff granted you $%s.', p_delta)
                                                   else format('Command Staff removed $%s from your cash.', -p_delta) end);
  return jsonb_build_object('message', format('%s now has $%s cash.', t.username, newc));
end $$;

create or replace function public.admin_reset_player(p_token text, p_player bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); t game.players;
begin
  perform game.require_admin(pid);
  t := game.tick(p_player);
  if t.is_npc then raise exception 'NPCs cannot be reset.'; end if;
  update game.players set level = 1, xp = 0, cash = 1000, bank = 0, hp = 100, energy = 100, nerve = 10,
    hp_at = now(), energy_at = now(), nerve_at = now(), str = 10, def = 10, spd = 10, dex = 10,
    weapon_id = null, armor_id = null, hospital_until = null, jail_until = null,
    wins = 0, losses = 0, missions_done = 0 where id = p_player;
  delete from game.inventory where player_id = p_player;
  insert into game.admin_log (admin_id, target_id, action) values (pid, p_player, 'reset');
  perform game.add_event(p_player, 'system', 'Your soldier was reset by Command Staff.');
  return jsonb_build_object('message', format('%s has been reset.', t.username));
end $$;

create or replace function public.admin_announce(p_token text, p_message text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); m text := trim(regexp_replace(coalesce(p_message, ''), '[[:cntrl:]]', ' ', 'g'));
begin
  perform game.require_admin(pid);
  if length(m) > 300 then raise exception 'Announcements are limited to 300 characters.'; end if;
  update game.announcements set active = false where active;
  if length(m) > 0 then insert into game.announcements (message) values (m); end if;
  insert into game.admin_log (admin_id, action) values (pid, case when length(m) > 0 then 'announce' else 'clear announcement' end);
  return jsonb_build_object('message', case when length(m) > 0 then 'Announcement posted.' else 'Announcement cleared.' end);
end $$;

create or replace function public.admin_recent_events(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token);
begin
  perform game.require_admin(pid);
  return coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'username', p.username, 'kind', e.kind,
            'message', e.message, 'created_at', e.created_at) order by e.id desc)
     from (select * from game.events order by id desc limit 100) e join game.players p on p.id = e.player_id), '[]'::jsonb);
end $$;

-- ===== Privileges: API roles may only EXECUTE the public RPC functions. =====
revoke all on all functions in schema game from public, anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on all functions in schema public to anon, authenticated;
