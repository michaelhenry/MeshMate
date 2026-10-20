# MeshMate

An iOS companion app for **MeshCore** LoRa radios (built and tested against the Heltec WiFi LoRa 32 **V4** running *Companion Radio – BLE* firmware).

It speaks the MeshCore companion protocol directly over Bluetooth LE (Nordic UART service), matching firmware **v1.18 / protocol v14**.

## Features

| Area | What you can do |
| --- | --- |
| **Connection** | Scan & connect over BLE (iOS handles PIN pairing), auto-reconnect with backoff, background BLE, built-in **demo radio** for the Simulator |
| **Chats** | Direct messages with delivery ACKs, round-trip time, automatic retries (final retry floods), byte counter (160 B limit), hops/SNR per message, unread badges, local notifications, offline history |
| **Channels** | Public, **hashtag** (`#name` → SHA-256 key), and **private** channels (random key); join via QR / `meshcore://channel/add` link; share as QR; remove (frees the slot) |
| **Room servers** | Log in (password saved in Keychain), read & post; posts show the original author |
| **Repeaters & sensors** | Admin/guest login, status (battery, uptime, noise floor, RSSI/SNR, packet counters, airtime, duplicates), telemetry (Cayenne LPP decoded), neighbour list with SNR, access list, **remote CLI console** |
| **Contacts** | Filter/sort/search, favourites, add via QR/link, import signed adverts, manual-add mode with “Heard adverts” inbox, remove, my contact QR |
| **Routing tools** | Path discovery (and “use this path”), **trace route** with per-hop SNR, last advert path, manual route editing, reset to flood, zero-hop contact sharing |
| **Discovery** | Zero-hop node discovery (repeaters/sensors in range with SNR both ways), send advert (nearby or flood) |
| **Map** | Contacts with positions, distance from you, jump to chat/details |
| **Radio settings** | Community presets (fetched live from meshcore.nz, bundled fallback), frequency/BW/SF/CR, TX power, client repeat (allowed bands), path hash size |
| **Identity** | Name, position (manual or from iPhone GPS), include location in adverts |
| **Privacy** | Auto-add rules per node type, overwrite-oldest, max hops, telemetry permissions (base/location/environment), extra ACKs |
| **Advanced** | RX delay/airtime tuning, flood scope / regions (default + per-session, or unscoped), BLE PIN, board variables (e.g. GPS on/off) |
| **Tools** | Live stats (core/radio/packets), own telemetry, live **RX log** with packet type/route/path decoding, local radio CLI console (v14+), clock sync |
| **Keys** | Export / import identity key, sign data with the radio's key |
| **Danger zone** | Reboot, factory reset, disconnect, forget radio |

## Notes

- Messages are stored on the phone; the radio only queues messages while the app is disconnected.
- Hashtag channels are public: anyone who knows the name can derive the key.
- Private key export/import only works if the firmware was built with `ENABLE_PRIVATE_KEY_EXPORT/IMPORT`; otherwise the app says so.
- “MeshCore” is the open-source project at <https://github.com/meshcore-dev/MeshCore>; this app is an independent client.
