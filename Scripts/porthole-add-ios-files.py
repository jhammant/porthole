#!/usr/bin/env python3
"""Adds Swift files (and resources: fonts) in iOSClient/ to the Porthole target of iOSClient/Porthole.xcodeproj, the way the project's
own entries are written (a build file, a file reference, the group's children, the Sources phase).
Porthole's files only (docs/porthole-plan.md); a file already listed is left alone.

usage: Scripts/porthole-add-ios-files.py PortholeShell.swift [more.swift ...]
"""
import pathlib
import re
import sys

proj = pathlib.Path(__file__).resolve().parent.parent / "iOSClient/Porthole.xcodeproj/project.pbxproj"
text = proj.read_text()
ids = set(re.findall(r"\b[0-9A-F]{24}\b", text))


def fresh(prefix):
    """A new 24-hex id in the project's own pattern: A1000001 0000000000 00 + prefix + 3 hex digits."""
    for n in range(0x500, 0xFFF):
        candidate = f"A1000001000000000000{prefix}{n:03X}"
        if candidate not in ids:
            ids.add(candidate)
            return candidate
    sys.exit("no free id")


anchor_source = "StreamClient+Clipboard.swift"   # an existing file of the target: its lines show where ours go
anchor_resource = "PrivacyInfo.xcprivacy"        # the same for a resource (a font), in the Resources phase
for name in sys.argv[1:]:
    resource = not name.endswith(".swift")
    anchor, phase = (anchor_resource, "Resources") if resource else (anchor_source, "Sources")
    filetype = "file" if resource else "sourcecode.swift"
    if f"path = \"{name}\";" in text or f"path = {name};" in text:
        print(f"{name}: already in the project")
        continue
    if not (proj.parent.parent / name).exists():
        sys.exit(f"{name}: no such file in iOSClient/")
    build, ref = fresh("B"), fresh("E")
    quoted = f'"{name}"' if re.search(r"[^A-Za-z0-9_.]", name) else name
    lines = text.split("\n")
    out = []
    for line in lines:
        out.append(line)
        if f"/* {anchor} in {phase} */ = {{isa = PBXBuildFile;" in line:
            out.append(f"\t\t{build} /* {name} in {phase} */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};")
        elif f"/* {anchor} */ = {{isa = PBXFileReference;" in line:
            out.append(f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {filetype}; path = {quoted}; sourceTree = \"<group>\"; }};")
        elif re.match(rf"^\t+[0-9A-F]{{24}} /\* {re.escape(anchor)} \*/,$", line):
            out.append(re.sub(r"[0-9A-F]{24} /\*.*\*/", f"{ref} /* {name} */", line))
        elif re.match(rf"^\t+[0-9A-F]{{24}} /\* {re.escape(anchor)} in {phase} \*/,$", line):
            out.append(re.sub(r"[0-9A-F]{24} /\*.*\*/", f"{build} /* {name} in {phase} */", line))
    added = len(out) - len(lines)
    if added != 4:
        sys.exit(f"{name}: expected 4 lines added, got {added}; project left unchanged")
    text = "\n".join(out)
    print(f"{name}: added")
proj.write_text(text)
