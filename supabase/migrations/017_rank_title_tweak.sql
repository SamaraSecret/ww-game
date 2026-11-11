-- Numbered Supreme Commander titles start at 2 from level 250 (200-249 stay unnumbered).
create or replace function game.rank_title(lvl int) returns text
language sql immutable set search_path = '' as $$
  select case
    when lvl >= 500 then 'War Legend ' || ((lvl - 500) / 100 + 1)::text
    when lvl >= 250 then 'Supreme Commander ' || ((lvl - 200) / 50 + 1)::text
    when lvl >= 200 then 'Supreme Commander'
    when lvl >= 150 then 'Warlord'
    when lvl >= 100 then 'Grand Marshal'
    when lvl >= 75  then 'High Marshal'
    when lvl >= 50  then 'Field Marshal'
    when lvl >= 40  then 'General'
    when lvl >= 30  then 'Brigadier'
    when lvl >= 25  then 'Colonel'
    when lvl >= 20  then 'Major'
    when lvl >= 15  then 'Captain'
    when lvl >= 11  then 'Lieutenant'
    when lvl >= 8   then 'Sergeant'
    when lvl >= 5   then 'Corporal'
    when lvl >= 3   then 'Private'
    else 'Recruit' end $$;
revoke all on function game.rank_title(int) from public, anon, authenticated;
