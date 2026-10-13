# pure1 token refresh

## refresh_pure1_token.sh

Keeps a Pure1 API access token fresh on macOS, so Claude Desktop, VS Code, Augment, and shell sessions can call the Pure1 API and the Pure1 MCP server without manual re-authentication. Pure1 access tokens expire after about 10 hours; schedule this script to run more often than that.

Each run:

1. Mints a new access token with `pure1_token_factory.py` (JWT signed with your private key, exchanged at the Pure1 OAuth endpoint)
2. Validates it against `https://api.pure1.purestorage.com/api/1.0/arrays`. On a 401 or 403 it exits and leaves the previous token in place.
3. Writes `export PURE1_ACCESS_TOKEN=...` to `~/.pure1_token.env`
4. Runs `launchctl setenv PURE1_ACCESS_TOKEN ...` so GUI apps see the new token without a restart
5. Self-heals the `Pure1 API` MCP server entry in `claude_desktop_config.json`. If the entry is missing or holds a stale token, it rewrites it (after a timestamped backup, keeping the newest 5) and posts a macOS notification to restart Claude Desktop.

All output is appended to `pure1_token_refresh.log` next to the script. Everything the script creates (token file, log, config backups) is owner-only (`umask 077`).

### Requirements

- macOS (the token refresh works elsewhere, but `launchctl` and the Claude Desktop self-heal are macOS-specific)
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

3. **Configure the script.** Either edit the two lines at the top:

   ```sh
   PRIVATE_KEY="${PURE1_PRIVATE_KEY:-$SCRIPT_DIR/pure1_private_key.pem}"
   API_KEY="${PURE1_API_KEY:-pure1:apikey:REPLACE_ME}"
   ```

   or set `PURE1_API_KEY` and `PURE1_PRIVATE_KEY` in the environment. The script refuses to run while the placeholder is still set.

4. **Run it once:**

   ```sh
   chmod +x refresh_pure1_token.sh
   ./refresh_pure1_token.sh
   source ~/.pure1_token.env
   ```

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

- **Keep the private key private.** `chmod 600` it, and never commit it.
- **Files created before you adopted this version keep their old permissions.** `umask` only applies to new files, so if `~/.pure1_token.env` or the log already exist, `chmod 600` them once.
- **`launchctl setenv` exposes the token to every GUI app you launch.** That's how this works, but it's broad.
- **Claude Desktop config backups hold old tokens.** Each self-heal leaves a `claude_desktop_config.json.bak.<timestamp>`. The script keeps only the newest 5, and other backup files in that folder are left alone.
- The log records a 20-character token preview, which is mostly the JWT header, not the secret part.
