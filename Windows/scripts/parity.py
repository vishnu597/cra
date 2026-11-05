#!/usr/bin/env python3 -I
"""Keeps Windows/PARITY.md honest: every Mac feature has a row, and every upstream change has
been looked at.

  parity.py check [--upstream REF] [--base REF]
      Fails when
        - a Mac source file (Sources/Cra, Sources/CraCEF, Sources/CraHelper) or a CraCore source
          file is not named in PARITY.md, so a feature upstream added has no row yet;
        - a Mac command (KeyBindingDefaults.mac) or Settings pane Windows doesn't have yet is
          not named in PARITY.md;
        - with --upstream, main has merged upstream commits newer than the
          "upstream-reviewed" marker in PARITY.md (a sync that didn't update the tracker).
      With --base, warns (doesn't fail) when Windows/Sources changed and PARITY.md didn't.

  parity.py summary [--write]
      The status counts per area, from the rows; --write puts them in PARITY.md between the
      summary markers. check fails when the counts there are out of date.

  parity.py report [--upstream REF]
      Markdown for a CI summary: upstream commits after the marker (to triage), the Mac
      commands and Settings panes Windows doesn't have, and the CraCore types the Windows app
      doesn't use yet.

Names count when they appear in backticks: `MainWindowController.swift`, `SidebarStore`,
`toggleSidebar`, `privacy`. Digit-suffixed commands are written with N: `spaceN`.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PARITY = os.path.join(ROOT, "Windows", "PARITY.md")
CORE = os.path.join(ROOT, "Packages", "CraCore", "Sources", "CraCore")
MAC_DIRS = [os.path.join(ROOT, "Sources", d) for d in ("Cra", "CraCEF", "CraHelper")]
WIN_SOURCES = os.path.join(ROOT, "Windows", "Sources")
KEYS = os.path.join(CORE, "KeyBindingDefaults.swift")
PANES = os.path.join(CORE, "SettingsNavigation.swift")
STATUSES = ["✅", "🟡", "🔜", "❌", "➖"]
SUMMARY = re.compile(r"(<!-- summary:[^>]*-->\n)(.*?)(<!-- /summary -->)", re.S)
MARKER = re.compile(r"<!--\s*upstream-reviewed:\s*([0-9a-f]{7,40})\s*-->")
SOURCE_EXT = (".swift", ".mm", ".h", ".cc", ".cpp")


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def git(*args):
    return subprocess.run(["git", "-C", ROOT, *args], capture_output=True, text=True)


def named(doc):
    """Everything written in backticks in PARITY.md."""
    return set(re.findall(r"`([^`\n]+)`", doc))


def files_under(top, exts):
    out = []
    for d, _, files in os.walk(top):
        out += [os.path.join(d, f) for f in files if f.endswith(exts)]
    return sorted(out)


def mac_files():
    return [os.path.basename(p) for top in MAC_DIRS for p in files_under(top, SOURCE_EXT)]


def core_names():
    return [os.path.splitext(os.path.basename(p))[0] for p in files_under(CORE, (".swift",))]


def normalize(action_id):
    return re.sub(r"\\\(n\)$|\d$", "N", action_id)


def block(text, start, end):
    i = text.index(start)
    return text[i:text.index(end, i)]


def mac_actions():
    src = read(KEYS)
    mac = block(src, "public static let mac:", "public static let windows:")
    ids = [normalize(m) for m in re.findall(r'KeyAction\(id: "([^"]+)"', mac)]
    return list(dict.fromkeys(ids))


def windows_actions():
    src = read(KEYS)
    table = block(src, "public static let windowsShortcuts:", "return table")
    ids = re.findall(r'^\s*"([A-Za-z]+)":\s*\[', table, re.M)
    ids += [normalize(m) for m in re.findall(r'table\["([^"]+)"\]', table)]
    return set(ids)


def panes():
    src = read(PANES)
    every = re.search(r"case ((?:\w+, )*\w+)\n", block(src, "enum SettingsPane", "public var id")).group(1).split(", ")
    win = re.findall(r"\.(\w+)", re.search(r"windowsPanes: \[SettingsPane\] = \[([^\]]*)\]", src).group(1))
    return every, set(win)


def missing_on_windows():
    acts = [a for a in mac_actions() if a not in windows_actions()]
    every, win = panes()
    return acts, [p for p in every if p not in win]


def marker(doc):
    m = MARKER.search(doc)
    return m.group(1) if m else None


def unreviewed(doc, upstream, merged_only):
    """Upstream commits after the marker: those main has merged, or every one upstream has."""
    mark = marker(doc)
    if not mark:
        return None, "PARITY.md has no <!-- upstream-reviewed: <sha> --> marker"
    if git("cat-file", "-e", mark + "^{commit}").returncode:
        return None, f"the upstream-reviewed commit {mark} isn't in this clone (fetch upstream)"
    tip = upstream
    if merged_only:
        base = git("merge-base", "HEAD", upstream)
        if base.returncode:
            return None, f"no merge base between HEAD and {upstream}"
        tip = base.stdout.strip()
    log = git("log", "--reverse", "--format=%h %s", f"{mark}..{tip}")
    return [l for l in log.stdout.splitlines() if l], None


def summary_table(doc):
    """Counts each area's rows by the status that opens their Windows column."""
    rows, area = [], None
    for line in doc.splitlines():
        if line.startswith("## "):
            area = line[3:].strip()
            rows.append([area] + [0] * len(STATUSES))
        elif area and line.startswith("| ") and not line.startswith(("| Feature", "| Commit", "| Area")):
            cells = [c.strip() for c in line.strip("|").split("|")]
            status = next((st for st in STATUSES if len(cells) > 1 and cells[1].startswith(st)), None)
            if status:
                rows[-1][1 + STATUSES.index(status)] += 1
    rows = [r for r in rows if sum(r[1:])]
    total = ["**All**"] + [sum(r[i] for r in rows) for i in range(1, len(STATUSES) + 1)]
    lines = ["| Area | " + " | ".join(STATUSES) + " |", "|---|" + "--:|" * len(STATUSES)]
    lines += ["| " + " | ".join(str(c) for c in r) + " |" for r in rows + [total]]
    return "\n".join(lines) + "\n"


def summary(args):
    doc = read(PARITY)
    table = summary_table(doc)
    if args.get("write"):
        with open(PARITY, "w", encoding="utf-8") as f:
            f.write(SUMMARY.sub(lambda m: m.group(1) + table + m.group(3), doc))
    else:
        print(table, end="")
    return 0


def check(args):
    doc = read(PARITY)
    have = named(doc)
    problems = []
    m = SUMMARY.search(doc)
    if not m:
        problems.append("PARITY.md has no <!-- summary --> markers")
    elif m.group(2) != summary_table(doc):
        problems.append("the summary counts are out of date: run Windows/scripts/parity.py summary --write")
    for f in mac_files():
        if f not in have:
            problems.append(f"Mac file `{f}` has no row in Windows/PARITY.md")
    for n in core_names():
        if n not in have:
            problems.append(f"CraCore `{n}` isn't named in Windows/PARITY.md (say which feature it serves)")
    acts, missing_panes = missing_on_windows()
    for a in acts:
        if a not in have:
            problems.append(f"Mac command `{a}` isn't on Windows and isn't named in Windows/PARITY.md")
    for p in missing_panes:
        if p not in have:
            problems.append(f"Settings pane `{p}` isn't on Windows and isn't named in Windows/PARITY.md")
    if args.get("upstream"):
        commits, err = unreviewed(doc, args["upstream"], merged_only=True)
        if err:
            problems.append(err)
        elif commits:
            problems.append(f"main has merged {len(commits)} upstream commit(s) newer than PARITY.md's "
                            "upstream-reviewed marker; triage them and move the marker:")
            problems += ["    " + c for c in commits]
    if args.get("base"):
        diff = git("diff", "--name-only", f"{args['base']}...HEAD").stdout.split()
        if any(p.startswith("Windows/Sources/") for p in diff) and "Windows/PARITY.md" not in diff:
            print("::warning file=Windows/PARITY.md::Windows/Sources changed but PARITY.md didn't; "
                  "update the feature's row if this PR changes what Windows has")
    for p in problems:
        print(p if p.startswith("    ") else "parity: " + p)
    if problems:
        print("parity: see Windows/PARITY.md, 'Keeping this current'")
        return 1
    print("parity: Windows/PARITY.md covers every Mac file, command and pane")
    return 0


def report(args):
    doc = read(PARITY)
    print("## Feature parity\n")
    if args.get("upstream"):
        commits, err = unreviewed(doc, args["upstream"], merged_only=False)
        if err:
            print(f"Upstream: {err}\n")
        elif commits:
            print(f"**{len(commits)}** upstream commit(s) since `{marker(doc)}`, not yet triaged in "
                  "Windows/PARITY.md:\n")
            print("\n".join(f"- {c}" for c in commits) + "\n")
        else:
            print(f"Every upstream commit through `{marker(doc)}` is triaged.\n")
    acts, missing_panes = missing_on_windows()
    print(f"Mac commands Windows doesn't perform yet ({len(acts)}): " + ", ".join(f"`{a}`" for a in acts) + "\n")
    print("Settings panes not on Windows yet: " + ", ".join(f"`{p}`" for p in missing_panes) + "\n")
    win_text = "\n".join(read(p) for p in files_under(WIN_SOURCES, SOURCE_EXT))
    unused = []
    for path in files_under(CORE, (".swift",)):
        types = re.findall(r"^public (?:final class|class|struct|enum|actor|protocol) (\w+)", read(path), re.M)
        if types and not any(re.search(rf"\b{t}\b", win_text) for t in types):
            unused.append(os.path.splitext(os.path.basename(path))[0])
    print(f"CraCore files whose types the Windows app doesn't use directly ({len(unused)}): "
          + ", ".join(f"`{u}`" for u in unused))
    return 0


def main(argv):
    if not argv or argv[0] not in ("check", "report", "summary"):
        print(__doc__)
        return 2
    args, rest = {}, argv[1:]
    while rest:
        flag = rest.pop(0)
        if flag == "--write":
            args["write"] = True
            continue
        if flag not in ("--upstream", "--base") or not rest:
            print(f"parity: unknown or incomplete option {flag}")
            return 2
        args[flag[2:]] = rest.pop(0)
    return {"check": check, "report": report, "summary": summary}[argv[0]](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
