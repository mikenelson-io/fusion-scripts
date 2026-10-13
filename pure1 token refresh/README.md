# pure1 token refresh

## refresh_pure1_token.sh

Keeps a Pure1 API access token fresh on macOS, so Claude Desktop, VS Code, Augment, and shell sessions can call the Pure1 API and the Pure1 MCP server without manual re-authentication. Pure1 access tokens expire after 9–10 hours, so schedule the script to run [every 8 hours](#scheduling-every-8-hours).

Each run:

1. Mints a new access token with `pure1_token_factory.py`. It signs a JWT with your private key and exchanges it at the Pure1 OAuth endpoint. The application ID and the key's passphrase come from the macOS keychain, and the key on disk is encrypted.
2. Validates it against `https://api.pure1.purestorage.com/api/1.0/arrays`. On a 401 or 403 it exits and leaves the previous token in place.
3. Writes `export PURE1_ACCESS_TOKEN=...` to `~/.pure1_token.env`
4. Runs `launchctl setenv PURE1_ACCESS_TOKEN ...` so GUI apps see the new token without a restart
5. Self-heals the `Pure1 API` MCP server entry in `claude_desktop_config.json`. If the entry is missing or holds a stale token, it rewrites it (after a timestamped backup, keeping the newest 5) and posts a macOS notification to restart Claude Desktop.

All output is appended to `pure1_token_refresh.log` next to the script. Everything the script creates (token file, log, config backups) is owner-only (`umask 077`).

### Requirements

- macOS. Credentials live in the login keychain via `security`.
- `openssl`, for encrypting the private key during `--set-credentials`
- `bash`, `curl`, and a `python3` with `requests`, `PyJWT`, and `cryptography`. The script picks the first interpreter on the system that can import `requests`.
- A Pure1 API registration: an application ID (`pure1:apikey:...`) and its RSA private key
- `pure1_token_factory.py` in the same folder (see below)
- `npx` on `PATH`, for the `mcp-remote` bridge the Claude Desktop entry uses

### Setup

1. **Register an API key in Pure1.** In Pure1 Manage, go to *Administration > API Registration* and register the public key of an RSA key pair you generated:

   ```sh
   openssl genrsa -out pure1_private_key.pem 2048
   openssl rsa -in pure1_private_key.pem -outform PEM -pubout -out pure1_public_key.pem
   chmod 600 pure1_private_key.pem
   ```

   Note the application ID Pure1 shows after registration.

2. **Get the token factory.** `pure1_token_factory.py` is Pure Storage's sample token-exchange client from the Pure1 API documentation. It's not included here because it's Pure Storage copyrighted code. Put it next to this script.

3. **Store the credentials:**

   ```sh
   chmod +x refresh_pure1_token.sh
   ./refresh_pure1_token.sh --set-credentials
   ```

   It prompts for the application ID and the path to the private key. You can also pass them as `--id pure1:apikey:... --key pure1_private_key.pem`. Then it:

   - encrypts the key with a random passphrase and writes it to `pure1_private_key.enc.pem` next to the script
   - stores the passphrase and the application ID in the login keychain, under the service `pure1-token-refresh`
   - mints a token to verify the pair **before** replacing anything, so a wrong ID or key leaves working credentials untouched
   - finishes with a normal refresh

   After that, delete the unencrypted key or move it offline. The script no longer reads it.

4. **Load the token in your current shell:** `source ~/.pure1_token.env`

### Rotating credentials

If you regenerate the API key in Pure1, for example after it expires or its role changes, run the same command with the new values:

```sh
./refresh_pure1_token.sh --set-credentials --id pure1:apikey:NEW --key new_private_key.pem
```

You never need to update the **access token** by hand. Every run mints a new one from the stored credentials.

The first time a scheduled run reads the keychain, macOS may ask to allow access. Choose **Always Allow**. To override the stored values for one run, set `PURE1_API_KEY` or `PURE1_PRIVATE_KEY`.

### Scheduling

See [Scheduling every 8 hours](#scheduling-every-8-hours) for launchd and cron.

## Windows: refresh_pure1_token.ps1

The PowerShell version does the same job on Windows, using Windows PowerShell 5.1 or PowerShell 7.

| | macOS (`.sh`) | Windows (`.ps1`) |
| --- | --- | --- |
| Credential store | login keychain, service `pure1-token-refresh` | `pure1_credentials.xml` next to the script, encrypted with DPAPI (only your Windows user on that machine can decrypt it) |
| Key encryption | `openssl` | Python `cryptography` (no extra dependency) |
| Token for GUI apps | `launchctl setenv` (picked up without restart) | User-scope environment variable (picked up on next app launch) |
| Claude Desktop config | `~/Library/Application Support/Claude/` | `%APPDATA%\Claude\` |
| Scheduling | launchd (recommended) or cron | Task Scheduler, via `setup_windows_task.ps1` or `schtasks` |

### Setup

Steps 1 and 2 from the macOS setup apply as-is: register an API key in Pure1, and put `pure1_token_factory.py` next to the script. Then:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
.\refresh_pure1_token.ps1 -SetCredentials        # prompts for the ID and key path
```

Then schedule it; see [Scheduling every 8 hours](#scheduling-every-8-hours).

`-SetCredentials` behaves like the macOS version. It encrypts the key, stores the ID and passphrase, verifies them with Pure1 before replacing anything, and then does a normal refresh. To rotate a regenerated API key:

```powershell
.\refresh_pure1_token.ps1 -SetCredentials -ApiKeyId pure1:apikey:NEW -KeyPath .\new_private_key.pem
```

DPAPI ties `pure1_credentials.xml` to your Windows account on that machine. Copying it to another user or PC won't work, so run `-SetCredentials` there instead.

## Scheduling every 8 hours

Pure1 access tokens last 9–10 hours. Running every 8 hours leaves a margin of one to two hours, so each token is replaced before it expires even if a run starts late.

### macOS

| | launchd (recommended) | cron |
| --- | --- | --- |
| Missed runs while the Mac was asleep | Runs on wake | **Skipped**. The token can lapse until the next slot. |
| `launchctl setenv` reaches GUI apps | Yes | Not reliably. cron jobs run outside your login session. The Claude Desktop config and `~/.pure1_token.env` are still updated. |
| Keychain access | Yes | Works while you're logged in. The script names the login keychain explicitly for this. |
| Folder restrictions | None | cron needs Full Disk Access if the script lives in Documents, Desktop, Downloads, or iCloud Drive |

#### Option A: launchd (recommended)

1. Save this as `~/Library/LaunchAgents/com.pure1.token-refresh.plist`, replacing `/path/to` with the folder that holds the script:

   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
     <key>Label</key>             <string>com.pure1.token-refresh</string>
     <key>ProgramArguments</key>
     <array>
       <string>/bin/bash</string>
       <string>/path/to/refresh_pure1_token.sh</string>
     </array>
     <key>StartInterval</key>     <integer>28800</integer>  <!-- every 8 hours -->
     <key>RunAtLoad</key>         <true/>                   <!-- and at login -->
     <key>StandardOutPath</key>   <string>/path/to/pure1_token_refresh.launchd.log</string>
     <key>StandardErrorPath</key> <string>/path/to/pure1_token_refresh_error.log</string>
     <key>KeepAlive</key>         <dict><key>SuccessfulExit</key><false/></dict>
     <key>ThrottleInterval</key>  <integer>300</integer>
   </dict>
   </plist>
   ```

   `KeepAlive` with `SuccessfulExit = false` retries a failed run, and `ThrottleInterval` spaces retries 5 minutes apart.

2. Load it. It runs once immediately, then every 8 hours:

   ```sh
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pure1.token-refresh.plist
   ```

3. Check it:

   ```sh
   launchctl print gui/$(id -u)/com.pure1.token-refresh | grep -E 'state|run interval|last exit'
   tail -5 /path/to/pure1_token_refresh.log
   ```

**Run now:** `launchctl kickstart -k gui/$(id -u)/com.pure1.token-refresh`

**Change the interval** (for example, moving an older 9-hour job to 8 hours): edit `StartInterval`, then reload:

```sh
launchctl bootout gui/$(id -u)/com.pure1.token-refresh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pure1.token-refresh.plist
```

**Remove:**

```sh
launchctl bootout gui/$(id -u)/com.pure1.token-refresh
rm ~/Library/LaunchAgents/com.pure1.token-refresh.plist
```

#### Option B: cron

1. Open your crontab:

   ```sh
   crontab -e
   ```

2. Add this line, replacing `/path/to`. It runs at 00:00, 08:00, and 16:00 local time:

   ```cron
   0 */8 * * * /bin/bash "/path/to/refresh_pure1_token.sh" >/dev/null 2>>"/path/to/pure1_token_refresh_error.log"
   ```

   Standard output is discarded because the script already writes everything to `pure1_token_refresh.log`.

3. Confirm it's installed with `crontab -l`. Then run the script once by hand, so you have a fresh token without waiting for the first slot.

To remove it, run `crontab -e` and delete the line.

cron won't run a slot that falls while the Mac is asleep. On a laptop, that can leave you with an expired token until the next slot, which is why launchd is recommended.

### Windows

#### Option A: `setup_windows_task.ps1` (recommended)

From PowerShell, as your normal user (not Administrator), in the script's folder:

```powershell
.\setup_windows_task.ps1
```

It registers the task `Pure1TokenRefresh`. The task:

- runs immediately, then every 8 hours, as you
- runs only while you're logged on, which DPAPI needs anyway
- catches up on a missed run once the PC is available again
- skips runs while offline
- retries up to 3 times, 5 minutes apart, and won't start a second copy while one is still running

```powershell
Start-ScheduledTask -TaskName Pure1TokenRefresh                           # run now
Get-ScheduledTask   -TaskName Pure1TokenRefresh | Get-ScheduledTaskInfo   # last/next run, result
Unregister-ScheduledTask -TaskName Pure1TokenRefresh -Confirm:$false      # remove
```

#### Option B: `schtasks` (Command Prompt)

If you'd rather not run the setup script, create the task directly from **Command Prompt** (not PowerShell, whose quoting differs). Replace the path:

```bat
schtasks /Create /TN Pure1TokenRefresh /SC HOURLY /MO 8 /RL LIMITED /IT /F ^
  /TR "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"C:\path\to\refresh_pure1_token.ps1\""
```

- `/SC HOURLY /MO 8`: every 8 hours, starting now
- `/IT`: only while you're logged on (needed for DPAPI)
- `/RL LIMITED`: no elevation

`schtasks` can't turn on catching up after a missed run. To enable it, open Task Scheduler, open the task's properties, and on the **Settings** tab check *Run task as soon as possible after a scheduled start is missed*.

```bat
schtasks /Run    /TN Pure1TokenRefresh                 & rem run now
schtasks /Query  /TN Pure1TokenRefresh /V /FO LIST     & rem details
schtasks /Delete /TN Pure1TokenRefresh /F              & rem remove
```

## Security notes

- **The private key is encrypted at rest.** A copied `pure1_private_key.enc.pem` is useless without your keychain, which unlocks when you log in. Never commit either the key or the original unencrypted one.
- **The key passphrase never appears as a command-line argument.** It reaches `security`, `openssl`, and Python through stdin or a pipe, so it doesn't show in `ps`. The short-lived access token is still passed as an argument to `curl`, `launchctl setenv`, and the config patch, so it's briefly visible in the process list.
- **Files created before you adopted this version keep their old permissions.** `umask` only applies to new files, so if `~/.pure1_token.env` or the log already exist, `chmod 600` them once.
- **`launchctl setenv` exposes the token to every GUI app you launch.** That's how this works, but it's broad.
- **Claude Desktop config backups hold old tokens.** Each self-heal leaves a `claude_desktop_config.json.bak.<timestamp>`. The script keeps only the newest 5, and other backup files in that folder are left alone.
- The log records a 20-character token preview, which is mostly the JWT header, not the secret part.
