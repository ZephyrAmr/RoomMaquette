# Building & Installing RoomMaquette on iPhone Pro Without a Mac

You do not need a Mac to build or install **RoomMaquette** on your iPhone Pro! Everything is configured so that:
1. **GitHub Actions** (running on Apple Silicon macOS cloud runners) automatically compiles the Swift & RoomPlan code.
2. You download the compiled **`.ipa`** file directly from GitHub.
3. You install it onto your iPhone Pro from your Windows PC using free sideloading tools in under 2 minutes.

---

## Step 1: Push This Project to Your GitHub Account

Your remote is already configured for your account: **`https://github.com/ZephyrAmr/RoomMaquette.git`**!

1. **Create the repository on GitHub** (if you haven't already):
   - Go to [github.com/new](https://github.com/new).
   - Repository name: **`RoomMaquette`**
   - Visibility: **Public** or **Private** (both work with GitHub Actions).
   - Leave "Add a README file" and ".gitignore" **unchecked**.
   - Click **Create repository**.

2. **Push your code**:
   Open PowerShell in this directory (`c:\Users\Zep\Desktop\room plan`) and run:

   ```powershell
   git push -u origin main
   ```

---

## Step 2: GitHub Actions Automatically Compiles the App

As soon as you push:
1. Go directly to your GitHub Actions page:
   👉 **[https://github.com/ZephyrAmr/RoomMaquette/actions](https://github.com/ZephyrAmr/RoomMaquette/actions)**
2. Click on the running workflow **"Build iOS RoomMaquette"**.
3. In about **2 to 3 minutes**, the Apple Silicon macOS runner will finish compilation.
4. Scroll to the bottom under **Artifacts** and download:
   - **`RoomMaquette-iOS-Device-IPA`** (contains `RoomMaquette-unsigned.ipa`).
5. Unzip it to extract `RoomMaquette-unsigned.ipa`.

---

## Step 3: Install onto Your iPhone Pro from Windows

You can install any `.ipa` file onto your physical iPhone Pro using **Sideloadly** (recommended) or **AltServer**, both of which run natively on Windows and use your standard free Apple ID (no paid $99/year developer account needed).

### Method A: Sideloadly (Recommended — Quickest & Simplest)

1. **Download and install Sideloadly on Windows**:
   - Website: [sideloadly.io](https://sideloadly.io)
   - Ensure iTunes and iCloud for Windows (non-Microsoft Store version or via Sideloadly installer) are installed.
2. **Connect your iPhone Pro to your Windows PC via USB cable**:
   - Unlock your iPhone and tap **"Trust This Computer"** if prompted.
3. **Open Sideloadly**:
   - Your connected iPhone will appear under **Device**.
   - Drag and drop `RoomMaquette-unsigned.ipa` into the large **IPA icon** area in Sideloadly.
   - Enter your **Apple ID** email address.
   - Click **Start**.
   - If prompted, enter your Apple ID password (this communicates directly with Apple's authentication servers to generate a free 7-day personal development certificate).
4. **Trust the App on iPhone**:
   - Once Sideloadly says "Done", the **RoomMaquette** app icon will appear on your iPhone home screen.
   - On your iPhone, open **Settings > General > VPN & Device Management**.
   - Tap your Apple ID under "Developer App".
   - Tap **Trust "Your Apple ID"**.
5. **Enable Developer Mode** (iOS 16, 17, 18 requirement):
   - Go to **Settings > Privacy & Security > Developer Mode** (at the bottom).
   - Turn **Developer Mode ON** and restart your iPhone when prompted.
6. Open **RoomMaquette** and start scanning rooms with LiDAR!

---

### Method B: AltStore & AltServer for Windows

If you already use AltStore:
1. Install **AltServer for Windows** from [altstore.io](https://altstore.io).
2. Connect your iPhone via USB, open AltServer in your system tray, and choose **Install AltStore > Your iPhone**.
3. Once AltStore is installed on your iPhone, send `RoomMaquette-unsigned.ipa` to your iPhone (via Google Drive, iCloud Drive, or cable) and tap **Open in AltStore**.

---

## Optional: Automated Cloud Signing (If You Have a Paid Apple Developer Account)

If you have an Apple Developer account ($99/year) and want GitHub Actions to produce directly signed IPAs without needing Sideloadly:

1. In your GitHub repository, go to **Settings > Secrets and variables > Actions**.
2. Add these repository secrets:
   - `APPLE_CERTIFICATE_BASE64`: Your iOS Distribution / Development certificate (`.p12` file encoded in base64).
   - `P12_PASSWORD`: The password for your `.p12` certificate.
   - `PROVISIONING_PROFILE_BASE64`: Your `.mobileprovision` file encoded in base64.
   - `KEYCHAIN_PASSWORD`: Any random string (e.g., `temp-ci-password-1234`).
3. Whenever you push, the `build-signed-ipa` job in GitHub Actions will run automatically, sign the application, and provide a signed `.ipa` in the build artifacts.
