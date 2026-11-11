-- Login returns is_admin; stricter reserved usernames; identical error for unknown user / wrong password.

create or replace function game.reserved_name(u text) returns boolean
language sql immutable set search_path = '' as $$
  select lower(u) ~ '(admin|moderat|staff|system|official|support|owner|operator|webmaster)'
      or lower(u) ~ '^(mod|mods|gm|gms|cmd|root|dev|sysop|sys|server|npc|bot)([_0-9]|$)'
      or lower(u) ~ '(^|_)(mod|gm|cmd)$'
$$;
revoke all on function game.reserved_name(text) from public, anon, authenticated;

create or replace function public.register(p_username text, p_password text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint; u text := trim(coalesce(p_username, ''));
begin
  if u !~ '^[A-Za-z0-9_]{3,16}$' then
    raise exception 'Username must be 3-16 characters: letters, numbers or underscore.';
  end if;
  if p_password is null or length(p_password) < 6 or length(p_password) > 72 then
    raise exception 'Password must be 6-72 characters.';
  end if;
  if game.reserved_name(u) then raise exception 'That username is not allowed. Please pick another.'; end if;
  if (select count(*) from game.players where not is_npc and created_at > now() - interval '10 minutes') >= 30 then
    raise exception 'Too many new recruits right now. Try again in a few minutes.';
  end if;
  begin
    insert into game.players (username, pass_hash)
    values (u, extensions.crypt(p_password, extensions.gen_salt('bf', 8)))
    returning id into pid;
  exception when unique_violation then
    raise exception 'That username is taken.';
  end;
  perform game.add_event(pid, 'system', 'Welcome to the front, recruit! Train at the camp, run missions and climb the ranks.');
  return jsonb_build_object('token', game.new_session(pid), 'is_admin', false);
end $$;

create or replace function public.login(p_username text, p_password text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare p game.players; mins int; bad constant text := 'Wrong username or password.';
begin
  select * into p from game.players
   where lower(username) = lower(trim(coalesce(p_username, ''))) and not is_npc for update;
  if not found or p.pass_hash is null then
    perform extensions.crypt(coalesce(p_password, ''), extensions.gen_salt('bf', 8)); -- similar timing
    return jsonb_build_object('error', bad);
  end if;
  if p.locked_until is not null and p.locked_until > now() then
    mins := ceil(extract(epoch from (p.locked_until - now())) / 60);
    return jsonb_build_object('error', format('Too many failed attempts. Try again in %s minute(s).', mins));
  end if;
  if extensions.crypt(coalesce(p_password, ''), p.pass_hash) <> p.pass_hash then
    if p.failed_logins + 1 >= 5 then
      update game.players set failed_logins = 0, locked_until = now() + interval '5 minutes' where id = p.id;
      return jsonb_build_object('error', 'Too many failed attempts. Try again in 5 minute(s).');
    end if;
    update game.players set failed_logins = failed_logins + 1 where id = p.id;
    return jsonb_build_object('error', bad);
  end if;
  if p.banned then
    return jsonb_build_object('error', 'This account has been banned.');
  end if;
  update game.players set failed_logins = 0, locked_until = null, last_action = now() where id = p.id;
  return jsonb_build_object('token', game.new_session(p.id), 'is_admin', p.is_admin);
end $$;
