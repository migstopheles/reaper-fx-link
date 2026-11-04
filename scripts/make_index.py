#!/usr/bin/env python3
"""Generates/updates the ReaPack repository index (index.xml) for a release.

Reads the reapack-index style metadata header of "FX Link.lua" (@version, @changelog, @provides,
@about, ...) from a git commit, and adds that version to index.xml with download URLs pinned to
the commit. Previously released versions are kept, as ReaPack expects.

Usage (see README "Releasing"):  python3 scripts/make_index.py [--commit SHA]
"""

import argparse
import fnmatch
import hashlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parent.parent
INDEX = ROOT / "index.xml"
MAIN_SCRIPT = "FX Link.lua"
REPO_NAME = "FX Link"
CATEGORY = "FX"


def git(*args, binary=False):
    out = subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True)
    return out.stdout if binary else out.stdout.decode().strip()


def parse_header(text):
    """Parses '-- @tag value' lines plus indented continuation lines."""
    tags, current = {}, None
    for line in text.splitlines():
        if not line.startswith("--"):
            break
        body = line[2:]
        match = re.match(r"\s*@(\w+)\s*(.*)$", body)
        if match:
            current = match.group(1)
            tags.setdefault(current, []).append(match.group(2).rstrip())
        elif current:
            tags[current].append(body.rstrip())

    def block(name):
        lines = tags.get(name, [])
        first, rest = (lines[0] if lines else ""), lines[1:]
        indents = [len(l) - len(l.lstrip()) for l in rest if l.strip()]
        cut = min(indents) if indents else 0
        return "\n".join([first] + [l[cut:] for l in rest]).strip()

    return tags, block


def markdown_to_rtf(markdown):
    """Minimal Markdown (headings, bullets, paragraphs) to RTF for ReaPack's about dialog."""

    def esc(text):
        text = text.replace("\\", "\\\\").replace("{", "\\{").replace("}", "\\}")
        text = re.sub(r"\*\*(.+?)\*\*", r"{\\b \1}", text)
        return "".join(c if ord(c) < 128 else f"\\u{ord(c)}?" for c in text)

    parts, paragraph = [], []

    def flush():
        if paragraph:
            parts.append(esc(" ".join(paragraph)) + "\\par\\par")
            paragraph.clear()

    for line in markdown.splitlines():
        stripped = line.strip()
        if not stripped:
            flush()
        elif stripped.startswith("#"):
            flush()
            parts.append("{\\b\\fs28 " + esc(stripped.lstrip("#").strip()) + "}\\par\\par")
        elif stripped.startswith(("- ", "* ")):
            flush()
            parts.append("\\bullet  " + esc(stripped[2:]) + "\\par")
        else:
            paragraph.append(stripped)
    flush()

    return "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0\\fswiss Helvetica;}}\\f0\\fs20\n" + "\n".join(parts) + "\n}"


def github_base():
    url = git("remote", "get-url", "origin")
    match = re.search(r"github\.com[:/](.+?)/(.+?)(\.git)?$", url)
    if not match:
        sys.exit(f"origin is not a GitHub remote: {url}")
    return f"https://github.com/{match.group(1)}/{match.group(2)}"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--commit", default="HEAD", help="commit to release (default: HEAD)")
    parser.add_argument("--skip-push-check", action="store_true",
                        help="don't require the commit to be on origin (URLs won't work until it is)")
    args = parser.parse_args()

    sha = git("rev-parse", args.commit)
    if not args.skip_push_check:
        git("fetch", "--quiet", "origin")
        if not git("branch", "-r", "--contains", sha):
            sys.exit(f"Commit {sha[:8]} is not on origin yet. Push it first, then re-run.")

    tags, block = parse_header(git("show", f"{sha}:{MAIN_SCRIPT}"))
    version = block("version")
    changelog = block("changelog")
    if not version or not changelog:
        sys.exit(f"{MAIN_SCRIPT} at {sha[:8]} needs @version and @changelog.")

    base = github_base()
    tree = git("ls-tree", "-r", "--name-only", sha).splitlines()

    # (path in repo, attributes) for every file of the package
    files = [(MAIN_SCRIPT, {"main": "main"})]
    for line in block("provides").splitlines():
        line = line.strip()
        if not line:
            continue
        main = re.match(r"\[(main[^\]]*)\]\s*(.+)$", line)
        pattern = main.group(2) if main else line
        matches = sorted(p for p in tree if fnmatch.fnmatchcase(p, pattern))
        if not matches:
            sys.exit(f"@provides pattern matched nothing at {sha[:8]}: {pattern}")
        for path in matches:
            attrs = {"file": path}
            if main:
                attrs["main"] = main.group(1).replace("main=", "") or "main"
            files.append((path, attrs))

    # Load the existing index (to keep old versions) or start a new one.
    if INDEX.exists():
        index = ET.parse(INDEX).getroot()
    else:
        index = ET.Element("index", {"version": "1", "name": REPO_NAME})
    index.set("commit", sha)

    category = index.find(f"category[@name='{CATEGORY}']")
    if category is None:
        category = ET.SubElement(index, "category", {"name": CATEGORY})

    package = category.find(f"reapack[@name='{MAIN_SCRIPT}']")
    if package is None:
        package = ET.SubElement(category, "reapack", {"name": MAIN_SCRIPT, "type": "script"})
    package.set("desc", block("description"))

    if package.find(f"version[@name='{version}']") is not None:
        sys.exit(f"Version {version} is already in index.xml. Bump @version in {MAIN_SCRIPT}.")

    # Package metadata (about dialog) always reflects the latest release.
    for old in package.findall("metadata"):
        package.remove(old)
    metadata = ET.Element("metadata")
    for link in tags.get("link", []):
        name, _, url = link.rpartition(" ")
        ET.SubElement(metadata, "link", {"rel": "website", "href": url}).text = name or url
    if block("about"):
        ET.SubElement(metadata, "description").text = markdown_to_rtf(block("about"))
    package.insert(0, metadata)

    committed = datetime.fromisoformat(git("show", "-s", "--format=%cI", sha)).astimezone(timezone.utc)
    version_el = ET.SubElement(package, "version", {
        "name": version,
        "author": block("author"),
        "time": committed.strftime("%Y-%m-%dT%H:%M:%SZ"),
    })
    ET.SubElement(version_el, "changelog").text = changelog
    for path, attrs in files:
        content = git("show", f"{sha}:{path}", binary=True)
        attrs["hash"] = "1220" + hashlib.sha256(content).hexdigest()
        source = ET.SubElement(version_el, "source", attrs)
        source.text = f"{base}/raw/{sha}/{quote(path)}"

    if index.find("metadata") is None:
        repo_meta = ET.SubElement(index, "metadata")
        ET.SubElement(repo_meta, "link", {"rel": "website"}).text = base

    ET.indent(index, space="  ")
    INDEX.write_text('<?xml version="1.0" encoding="utf-8"?>\n' + ET.tostring(index, encoding="unicode") + "\n",
                     encoding="utf-8")
    print(f"index.xml: added {MAIN_SCRIPT} v{version} ({len(files)} files) at {sha[:8]}.")
    print("Now commit index.xml and push.")


if __name__ == "__main__":
    main()
