"""Uploads an Android App Bundle to Google Play and releases it on a track, in one edit.

    PLAY_JSON=... python3 scripts/play_release.py <package> <aab> <track> <version name> \
        <version code> <notes file>

A code Play already holds (a retried run) is not uploaded again; otherwise the code Play reads
out of the uploaded bundle must be the one expected. The track is set to that one
code at 100% ("completed") with the notes in Arabic, and the edit is committed; Play then
reviews it as usual. Prints codes and states only.
"""
import json
import os
import sys

import google_auth_httplib2
from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload, build_http

package, aab, track, version_name, expected, notes_path = sys.argv[1:7]
expected = int(expected)
notes = open(notes_path, encoding="utf-8").read().strip()
if not notes:
    sys.exit("no release notes")

creds = service_account.Credentials.from_service_account_info(
    json.loads(os.environ["PLAY_JSON"]),
    scopes=["https://www.googleapis.com/auth/androidpublisher"],
)
# build_http, not a bare httplib2.Http: a resumable upload answers each chunk with 308
# "Resume Incomplete", and only the client's own Http stops treating 308 as a redirect
# (a bare one fails with RedirectMissingLocation on the first chunk).
base = build_http()
base.timeout = 600
http = google_auth_httplib2.AuthorizedHttp(creds, http=base)
play = build("androidpublisher", "v3", http=http, cache_discovery=False)
edits = play.edits()

edit = edits.insert(packageName=package, body={}).execute()
eid = edit["id"]
try:
    held = {int(b["versionCode"]) for b in
            edits.bundles().list(packageName=package, editId=eid).execute().get("bundles", [])}
    if expected in held:
        code = expected
        print(f"version code {code} is already on Play: not uploaded again")
    else:
        media = MediaFileUpload(aab, mimetype="application/octet-stream", resumable=True,
                                chunksize=32 * 1024 * 1024)
        request = edits.bundles().upload(packageName=package, editId=eid, media_body=media)
        response = None
        last = -1
        while response is None:
            status, response = request.next_chunk(num_retries=5)
            if status:
                pct = int(status.progress() * 100)
                if pct // 10 != last // 10:
                    print(f"upload {pct}%", flush=True)
                    last = pct
        code = int(response["versionCode"])
        print(f"bundle uploaded: version code {code}")
        if code != expected:
            sys.exit(f"Play read version code {code} from the bundle, expected {expected}")

    edits.tracks().update(
        packageName=package, editId=eid, track=track,
        body={
            "track": track,
            "releases": [{
                "name": version_name,
                "versionCodes": [str(code)],
                "status": "completed",
                "releaseNotes": [{"language": "ar", "text": notes}],
            }],
        },
    ).execute()
    edits.commit(packageName=package, editId=eid).execute()
    print(f"{package} {version_name} ({code}) released on {track}")
except Exception:
    try:
        edits.delete(packageName=package, editId=eid).execute()
    except Exception:
        pass
    raise
