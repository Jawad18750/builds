"""Release notes for both stores, from the private repository's changelog.

    python3 scripts/release_notes.py <changelog.md> <out dir>

Writes <out>/full.txt (App Store Connect's "What's New": every bullet) and <out>/play.txt
(Google Play's, capped at 500 characters: the leading bullets that fit whole, which is why the
changelog lists the most important first). The file's leading HTML comment is not notes.
"""
import pathlib
import re
import sys

PLAY_MAX = 500

src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = re.sub(r"<!--.*?-->", "", src.read_text(encoding="utf-8"), flags=re.S)
bullets = [line.rstrip() for line in text.splitlines() if line.startswith("- ")]
if not bullets:
    sys.exit(f"no bullets in {src}")

play = ""
for line in bullets:
    candidate = f"{play}\n{line}" if play else line
    if len(candidate) > PLAY_MAX:
        break
    play = candidate
if not play:
    sys.exit(f"the first bullet alone is over {PLAY_MAX} characters")

out.mkdir(parents=True, exist_ok=True)
(out / "full.txt").write_text("\n".join(bullets) + "\n", encoding="utf-8")
(out / "play.txt").write_text(play + "\n", encoding="utf-8")
print(f"notes: {len(bullets)} bullets; Play gets {play.count(chr(10)) + 1} ({len(play)} characters)")
