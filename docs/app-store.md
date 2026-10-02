# App store

Pages can be installed on a badge without a cable. They are published as
signed packs in [mwingert/avm_badge_apps](https://github.com/mwingert/avm_badge_apps),
and the badge's Store page browses and downloads them straight from GitHub.
There is no server of our own in between.

```
store repo ── mix store.pack ──▶ packs/*.avm + manifest.json ── git push ──▶ GitHub
                                                                               │
badge: Store page ◀── HTTPS GET raw.githubusercontent.com ◀────────────────────┘
         │
         └─ verify signature ─▶ load into PSRAM ─▶ home grid
```

## Creating an app

An app lives in the store repo as `apps/<id>/`:

- `lib/` holds ordinary Elixir. Every module sits under `Badge.App.<Id>`, and
  `Badge.App.<Id>.Page` implements the `Badge.Page` behaviour like any
  firmware page.
- `app.exs` holds its store entry:

      [name: "Fractals", author: "Mathias Wingert",
       description: "Mandelbrot sectors you zoom into, in five palettes",
       version: "1.0.0", storage: "ram", category: "art"]

The rules:

- `id` is a lowercase letter and up to 14 lowercase letters or digits. The
  badge derives the page module from it and never takes a module name from
  the network.
- `name` is at most 13 bytes (one home grid cell), `author` at most 32,
  `description` at most 120, `version` at most 16.
- `category` is one of `games`, `art`, `music`, `chat`, `tools` or `other`.
  The list lives in the store repo's `lib/avm_badge_apps/pack.ex`; the badge
  accepts any lowercase word up to 12 letters and builds its filter from the
  manifest, so a new category needs no firmware update. It is not signed: it
  only sorts the list.
- An app may call any firmware module (`Badge.Theme`, `Badge.Nav`,
  `Badge.Nvs`, …): it runs in the same VM and is compiled against
  `../avm_badge`. The AtomVM rules in `CLAUDE.md` apply as they do to
  firmware.

## Building

    cd avm_badge_apps
    BADGE_STORE_KEY=~/.config/avm_badge/store_key mix store.pack <id>

`mix store.pack`:

1. Compiles every app for the badge target and runs `mix atomvm.check`.
2. Refuses modules outside `Badge.App.*`, an app without its `Page` module,
   and metadata over the limits.
3. Packs that app's modules into one `.avm`, with debug information stripped.
   Packs over 64K are refused.
4. Signs it with ECDSA P-256. The signature covers `id`, `version`, `api`,
   `storage` and the pack's SHA-256, so none of them can be swapped.
5. Writes `packs/<id>-<version>.avm` and the app's entry in `manifest.json`.

A published version never changes: if its pack already exists with different
bytes, the task stops. Bump `version` instead, because a badge downloads the
exact version it installed again after every reboot.

`api` is `Badge.Store.api/0` from the firmware. It goes up when a firmware
function that apps call changes, and a badge installs only apps built for its
own `api`.

## Publishing

    git add packs manifest.json && git commit -m "Publish <id> <version>" && git push

GitHub serves the files from `raw.githubusercontent.com` and caches them for
up to five minutes, so badges see a push within about five minutes.

## Browsing

The Store page is on the second home screen, under the diamond key
(`Badge.Page.Store`).

1. On entry it starts a `Badge.Store.Job` in a process of its own, which:
   - waits for wifi and a set clock, since before SNTP every certificate is
     "not yet valid";
   - fetches `manifest.json` over HTTPS with the certificate checked;
   - decodes it and drops any malformed entry.
2. The top line is the category filter, `< All >` first. Left and right step
   through All and every category the manifest uses, and the list shows the
   matching apps. An entry without a category counts as `other`.
3. The list shows each app's name and status:
   - its size when it can install;
   - `installed`;
   - `update` when the store has another version;
   - `newer fw` when it needs another `api` or flash storage;
   - `no room` when it does not fit.

   The footer shows the free budget. Installed apps the store no longer lists
   stay in the list under All, so they can still be removed.
4. Enter opens the details: description, author, version and "Needs 15K,
   180K free".

The badge never uses the GitHub API, so GitHub's rate limit per IP address,
which a conference shares, does not apply.

## Installing

In the details, Enter installs:

1. `Badge.Store.installable/2` checks the `api` and `storage`, that at most
   12 apps are installed, and that the pack fits the 256K budget. For an
   update only the size difference counts.
2. A job downloads `packs/<id>-<version>.avm`.
3. `Badge.Store.verify/2` checks the size, the SHA-256, the `api`, the
   `storage` and the signature against the store key: the NVS `store_key`
   if provisioned, otherwise `assets/store_key.pub`, compiled into the
   firmware. A pack that fails is discarded; nothing is
   loaded or saved.
4. `:atomvm.add_avm_pack_binary/2` loads the pack into PSRAM, after the
   firmware's own code, so it can never replace a firmware module.
5. `Badge.Store.Installed` records the app in NVS under `apps`, together with
   what a later download needs to verify it. The app then appears on the home
   grid from the third screen on.

## Opening, rebooting, updating, removing

- **Opening** an app whose code is loaded opens it at once. After a reboot
  the code is gone, so the Store page opens instead, shows "Downloading
  <name>", downloads and verifies the installed version, then opens the app.
  This needs wifi.
- **Updating** saves the new version's entry; the next open after a restart
  downloads the new pack. Loaded code cannot be unloaded, hence the restart.
- **Removing** drops the entry from NVS and the grid. The code stays in RAM
  until the restart.
- **A crashing app** is caught by `Badge.UI.Guard`. The console shows
  `UI: page … crashed`, the badge returns to Home, and the app's cell is
  dimmed and will not open until the next boot.

## When things go wrong

| Problem | What happens |
|---|---|
| No wifi or no clock yet | "Waiting for wifi and clock"; fetched again every 10 s |
| GitHub unreachable or an HTTP error | "Store offline: <reason>"; fetched again every 10 s |
| Download fails, or runs over 60 s | "Failed: <reason>"; nothing saved |
| Wrong size, hash or signature | Pack discarded and logged; nothing loaded or saved |
| Leaving the Store page mid-download | The download is stopped; nothing recorded |
| The `:ssl` bug hits during a download | The badge reboots; NVS is only written after a verified load, so nothing is lost |

## Trust

The badge runs only code signed with the store key, whoever serves it.
AtomVM has no sandbox, so an installed app can do anything the firmware can;
review what goes into the store repo accordingly. The private key lives at
`~/.config/avm_badge/store_key` and must never be committed. Losing it means
no new app can be signed until every badge gets firmware with a new
`assets/store_key.pub`.

## Pointing a badge at another store

The NVS key `store_url` overrides the default base,
`https://raw.githubusercontent.com/mwingert/avm_badge_apps/main/`. Give the
full base ending in `/`. An `http://` base works for a store served from a
laptop on the bench; the signature keeps it safe.

A store signed by someone else also needs their public key in NVS
`store_key`. The key never comes from the store itself: whoever can push to
the store could then swap key and packs together.

    BADGE_STORE_URL=https://raw.githubusercontent.com/<you>/<fork>/main/ \
    BADGE_STORE_PUB=path/to/store_key.pub \
    python3 tools/provision.py

Back to the public store: provision the default URL and
`assets/store_key.pub` the same way. Installed apps signed by another key
fail their next download with `:signature`.

A fork that only mirrors the public store's signed packs needs `store_url`
alone.
