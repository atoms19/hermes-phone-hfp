# Running Hermes Phone in Docker (dev setup)

Current local setup: the HFP daemon runs in a container and uses the host's
BlueZ over the system D-Bus socket. A small stand-in for the Hermes gateway
(`stub_hermes.py`) answers the handshake the daemon needs before it starts voice.
The stand-in gives the assistant **no tools**: conversation only.

## Files

| File | Purpose |
| --- | --- |
| `docker/Dockerfile.hfp` | Daemon image (`hfp-daemon:dev`) |
| `docker/call.sh` | Start an outgoing call |
| `~/.config/hfp-mcp-docker.env` | Secrets and addresses (mode 600, not in the repo) |
| `~/hfp-test/config.yaml` | Routing config mounted into the daemon |
| `~/hfp-test/stub_hermes.py` | Test-only stand-in for the Hermes gateway |

The env file holds `HFP_GEMINI_API_KEY`, `HFP_MCP_BEARER_TOKEN`,
`HFP_ADAPTER_ADDRESS`, `HFP_PHONE_ADDRESS`, `HFP_HERMES_API_KEY`,
`HFP_HERMES_BRIDGE_KEY` and `HFP_MCP_CONFIG=/config/config.yaml`.
Add `HFP_FULL_TRANSCRIPTS=true` to save call text (off by default).

## Host prerequisites

- `bluetooth.service` active and the adapter powered: `bluetoothctl show | grep Powered`
- WirePlumber override so it does not own the HFP profile:
  `~/.config/wireplumber/wireplumber.conf.d/90-hfp-mcp.conf`
  (copy of `setup/90-hfp-mcp.conf`), then `systemctl --user restart wireplumber`
- The phone paired and trusted, with call audio enabled for this connection

## Build the image

```bash
docker build -f docker/Dockerfile.hfp -t hfp-daemon:dev .
```

Rebuild after changing anything under `src/`.

## Start

```bash
# 1. Hermes stand-in
docker run -d --name hfp-stub --network host \
  --env-file ~/.config/hfp-mcp-docker.env \
  -v ~/hfp-test/stub_hermes.py:/stub.py:ro \
  --entrypoint python hfp-daemon:dev /stub.py

# 2. Daemon
docker run -d --name hfp-dev --network host \
  -v /run/dbus/system_bus_socket:/run/dbus/system_bus_socket \
  -v hfp-dev-data:/data \
  -v ~/hfp-test/config.yaml:/config/config.yaml:ro \
  --env-file ~/.config/hfp-mcp-docker.env hfp-daemon:dev
```

Connect the phone if it did not reconnect by itself:

```bash
bluetoothctl connect <PHONE_BT_ADDRESS>
```

## Check it is running

```bash
docker ps --filter name=hfp
docker logs --tail 10 hfp-dev          # want: "HFP connected to <PHONE_BT_ADDRESS>"
ss -ltn | grep -E ':8000|:8642'        # daemon 8000, stand-in 8642
```

State (token read from the env file, nothing printed):

```bash
tok=$(grep ^HFP_MCP_BEARER_TOKEN ~/.config/hfp-mcp-docker.env | cut -d= -f2)
curl -s -H "Authorization: Bearer $tok" http://127.0.0.1:8000/v1/state | python3 -m json.tool | head -40
```

## Restart and stop

```bash
docker restart hfp-dev        # after config or env changes, or if it exited
docker start hfp-dev          # if it is stopped
docker stop hfp-dev           # stop answering/handling calls
```

Config changes are only read at start, so restart after editing
`~/hfp-test/config.yaml`. Recreate the container (`docker rm -f hfp-dev`, then
the `docker run` above) if you change mounts or the env file.

The daemon exits when BlueZ disappears from the bus (Bluetooth service restart
or adapter reset). Start it again with `docker start hfp-dev`. It has no restart
policy; add `--restart unless-stopped` to the `docker run` to bring it back
automatically.

## Make a call

```bash
./docker/call.sh "+91XXXXXXXXXX" "Instructions for this call"
```

Use the full international number. The second argument is the brief (up to 4,000
characters); it is where the assistant's name and purpose go. `{"ok":true,...}`
means the call went out and voice is ready.

## Incoming calls

The default config answers nothing: `auto_answer: false`, no routes. To answer
every caller (conversation only, no tools), set `auto_answer: true` and add a
`default` route:

```yaml
phone:
  auto_answer: true
  policies:
    guest:
      admin: false
      tools: [hfp_caller_read, hfp_caller_update]
      remember: false
      max_minutes: 5
  default:
    endpoint: stub
    policy: guest
    voice: gemini_live
```

Keep the existing `version`, `default_region` and `endpoints` keys. Validate, then
restart:

```bash
docker run --rm --env-file ~/.config/hfp-mcp-docker.env \
  -v ~/hfp-test/config.yaml:/config/config.yaml:ro \
  --entrypoint hfp-mcp hfp-daemon:dev route validate
docker restart hfp-dev
```

While the phone is connected and the container runs, every caller is answered.
To answer only specific numbers, list them under `numbers:` and omit `default`.

Normal calls you place or answer on the phone stay on the phone. Audio goes to the
daemon only for calls it handles itself.

## Transcripts

Requires `HFP_FULL_TRANSCRIPTS=true` in the env file, then a recreate of `hfp-dev`.

```bash
docker exec hfp-dev hfp-mcp transcript list
docker exec hfp-dev hfp-mcp transcript show <call_id>
```

Without the setting the daemon returns 403 and saves no call text.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Connection refused on `127.0.0.1:8000` | Container is stopped. `docker start hfp-dev`, then read `docker logs`. |
| `org.bluez disappeared from the system bus` | Bluetooth service restarted. `docker start hfp-dev`. |
| `Gemini startup failed` | Usually a symptom. Check `live_ai.last_error` in `/v1/state`; often the SCO link did not come up. |
| `Could not establish SCO audio link ... timed out`, `SCO ... Connection reset by peer` | Adapter or phone dropped the audio link. Hang up, `bluetoothctl disconnect` then `connect` the phone, retry. Kernel hints: `journalctl -k --since -30min \| grep -i sco`. |
| `403 Forbidden` on transcripts | Transcripts are off; see above. |
| Call audio stays on the phone | The daemon is not handling that call; see "Incoming calls". |
| Headset mode stops working on the host | Expected while the WirePlumber override is installed. A2DP music is unaffected. |

## Undo the host changes

```bash
docker rm -f hfp-dev hfp-stub
rm ~/.config/wireplumber/wireplumber.conf.d/90-hfp-mcp.conf
systemctl --user restart wireplumber
bluetoothctl untrust <PHONE_BT_ADDRESS>
```

`docker volume rm hfp-dev-data` also deletes the daemon's saved state.
