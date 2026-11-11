# Iron Front: World War

A text-based, persistent multiplayer World War strategy game in the style of classic browser games such as Torn.
Play it at **https://samarasecret.github.io/ww-game/**

## Gameplay
- **Register** with a username and password, then climb the ranks from Recruit to Field Marshal.
- **Training Camp**: spend energy to raise Strength, Defense, Speed and Dexterity (diminishing returns).
- **Missions**: spend nerve on Recon Patrols, Supply Raids, Sabotage, Convoy Ambushes and more. Failure can wound you or land you in the stockade.
- **Battlefield**: attack NPC training targets or other soldiers (level 3+). Combat is resolved on the server as a round-by-round battle log.
- **Army Command**: build a personal force.
  - *Troops*: recruit infantry with cash and a little energy. Max force size grows with level, and each recruit costs more as the force grows.
  - *Army weapons*: Rifles, Machine Guns, Mortars, Anti-tank Rockets, Flamethrowers. Each troop carries one weapon (best first).
  - *Vehicles*: Jeep, Armored Car, Light Tank, Artillery, Heavy Tank, Fighter Plane, Bomber, Destroyer. Level requirements,
    a per-type cap that grows with level, wear from battles, repairs for cash and a partial refund when sold.
  - *Army Power* boosts battle damage (between x0.6 and x1.5 against the enemy's army), so personal stats still matter.
    Losers lose more troops, and vehicles wear down. Other players only see a coarse *Force class* (Squad ... Division).
- **Field Hospital & Stockade**: wait out the timer or pay to leave early.
- **Armory**: buy, equip and sell weapons and armor.
- **Bank**: keep your cash safe from attackers (1% deposit fee).
- **Armies**: found, join or leave a faction.
- **Soldiers, Leaderboards, Events and Radio Chat**.
- **Admin panel** (shown only to admin accounts after a normal login, enforced on the server): player list, ban/unban, give/take cash, reset a player, global announcements, recent events.

Energy regenerates +5 every 5 minutes (max 100), nerve +1 every 5 minutes (max 10), health +10% every 5 minutes.

## How it is built and hosted
- **Frontend**: plain HTML, CSS and JavaScript (no build step) hosted free on **GitHub Pages**.
- **Backend**: **Supabase** (Postgres). All game rules live in SQL functions (`supabase/migrations/`).
  The browser can only call these functions (RPC). It cannot read or write any table directly.

## Security and privacy notes (honest version)
- Game tables live in a private `game` schema that the public API does not expose. Row Level Security is on for every table,
  and the public roles have no table privileges at all. They can only execute the game's RPC functions.
- Every action is validated on the server, with row locks to prevent double-spending.
- Passwords are stored as bcrypt hashes. Login sessions use random tokens, and only a SHA-256 hash of each token is stored.
  Sessions expire after 7 days. After 5 wrong passwords, the account is locked for 5 minutes.
- Other players can only see public info: username, level, rank, army, status, win/loss record and join date.
  Cash, bank, exact battle stats, force size, army inventory and events are private.
- Staff-like usernames (admin, mod, gm, staff, system, ...) cannot be registered.
- **No email addresses or IP addresses are collected or stored.**
- The Supabase key in `config.js` is the *publishable* key, which is meant to be public. No secret keys, passwords or
  player data are in this repository.
- Limitations: this is a hobby game. There is no password reset (there is no email), no CAPTCHA, and the per-account
  lockout means someone could deliberately lock another player out for 5 minutes. Don't reuse a password from another site.
