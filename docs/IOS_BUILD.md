# Building the iPhone app without a Mac (GitHub Actions + TestFlight)

[Certain] Xcode only runs on macOS. Here, GitHub's cloud Macs build the app and Apple's TestFlight installs it on your iPhone. You do a one-time setup in the browser on Windows. The `ios/PinkDrone.xcodeproj` is generated from `ios/project.yml` during the build, so you never open Xcode.

[Likely] Because the repo is public, the cloud Mac builds cost nothing.

## One-time setup (about 20 minutes)

### 1. Register the app ID (developer.apple.com)
1. **Certificates, IDs & Profiles → Identifiers → +**.
2. Choose **App IDs → App**.
3. Description `PinkDrone`. Bundle ID: **Explicit** `com.gabrielhcaribe.pinkdrone`.
4. Under Capabilities, tick **Hotspot**. This is what lets the app join the drone WiFi automatically.
5. Click **Continue → Register**.

### 2. Create the app record (appstoreconnect.apple.com)
1. **Apps → + → New App**.
2. Platform **iOS**.
3. Name: anything unique on the App Store, e.g. `PinkDrone GHC`. The name on your home screen stays "PinkDrone".
4. Language English, Bundle ID `com.gabrielhcaribe.pinkdrone`, SKU `pinkdrone`.
5. Click **Create**. You don't need to fill in anything else, because TestFlight internal testing has no review.

### 3. Create an App Store Connect API key
1. **Users and Access → Integrations → App Store Connect API → Team Keys → +**.
2. Name `github-ci`, Access **Admin**. [Likely] Admin is needed so the build can create signing certificates in the cloud.
3. **Download** the `.p8` file. You can only download it once, so keep it safe.
4. Note the **Key ID** (in the table) and the **Issuer ID** (above the table).

### 4. Find your Team ID
developer.apple.com/account → **Membership details → Team ID** (10 characters).

### 5. Add 5 secrets to GitHub
On the repo: **Settings → Secrets and variables → Actions → New repository secret**.

| Name | Value |
|---|---|
| `DRONE_WIFI_PASSWORD` | the WiFi password, same as in `secrets.h` |
| `APPLE_TEAM_ID` | Team ID from step 4 |
| `ASC_KEY_ID` | Key ID from step 3 |
| `ASC_ISSUER_ID` | Issuer ID from step 3 |
| `ASC_KEY_P8` | open the `.p8` in Notepad and paste **everything**, including the `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----` lines |

Secrets are encrypted and are never visible in the public repo or the logs.

## Build and install

1. Repo → **Actions → "iOS app" → Run workflow**. Pick the branch, keep **Upload to TestFlight** ticked, then **Run**.
   - It takes 10–20 minutes. Pushes to `main` also upload automatically.
   - Pushes to other branches only compile-check, with no secrets needed.
2. appstoreconnect.apple.com → your app → **TestFlight**.
   - The build shows "Processing" for 5–30 minutes.
   - The first time, answer the export-compliance question if asked. The app declares no encryption, so normally it isn't asked.
3. **TestFlight → Internal Testing → +** to create a group, then add yourself (your Apple ID email).
4. On the iPhone, install **TestFlight** from the App Store, open the invite, and tap **Install**.
5. The first time you launch the app:
   - Allow **Local Network**, **Camera** and **Motion & Fitness**.
   - Accept the prompt to join the **PinkDrone** WiFi.

TestFlight builds expire after 90 days. To get a fresh one, run the workflow again.

## If the build fails

- Open the failed run in the Actions tab; the red step has the error.
- Once I have push access to the repo, I can read these logs myself and push fixes.
- `No profiles for 'com.gabrielhcaribe.pinkdrone'` or `cloud signing` errors: check that the API key has **Admin** access and that the App ID from step 1 exists with **Hotspot** enabled.
- `No suitable application records were found`: step 2 is missing, or the bundle ID doesn't match.

## Fallback: a rented Mac
A cloud Mac (e.g. MacinCloud, about $1–2/hour) running Xcode works too:
1. `brew install xcodegen`, then `cd ios && cp Secrets.example.xcconfig Secrets.xcconfig` and edit it.
2. Run `xcodegen generate` and open `PinkDrone.xcodeproj`.
3. Under Signing, pick your team, plug in the iPhone and press Run.
