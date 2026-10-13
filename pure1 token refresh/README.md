# pure1 token refresh

## refresh_pure1_token.sh

Keeps a Pure1 API access token fresh on macOS, so Claude Desktop, VS Code, Augment, and shell sessions can call the Pure1 API and the Pure1 MCP server without manual re-authentication. Pure1 access tokens expire after about 10 hours; schedule this script to run more often than that.

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

The first time launchd's run reads the keychain, macOS may ask to allow access. Choose **Always Allow**. To override the stored values for one run, set `PURE1_API_KEY` or `PURE1_PRIVATE_KEY`.

### Scheduling with launchd

Save as `~/Library/LaunchAgents/com.pure1.token-refresh.plist`, replacing `/path/to` with this folder:

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
  <key>StartInterval</key>     <integer>32400</integer>  <!-- every 9 hours -->
  <key>RunAtLoad</key>         <true/>
  <key>StandardOutPath</key>   <string>/path/to/pure1_token_refresh.launchd.log</string>
  <key>StandardErrorPath</key> <string>/path/to/pure1_token_refresh_error.log</string>
  <key>KeepAlive</key>         <dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key>  <integer>300</integer>
</dict>
</plist>
```

```sh
launchctl load ~/Library/LaunchAgents/com.pure1.token-refresh.plist
launchctl list | grep pure1
# uninstall
launchctl unload ~/Library/LaunchAgents/com.pure1.token-refresh.plist
```

`KeepAlive` with `SuccessfulExit = false` retries failed runs, and `ThrottleInterval` spaces those retries 5 minutes apart.

### Security notes

- **The private key is encrypted at rest.** A copied `pure1_private_key.enc.pem` is useless without your keychain, which unlocks when you log in. Never commit either the key or the original unencrypted one.
- **The key passphrase never appears as a command-line argument.** It reaches `security`, `openssl`, and Python through stdin or a pipe, so it doesn't show in `ps`. The short-lived access token is still passed as an argument to `curl`, `launchctl setenv`, and the config patch, so it's briefly visible in the process list.
- **Files created before you adopted this version keep their old permissions.** `umask` only applies to new files, so if `~/.pure1_token.env` or the log already exist, `chmod 600` them once.
- **`launchctl setenv` exposes the token to every GUI app you launch.** That's how this works, but it's broad.
- **Claude Desktop config backups hold old tokens.** Each self-heal leaves a `claude_desktop_config.json.bak.<timestamp>`. The script keeps only the newest 5, and other backup files in that folder are left alone.
- The log records a 20-character token preview, which is mostly the JWT header, not the secret part.
