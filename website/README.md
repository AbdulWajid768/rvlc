# RVLC website

The download page at <https://rvlc.abdulwajid.dev>. It is a static site on
Firebase Hosting with a download counter in Firestore. Both are on the free
Spark plan, and there is no build step.

| Path | Contents |
|---|---|
| `public/index.html` | The page, laid out like a film in chapters: opening titles, Smart Subtitle Sync, the player, privacy, install, release notes and end credits. |
| `public/styles.css` | Styles: dark and cinematic, set in Geist, Geist Mono and Instrument Serif (Google Fonts). |
| `public/app.js` | Loads the latest release from GitHub and reads/increments the download counter. |
| `public/motion.js` | Animations: opening curtain, scroll-linked tilt, scrub bar and timecode, reveals, the interactive sync demo and the feature-grid loops. Everything is static under "reduce motion". |
| `public/assets/` | Icons and social preview from [`../brand`](../brand), a real screenshot of RVLC (`shot-studio.jpg`) and a short loop (`film.mp4`) that plays inside its video area. |
| `firestore.rules` | Anyone may read the counter; a write may only add exactly 1. |
| `firebase.json`, `.firebaserc` | Hosting, rules and emulator settings; the Firebase project ID. |

## How it works

- **Version and download link.** At page load, `app.js` reads
  `api.github.com/repos/AbdulWajid768/rvlc/releases/latest` and uses the
  release's tag, date, notes and its `.dmg` asset. The DMG is served by GitHub
  Releases, not Firebase: Firebase's free plan allows only about 360 MB of
  traffic per day. A new release therefore needs **no website deploy**. If the
  API is unavailable, the page shows the built-in version (`FALLBACK` in
  `app.js`) and links to the latest release page.
- **Download counter.** The document `stats/downloads` in Firestore holds
  `{ count }`. The page reads it once per visit. Clicking Download adds 1
  through Firestore's REST API, once per browser per release, and then starts
  the download. The project ID and API key come from Hosting's reserved
  `/__/firebase/init.json`, so none are hard-coded. The Firebase web API key is
  public by design; the security rules are what protect the data.
- **The app itself stays offline.** The counter counts website downloads, not
  installs, so the player keeps its "no network requests" promise
  ([SECURITY.md](../SECURITY.md)).

## One-time setup

You need the Firebase CLI (`npm i -g firebase-tools`) and to be logged in with
`firebase login`.

1. Create the project. Project IDs are global, so if `rvlc-web` is taken, pick
   another ID and put it in `.firebaserc`.

   ```bash
   firebase projects:create rvlc-web --display-name "RVLC"
   ```

2. Create the Firestore database (choose a location near your users; it can't
   be changed later):

   ```bash
   firebase firestore:databases:create "(default)" --location=eur3 --project rvlc-web
   ```

3. Register a web app so `/__/firebase/init.json` has a config to serve:

   ```bash
   firebase apps:create web "RVLC website" --project rvlc-web
   ```

4. Deploy (from this folder):

   ```bash
   firebase deploy --only hosting,firestore:rules
   ```

   The site is then live at `https://rvlc-web.web.app`. The counter document
   is created by the first download.

5. Custom domain: Firebase console → Hosting → **Add custom domain** →
   `rvlc.abdulwajid.dev`. Add the TXT and A records it shows at the DNS
   provider for `abdulwajid.dev`. Firebase issues the HTTPS certificate itself;
   that can take up to a few hours after DNS propagates.

## Publishing a new version

1. Bump `RVLCVersion.string` in `Sources/RVLCApp/App/AppDelegate.swift` and add
   a section to `CHANGELOG.md`.
2. Build the DMG: `scripts/package-macos.sh` produces
   `dist/RVLC-<version>-macOS-arm64.dmg`.
3. Create the GitHub release with the DMG attached:

   ```bash
   gh release create v<version> dist/RVLC-<version>-macOS-arm64.dmg --title "RVLC <version>" --notes-file notes.md
   ```

The website picks it up automatically. Update `FALLBACK` in `public/app.js`
and redeploy only if you want the offline fallback to show the new version.

## Local preview

```bash
firebase emulators:start --only hosting,firestore
```

Open <http://localhost:5050>. (`python3 -m http.server -d public` also works for
layout work; the counter stays hidden without Firebase.) On `localhost`, `app.js` talks to the Firestore
emulator on port 8085, so test clicks never touch the real counter. The first
run downloads the Firestore emulator (needs Java 21+).
