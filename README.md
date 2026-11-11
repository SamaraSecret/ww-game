# Iron Front: World War

A text-based, persistent multiplayer World War strategy game in the style of classic browser games such as Torn.
Play it at **https://iron-front-ww.vercel.app/** (recommended; this is the copy with HTTP security headers).
A GitHub Pages copy also stays up at **https://samarasecret.github.io/ww-game/**, but that host cannot set those headers.

## Gameplay
- **Register** with a username and password, then climb the ranks from Recruit through Field Marshal and beyond. There is no ordinary level cap (a safety ceiling of 1,000,000 avoids overflow).
- **Training Camp**: spend energy to raise Strength, Defense, Speed and Dexterity (diminishing returns). Every level-up also grants **5 stat points** you can assign to those four stats. Existing soldiers receive the points for levels they have already earned, once.
- **Missions**: spend nerve on Recon Patrols, Supply Raids, Sabotage, Convoy Ambushes and more. Failure can wound you or land you in the stockade.
- **Battlefield**: attack NPC training targets or other soldiers (level 3+). Combat is resolved on the server as a round-by-round battle log.
- **Army Command**: build a personal force.
  - *Troops*: every level-up grants **+2 free troops** (up to **300 free troops** in total). Everything beyond that is
    bought with cash in **Supplies** (each recruit costs a little more as the force grows, plus a little energy).
    The absolute maximum army size is **1,000 troops**.
  - *Army weapons*: Rifles, Grenades, Machine Guns, Combat Shotguns, Mortars, Anti-tank Rockets, Heavy Mortars,
    Flamethrowers, Recoilless Guns, Autocannons, Howitzers and Missile Launchers. Each troop carries one weapon (best first).
  - *Vehicles*: Motorcycle, Jeep, Supply Truck, Armored Car, Half-Track, APC, Light Tank, Scout Plane, Medium Tank,
    Artillery, Self-Propelled Gun, Heavy Tank, Transport Helicopter, Fighter Plane, Attack Helicopter, Bomber,
    Jet Fighter, Destroyer, Submarine, Cruiser and Battleship. Level requirements, a per-type cap that grows with level,
    wear from battles, repairs for cash and a partial refund when sold.
  - *Army Power* boosts battle damage (between x0.6 and x1.5 against the enemy's army), so personal stats still matter.
    Losers lose more troops, and vehicles wear down. Other players only see a coarse *Force class* (Squad ... Division).
- **Field Hospital & Stockade**: wait out the timer or pay to leave early.
- **Armory**: buy, equip and sell personal weapons and armor (20 weapons and 12 armor pieces, from a Combat Knife up to a Rail Rifle). Every weapon, armor piece and vehicle has an original in-game icon.
- **Bank**: keep your cash safe from attackers (1% deposit fee).
- **Armies**: found, join or leave a faction.
- **Soldiers, Leaderboards, Events and Radio Chat**.
- **Admin panel** (shown only to admin accounts after a normal login, enforced on the server):
  - *Command Powers* on the admin's own soldier: instant refill, instant release, set stats/level, grant cash/troops/
    weapons/vehicles, Immortal mode, God strike, and Command Orders broadcast to every player's Events.
  - The admin is hidden from the Battlefield, Soldiers list and leaderboards and appears as "Command HQ" to players.
  - Every admin action is written to an admin-only audit log.
  - Player management: player list, ban/unban, give/take cash, reset a player, global announcements, recent events.

Energy regenerates +5 every 5 minutes (max 100), nerve +1 every 5 minutes (max 10), health +10% every 5 minutes.

## How it is built and hosted
- **Frontend**: plain HTML, CSS and JavaScript (no build step). The recommended public site is **https://iron-front-ww.vercel.app/**, hosted on **Vercel**, which enforces HTTP security headers (see `vercel.json` and [SECURITY.md](SECURITY.md)). A copy also remains on **GitHub Pages** at https://samarasecret.github.io/ww-game/. Prefer the Vercel link.
- **Backend**: **Supabase** (Postgres). All game rules live in SQL functions (`supabase/migrations/`).
  The browser can only call these functions (RPC). It cannot read or write any table directly.

## Security and privacy notes (honest version)
See [SECURITY.md](SECURITY.md) for the full write-up. The short version:
- Game tables live in a private `game` schema that the public API does not expose. Row Level Security is on for every table,
  with a deny-all policy, and the public roles have no table privileges at all. They can only execute the listed game RPCs.
- Every action is validated on the server, with row locks to prevent double-spending and rate limits on expensive or
  abusive endpoints.
- Passwords must be 8-72 characters, cannot be a very common choice, and are stored as bcrypt hashes. Change your
  password (and sign out everywhere) on the in-game **Security** page. Player sessions expire after 7 days. Command Staff
  sessions last at most 2 hours idle or 12 hours total, and a password change ends every admin session.
- Login throttling never lets a stranger lock out the real owner: failures are counted per *(username + device)* and per
  *device* (a random id stored in the browser, never an IP). Command Staff logins also have a stricter per-device lock
  and a global failure cap, still with the same generic error.
- Other players can only see public info: username, level, rank, army, status, win/loss record and join date.
  Cash, bank, exact battle stats, unspent stat points, force size, army inventory and events are private. The admin
  account is hidden from public lists and appears as "Command HQ".
- Staff-like usernames (admin, mod, gm, staff, system, ...) cannot be registered.
- **No email addresses or IP addresses are collected or stored.**
- The Supabase key in `config.js` is the *publishable* key, which is meant to be public. No secret keys, passwords or
  player data are in this repository.
- The Vercel site sets HTTP security headers (including Content-Security-Policy, a ban on embedding the game in other
  sites, HTTPS-only, and others listed in SECURITY.md). GitHub Pages cannot set those headers; its copy only has a
  Content-Security-Policy meta tag, and some rules such as `frame-ancestors` do not apply there. Use the Vercel link.
- Limitations: no password reset (there is no email), no CAPTCHA, and no 2FA. The device id lives in the browser, so a
  determined attacker can rotate it; they are then only slowed, not stopped. Don't reuse a password from another site.
