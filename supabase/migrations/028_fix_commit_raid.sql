-- Disambiguate local chest variable vs game.raids.chest in commit_raid.

create or replace function public.commit_raid(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare
  pid bigint := game.auth(p_token);
  p game.players;
  r game.raids;
  b game.raid_bosses;
  n int;
  n_br int; n_hk int; n_cb int;
  power numeric;
  v_log jsonb := '[]'::jsonb;
  ok_br boolean; ok_hk boolean; ok_cb boolean;
  v_chest bigint := 0;
  rec record;
  ch numeric;
  won boolean;
begin
  perform game.rate_limit(pid, 'raid', 8, interval '10 minutes', interval '3 seconds');
  p := game.tick(pid);
  perform game.require_free(p);
  if p.faction_id is null then raise exception 'You are not in a cartel.'; end if;
  select * into r from game.raids where faction_id = p.faction_id and status = 'open' for update;
  if not found then raise exception 'There is no open job.'; end if;
  if r.leader_id <> pid then raise exception 'Only the job leader can commit the raid.'; end if;
  select * into b from game.raid_bosses where id = r.boss_id;
  select count(*),
         count(*) filter (where role = 'breach'),
         count(*) filter (where role = 'hack'),
         count(*) filter (where role = 'combat')
    into n, n_br, n_hk, n_cb
    from game.raid_members where raid_id = r.id;
  if n < b.min_members then raise exception 'You need at least % people on this job.', b.min_members; end if;

  -- Charge energy and require everyone free. Lock members in id order.
  for rec in
    select m.player_id, pl.energy, pl.hospital_until, pl.jail_until, pl.level
      from game.raid_members m
      join game.players pl on pl.id = m.player_id
     where m.raid_id = r.id
     order by m.player_id
     for update of pl
  loop
    perform game.tick(rec.player_id);
    select energy, hospital_until, jail_until into rec.energy, rec.hospital_until, rec.jail_until
      from game.players where id = rec.player_id;
    if rec.hospital_until is not null and rec.hospital_until > now() then
      raise exception 'Someone on the job is in the hospital.';
    end if;
    if rec.jail_until is not null and rec.jail_until > now() then
      raise exception 'Someone on the job is in jail.';
    end if;
    if rec.energy < b.energy_cost then
      raise exception 'Someone on the job does not have enough energy.';
    end if;
    update game.players set energy = energy - b.energy_cost where id = rec.player_id;
  end loop;

  select coalesce(sum((game.army_power(m.player_id)->>'power')::numeric), 0) into power
    from game.raid_members m where m.raid_id = r.id;

  ch := least(0.92, greatest(0.15, 0.50 + n_br * 0.10 - b.difficulty * 0.08 + least(0.15, power / 8000.0)));
  ok_br := random() < ch;
  v_log := v_log || jsonb_build_array(jsonb_build_object('stage','breach','ok', ok_br, 'chance', round(ch*100)));

  ch := least(0.92, greatest(0.15, 0.50 + n_hk * 0.10 - b.difficulty * 0.08 + least(0.15, power / 8000.0)));
  ok_hk := random() < ch;
  v_log := v_log || jsonb_build_array(jsonb_build_object('stage','hack','ok', ok_hk, 'chance', round(ch*100)));

  ch := least(0.92, greatest(0.15, 0.50 + n_cb * 0.10 - b.difficulty * 0.08 + least(0.15, power / 8000.0)));
  ok_cb := random() < ch;
  v_log := v_log || jsonb_build_array(jsonb_build_object('stage','combat','ok', ok_cb, 'chance', round(ch*100)));

  won := ok_br and ok_hk and ok_cb;
  if won then
    v_chest := (b.chest_min + floor(random() * (b.chest_max - b.chest_min + 1)))::bigint;
    update game.factions set vault_dirty = vault_dirty + v_chest where id = r.faction_id;
  end if;
  update game.raids
     set status = case when won then 'won' else 'failed' end,
         resolved_at = now(), chest = v_chest, log = v_log
   where id = r.id;

  insert into game.events (player_id, kind, message)
    select m.player_id, 'raid',
           case when won then format('The job on %s paid $%s dirty cash into the vault.', b.name, to_char(v_chest, 'FM999,999,999'))
                else 'The job on ' || b.name || ' fell apart.' end
      from game.raid_members m where m.raid_id = r.id;

  return jsonb_build_object(
    'ok', won, 'chest', v_chest, 'log', v_log,
    'message', case when won then format('The job succeeded. $%s dirty cash went into the vault.', to_char(v_chest, 'FM999,999,999'))
                    else 'The job failed. The vault is unchanged.' end,
    'me', game.me_json(pid));
end $function$;

-- ---------- hospital hits & jail breaks ----------
