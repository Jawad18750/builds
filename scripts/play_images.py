"""Replaces the Google Play listing images of one app, in one edit, and nothing else.

    PLAY_JSON=... python3 scripts/play_images.py <package> <images dir>

<images dir> holds one folder per listing language (e.g. ar), each with an images/ folder in
the supply layout: phoneScreenshots/, sevenInchScreenshots/, tenInchScreenshots/ (PNGs,
uploaded in file-name order) and featureGraphic.png. Each image type found there is cleared
and uploaded again; types that are not there are left as they are. No build, no text, no
track. Prints languages, types and counts only.
"""
import json
import os
import sys
from pathlib import Path

import google_auth_httplib2
from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload, build_http

package, root = sys.argv[1:3]
root = Path(root)
TYPES = ["phoneScreenshots", "sevenInchScreenshots", "tenInchScreenshots"]

creds = service_account.Credentials.from_service_account_info(
    json.loads(os.environ["PLAY_JSON"]),
    scopes=["https://www.googleapis.com/auth/androidpublisher"],
)
base = build_http()
base.timeout = 300
http = google_auth_httplib2.AuthorizedHttp(creds, http=base)
play = build("androidpublisher", "v3", http=http, cache_discovery=False)
edits = play.edits()

langs = sorted(p.name for p in root.iterdir() if (p / "images").is_dir()) if root.is_dir() else []
if not langs:
    sys.exit("no <language>/images folders")

edit = edits.insert(packageName=package, body={}).execute()
eid = edit["id"]
try:
    for lang in langs:
        images = root / lang / "images"
        uploads = [(t, sorted((images / t).glob("*.png"))) for t in TYPES if (images / t).is_dir()]
        feature = images / "featureGraphic.png"
        if feature.is_file():
            uploads.append(("featureGraphic", [feature]))
        for kind, files in uploads:
            if not files:
                continue
            if kind != "featureGraphic" and len(files) > 8:
                sys.exit(f"{lang} {kind}: {len(files)} images, Play takes at most 8")
            edits.images().deleteall(packageName=package, editId=eid, language=lang, imageType=kind).execute()
            for f in files:
                edits.images().upload(packageName=package, editId=eid, language=lang, imageType=kind,
                                      media_body=MediaFileUpload(str(f), mimetype="image/png")).execute()
            print(f"{lang} {kind}: {len(files)}")
    edits.commit(packageName=package, editId=eid).execute()
    print("listing images committed")
except BaseException:
    try:
        edits.delete(packageName=package, editId=eid).execute()
    except Exception:
        pass
    raise
