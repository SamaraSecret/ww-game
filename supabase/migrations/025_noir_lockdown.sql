-- Noir Syndicate: drop obsolete war RPCs and lock the public API to the new function list.

-- Drop leftover war-themed RPCs (all overloads of each name).
do $drop$
declare r record;
  names text[] := array[
    'list_missions','do_mission','get_army',
    'recruit_troops','dismiss_troops',
    'buy_troop_weapon','sell_troop_weapon',
    'buy_vehicle','sell_vehicle','repair_vehicle','repair_all_vehicles',
    'create_faction','join_faction','leave_faction','list_factions','get_faction'
  ];
begin
  for r in
    select n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = any(names)
  loop
    execute format('drop function if exists %I.%I(%s)', r.nspname, r.proname, r.args);
  end loop;
end
$drop$;

-- Re-lock tables and functions. New tables from 021 already have RLS + revokes.
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
    'get_me','get_profile','get_chat','send_chat','get_events',
    'list_players','list_targets','list_items','list_crimes','list_cartels','get_cartel',
    'leaderboard','hospital_list','jail_list',
    'attack','train','spend_stats','do_crime',
    'bank_deposit','bank_withdraw','bank_launder',
    'buy_item','sell_item','equip_item','unequip_item',
    'get_crew','recruit_crew','dismiss_crew','buy_crew_weapon','sell_crew_weapon',
    'create_cartel','join_cartel','leave_cartel','cartel_vault',
    'pay_bail','revive',
    'list_garage','steal_car','tune_car','chop_car','export_car',
    'list_businesses','buy_business',
    'swiss_list','swiss_open','swiss_collect',
    'list_bounties','place_bounty',
    'list_districts','contest_district','collect_tribute',
    'list_raid_bosses','list_raids','start_raid','join_raid','commit_raid',
    'hospital_hit','jail_break','choose_path','path_action',
    'admin_adjust_cash','admin_adjust_clean','admin_announce','admin_audit_log_list','admin_command_order',
    'admin_get_player','admin_list_players','admin_power_grant','admin_power_refill',
    'admin_power_release','admin_power_set_stats','admin_power_toggle','admin_recent_events',
    'admin_reset_player','admin_set_ban','admin_set_specialization'
  ];
begin
  foreach fn in array fns loop
    execute format('grant execute on function public.%I to anon', fn);
  end loop;
  grant execute on all functions in schema public to service_role;
end
$g$;
