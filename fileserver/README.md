# fileserver

Minimal HTTP file server for **hands-on-metal** — download files with
`curl` / `wget` and upload files with `curl -F`.  Zero dependencies beyond
the Python standard library.

---

## Quick start

```bash
# Start the server (creates ./files/ automatically)
python fileserver/server.py

# Or customise host, port, and storage directory
python fileserver/server.py --host 127.0.0.1 --port 9000 --dir /tmp/my-share
```

The server prints its URLs on start-up:

```
hands-on-metal file server listening on http://0.0.0.0:8080
  Storage directory : /home/user/hands-on-metal/files
  Max upload size   : 500 MB

  Download : curl  http://0.0.0.0:8080/<filename> -o <filename>
             wget  http://0.0.0.0:8080/<filename>
  Upload   : curl -F "file=@<filename>" http://0.0.0.0:8080/upload
  List     : curl  http://0.0.0.0:8080/
```

---

## Usage

### Upload a file

```bash
curl -F "file=@diagnostic_bundle.zip" http://localhost:8080/upload
# OK — saved as diagnostic_bundle.zip (14,230 bytes)
```

If a file with the same name already exists, a timestamp suffix is appended
automatically to prevent overwrites.

### Download a file

```bash
# curl
curl http://localhost:8080/diagnostic_bundle.zip -o diagnostic_bundle.zip

# wget
wget http://localhost:8080/diagnostic_bundle.zip
```

### List available files

```bash
# Human-readable (works in a browser too)
curl http://localhost:8080/
```

---

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `--host` | `0.0.0.0` | Bind address |
| `--port` | `8080` | Listen port |
| `--dir` | `./files` | Directory to serve / store uploads |
| `--max-upload` | `524288000` (500 MB) | Maximum upload size in bytes |

---

## Integration with hands-on-metal

After collecting a diagnostic bundle on-device, you can push it straight to
a file server running on your PC:

```bash
# On the PC — start the server
python fileserver/server.py --dir ./incoming

# On the device (via Termux or adb shell) — upload the bundle
curl -F "file=@/sdcard/hands-on-metal/share/20250417T120000Z/share_bundle.json" \
     http://<PC_IP>:8080/upload
```

Then pull it down from any other machine:

```bash
curl http://<PC_IP>:8080/share_bundle.json -o share_bundle.json
```
