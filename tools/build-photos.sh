#!/bin/bash
# Builds photos.json and the small thumbnails for the map.
#   - Reads GPS and the date taken from every JPG in photos/ (using macOS mdls).
#   - Writes photos.json (sorted by time taken, in UK local time).
#   - Makes a 480px thumbnail for each photo in photos/thumbs/ (using macOS sips),
#     skipping any that already exist and turning portrait photos upright.
#   - Photos with no GPS are skipped with a warning. Nothing is ever moved or deleted.
# How to run (from anywhere):  bash tools/build-photos.sh
# Run it again whenever you add new photos to photos/.
exec /usr/bin/python3 -I - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import glob, json, os, re, struct, subprocess, sys
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

root = sys.argv[1]
photos_dir = os.path.join(root, "photos")
thumbs_dir = os.path.join(photos_dir, "thumbs")
THUMB_SIZE = 480
UK = ZoneInfo("Europe/London")  # handles BST/GMT automatically
os.makedirs(thumbs_dir, exist_ok=True)

def mdls(path, name):
    """Return one Spotlight value as text, or None if it has none."""
    out = subprocess.run(["mdls", "-name", name, path], capture_output=True, text=True).stdout.strip()
    value = out.split("=", 1)[-1].strip()
    return None if value in ("", "(null)") else value

def exif_orientation(path):
    """Read the EXIF orientation number (1 = upright) straight from the file."""
    try:
        d = open(path, "rb").read(131072)
        t = d.find(b"Exif\0\0") + 6
        e = "<" if d[t:t + 2] == b"II" else ">"
        p = t + struct.unpack(e + "I", d[t + 4:t + 8])[0]
        for k in range(struct.unpack(e + "H", d[p:p + 2])[0]):
            q = p + 2 + 12 * k
            if struct.unpack(e + "H", d[q:q + 2])[0] == 0x112:
                return struct.unpack(e + "H", d[q + 8:q + 10])[0]
    except Exception:
        pass
    return 1

def make_thumb(src, dest):
    """Resize with sips, rotate pixels upright, then mark the thumbnail as upright."""
    rotate = {3: 180, 6: 90, 8: 270}.get(exif_orientation(src))
    cmd = ["sips", "-Z", str(THUMB_SIZE), "-s", "format", "jpeg", "-s", "formatOptions", "75"]
    if rotate:
        cmd += ["-r", str(rotate)]
    r = subprocess.run(cmd + [src, "--out", dest], capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(dest):
        print("WARNING: could not make a thumbnail for", os.path.basename(src))
        return
    # sips keeps the old orientation tag, so set it to 1 or browsers would rotate it twice.
    data = bytearray(open(dest, "rb").read())
    t = data.find(b"Exif\0\0") + 6
    if t >= 6:
        e = "<" if data[t:t + 2] == b"II" else ">"
        p = t + struct.unpack(e + "I", data[t + 4:t + 8])[0]
        for k in range(struct.unpack(e + "H", data[p:p + 2])[0]):
            q = p + 2 + 12 * k
            if struct.unpack(e + "H", data[q:q + 2])[0] == 0x112:
                data[q + 8:q + 10] = struct.pack(e + "H", 1)
        open(dest, "wb").write(data)

entries, made = [], 0
files = sorted(f for f in os.listdir(photos_dir)
               if f.lower().endswith((".jpg", ".jpeg")) and os.path.isfile(os.path.join(photos_dir, f)))
for name in files:
    path = os.path.join(photos_dir, name)
    lat, lng = mdls(path, "kMDItemLatitude"), mdls(path, "kMDItemLongitude")
    when = mdls(path, "kMDItemContentCreationDate")  # in UTC
    if lat is None or lng is None:
        print("WARNING: no GPS, skipped:", name)
        continue
    if when is None:
        print("WARNING: no date taken, skipped:", name)
        continue
    taken = datetime.strptime(when, "%Y-%m-%d %H:%M:%S %z").astimezone(UK)
    entries.append({"file": name, "lat": round(float(lat), 6), "lng": round(float(lng), 6),
                    "taken": taken.isoformat()})
    thumb = os.path.join(thumbs_dir, name + ".jpg")
    if not os.path.exists(thumb):
        make_thumb(path, thumb)
        made += 1

entries.sort(key=lambda x: (x["taken"] and datetime.fromisoformat(x["taken"]), x["file"]))
with open(os.path.join(root, "photos.json"), "w") as f:
    f.write("[\n" + ",\n".join("  " + json.dumps(x) for x in entries) + "\n]\n")
print("photos.json: %d photos, %d new thumbnails" % (len(entries), made))
PY
