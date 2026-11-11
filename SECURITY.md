# Security

This document describes how Noir Syndicate protects players and The Boss (the admin account), what is already locked down, and what a hobby game still cannot promise.

## How the game is built

- The browser is a static site. The recommended public copy is **https://iron-front-ww.vercel.app/**, hosted on **Vercel**, which sets HTTP security headers from `vercel.json`. A GitHub Pages copy also remains online at https://samarasecret.github.io/ww-game/, but that host cannot set those headers, so prefer the Vercel link. The site can only call named game functions (RPCs) on the Supabase project, using the **publishable** key in `config.js`. That key is designed to be public. It cannot read or write tables.
- All game data lives in a private `game` schema that is not exposed through PostgREST. Row Level Security is on for every game table, with a deny-all policy and no table or sequence privileges for the `anon`, `authenticated`, or `public` roles.
- Game rules run in `SECURITY DEFINER` functions with `search_path` locked. Internal helpers stay in the `game` schema and are not callable through the API. Only the listed public RPCs are granted to `anon`.
- The service role / secret key is not in this repository (including git history) and is not used by the frontend.

## Accounts and sessions

- This game uses its own accounts, not Supabase Auth. Passwords are stored as bcrypt hashes (cost 10 for new hashes). They must be 8–72 characters, must not match the username, and a list of very common passwords is rejected.
- Session tokens are 32 random bytes, shown to the client as 64 hex characters. Only a SHA-256 hash of the token is stored. Logout deletes that hash. Changing your password signs other devices out. Admin password changes end every session, including the current one. “Sign out everywhere” is on the Security page.
- Player sessions expire after 7 days. Admin sessions expire after **2 hours idle** or **12 hours** at most, and at most two admin sessions are kept.
- The Security page in the game is where you change your password or sign out everywhere.

### Where the token is stored

- **Players:** `localStorage`, so you stay signed in in this browser until the session expires or you sign out. Convenient, but any XSS bug in the page could read it. We render all player-supplied text as text nodes (never `innerHTML`) and ship a strict Content-Security-Policy (HTTP header on Vercel, plus a matching meta tag) to reduce that risk.
- **The Boss (admin):** `sessionStorage`, so closing the tab drops the client copy. The server still enforces the idle and maximum lifetimes above.
- A random device id used only for login throttling is kept in `localStorage`. No IP addresses are stored.

## Login throttling

Failed logins are counted per *(username + device)* and per *device*. A username under heavy attack is only slowed, never locked out for the real owner. All failures return the same generic error, including unknown usernames.

Admin logins have an extra per-device progressive lock and a global cap on failed admin attempts. Those still return the same generic error.

Registration is limited per device, with a global safety cap.

## API lock-down

- Direct table access through `/rest/v1/<table>` is not possible (tables are not in the public schema).
- OpenAPI schema listing is rejected without the service role key (Supabase gateway).
- GraphQL (`pg_graphql`) is not enabled; execute privileges on it are revoked from public roles.
- No storage buckets are used or public. Table privileges on `storage` are revoked from public roles.
- Realtime publications do not include game tables.
- Authenticated RPCs are rate-limited on the server (a global per-player cap, plus tighter limits on attacks, bank actions, chat, founding a cartel, and admin player-list views). Chat messages are capped at 200 characters and stripped of control characters. Cartel names are restricted to a safe pattern.

## Admin protections

- There is no separate admin login form. The admin account uses the same login page. The admin username is reserved and is never shown in public lists, leaderboards, The Streets, hospital lists, or chat (it appears as “The Boss”). Public profile lookups for that account return “Player not found.” Attacks against it fail with the same message as a missing or banned target, so the id cannot be enumerated that way.
- Players cannot ban, attack, or reset the admin. Admin actions, including viewing the player list or a player’s private sheet, are written to an admin-only audit log.

## HTTP security headers

The Vercel site sets these headers on every page (see `vercel.json`):

- `Strict-Transport-Security` (HTTPS-only, including subdomains, preload)
- `Content-Security-Policy` (scripts and styles only from this site, images from this site or `data:`, connections only to this site and the Supabase project, no embedding, no plugins)
- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY`
- `Referrer-Policy: no-referrer`
- `Permissions-Policy` (camera, microphone, geolocation and other browser features disabled)
- `Cross-Origin-Opener-Policy: same-origin`
- `Cross-Origin-Resource-Policy: same-origin`

The same Content-Security-Policy is also in a `<meta>` tag, without `frame-ancestors` (browsers ignore that directive in meta tags). The two policies are aligned so they do not conflict.

The GitHub Pages copy cannot set HTTP security headers. It only has the meta tag, so `frame-ancestors`, HSTS and the other headers above are not enforced there. Use https://iron-front-ww.vercel.app/.

## Limitations (honest)

- No CAPTCHA and no two-factor authentication.
- No password reset, because no email address is collected.
- The device id lives in the browser; a determined attacker can rotate it and is then only slowed, not stopped.
- Slightly stricter admin-login lockouts can, in theory, hint that a guessed username is the admin account if someone is specifically comparing lockout timing. Errors stay generic.
- A leftover Supabase Auth “email signups” switch may still appear enabled in the project until it is turned off in the dashboard (Authentication → Providers → Email). The game does not use Supabase Auth, and a database trigger rejects new `auth.users` rows when the platform allows that trigger to be installed.
- If a legacy anon JWT still exists in the project API settings, it is equivalent in power to the publishable key (RPC only). Prefer the publishable key and disable the legacy anon key in the dashboard if you can.

If you think you have found a vulnerability, please do not open a public issue that includes player data, tokens, or passwords. Contact the operator privately.
