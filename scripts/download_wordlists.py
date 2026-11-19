"""Download public study lists and convert them to WordsMemory UTF-8 TXT."""
import hashlib
import io
import json
import re
import urllib.request
import zipfile
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "wordlists"
BOOKS = [
    ("CET4_2", "四级_有道_正序", "1521164635506", 3739),
    ("CET4_3", "四级_新东方", "1521164643060", 2607),
    ("CET6_2", "六级_有道", "1524052554766", 2078),
    ("CET6_3", "六级_新东方", "1521164633851", 2345),
    ("IELTS_2", "雅思_有道_正序", "1521164657744", 3427),
    ("IELTS_3", "雅思_新东方", "1521164666922", 3575),
]


def clean(value):
    return re.sub(r"\s+", " ", str(value or "")).strip()


def main():
    ROOT.mkdir(exist_ok=True)
    sources = ROOT / "_sources"
    sources.mkdir(exist_ok=True)
    manifest = []
    for book_id, name, stamp, expected in BOOKS:
        archive_name = f"{stamp}_{book_id}.zip"
        url = f"https://raw.githubusercontent.com/kajweb/dict/master/book/{archive_name}"
        archive_path = sources / archive_name
        if archive_path.exists():
            data = archive_path.read_bytes()
        else:
            request = urllib.request.Request(url, headers={"User-Agent": "WordsMemory-study-download"})
            with urllib.request.urlopen(request, timeout=90) as response:
                data = response.read()
            # Check the response is an archive before saving it.
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                assert archive.testzip() is None
            archive_path.write_bytes(data)
        rows = []
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            files = [n for n in archive.namelist() if n.endswith(".json") and not n.startswith("__MACOSX/")]
            assert len(files) == 1, files
            content = archive.read(files[0]).decode("utf-8-sig")
            for line in content.splitlines():
                if not line.strip():
                    continue
                entry = json.loads(line)
                word = clean(entry["headWord"]).lower()
                translations = entry["content"]["word"]["content"].get("trans", [])
                meanings = []
                for translation in translations:
                    meaning = clean(translation.get("tranCn"))
                    pos = clean(translation.get("pos"))
                    if meaning:
                        meanings.append(f"{pos.rstrip('.')}. {meaning}" if pos else meaning)
                assert word and meanings, entry.get("wordRank")
                rows.append(f"{word}\t{'；'.join(meanings)}\t\t")
        assert len(rows) == expected, (book_id, len(rows), expected)
        filename = f"{name}_{len(rows)}词.txt"
        output = ROOT / filename
        output.write_text("word\tmeaning\tfrequency\tsenseKey\n" + "\n".join(rows) + "\n", encoding="utf-8")
        parsed = output.read_text(encoding="utf-8").splitlines()
        assert len(parsed) == expected + 1
        assert all(len(row.split("\t")) == 4 for row in parsed)
        manifest.append({"file": filename, "book_id": book_id, "entries": len(rows), "unique_words": len({r.split('\t')[0] for r in rows}), "source": url, "source_sha256": hashlib.sha256(data).hexdigest(), "txt_sha256": hashlib.sha256(output.read_bytes()).hexdigest()})
        print(f"{filename}: {len(rows)} entries", flush=True)
    (ROOT / "sources.json").write_text(json.dumps({"downloaded": str(date.today()), "repository": "https://github.com/kajweb/dict", "files": manifest}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
