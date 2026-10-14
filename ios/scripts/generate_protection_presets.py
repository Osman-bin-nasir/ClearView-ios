#!/usr/bin/env python3
"""Generate `ProtectionPresets.swift` from Android's `BlockRepository.kt`.

The Block tab's built-in rule sets — the always-block adult keywords, the adult
domain preset, the Strict Mode discovery terms and the two context-combination
halves — are the product's actual protection. They live in one place on Android
(`app/src/main/java/com/muddassir/clearview/repository/BlockRepository.kt`) and
the iOS app has to enforce exactly the same lists: a keyword that blocks on
Android and not on iOS (or the reverse) is a bug nobody would notice until it
mattered.

Retyping ~700 terms by hand is how the two sets drift, so they are generated
instead. Run from the repository root:

    python3 ios/scripts/generate_protection_presets.py

and commit the regenerated `ProtectionPresets.swift` together with the Android
change that prompted it. The file is checked in (the app must build without
Python), and `ProtectionPresetTests` pins the counts so a regeneration that
silently drops a list fails the build rather than weakening protection.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "app/src/main/java/com/muddassir/clearview/repository/BlockRepository.kt"
TARGET = ROOT / "ios/ClearViewApp/Features/Protection/ProtectionPresets.swift"

# Kotlin set name -> (Swift property name, comment)
SETS = [
    (
        "ALWAYS_BLOCK_KEYWORDS",
        "alwaysBlockKeywords",
        "Tier 1 — always blocked: clear adult terms, blocked in every mode.",
    ),
    (
        "ADULT_DOMAINS",
        "adultDomains",
        "The adult website preset — hosts blocked on sight, in every mode.",
    ),
    (
        "STRICT_MODE_KEYWORDS",
        "strictModeKeywords",
        "Tier 2 — Strict Mode only: risky-but-innocent discovery terms.",
    ),
    (
        "COMBINATION_GENERIC_TERMS",
        "combinationGenericTerms",
        "Tier 3, generic half — innocent alone (woman, girl, beach, pool).",
    ),
    (
        "COMBINATION_RISKY_TERMS",
        "combinationRiskyTerms",
        "Tier 3, risky half — what sexualizes a generic half (bikini, pics).",
    ),
]


def read_source() -> str:
    if not SOURCE.exists():
        sys.exit(f"Android source not found: {SOURCE}")
    return SOURCE.read_text(encoding="utf-8")


def block_for(text: str, name: str) -> str:
    """The text of `linkedSetOf( ... )` assigned to `name`."""
    marker = re.compile(rf"\b{name}\s*:\s*Set<String>\s*=\s*linkedSetOf\(", re.MULTILINE)
    match = marker.search(text)
    if not match:
        sys.exit(f"{name} not found in {SOURCE.name} — did the Android field change?")
    depth = 1
    index = match.end()
    while index < len(text) and depth:
        char = text[index]
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        index += 1
    if depth:
        sys.exit(f"{name}: unbalanced parentheses in {SOURCE.name}")
    return text[match.end() : index - 1]


STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')
ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "$": "$"}


def unescape(raw: str) -> str:
    out = []
    index = 0
    while index < len(raw):
        char = raw[index]
        if char == "\\" and index + 1 < len(raw):
            following = raw[index + 1]
            if following == "u" and index + 5 < len(raw) + 1:
                try:
                    out.append(chr(int(raw[index + 2 : index + 6], 16)))
                    index += 6
                    continue
                except ValueError:
                    pass
            out.append(ESCAPES.get(following, following))
            index += 2
            continue
        out.append(char)
        index += 1
    return "".join(out)


def entries(block: str) -> list[str]:
    """The list's strings, in source order, de-duplicated.

    Android's literal carries a few intentional repeats (the same term listed
    under two headings); a `Set` collapses them, and so does this, but the
    FIRST occurrence keeps its position so the generated order still reads like
    the source.
    """
    seen: set[str] = set()
    ordered: list[str] = []
    for raw in STRING.findall(block):
        value = unescape(raw)
        if value in seen:
            continue
        seen.add(value)
        ordered.append(value)
    return ordered


def swift_literal(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def main() -> None:
    text = read_source()
    sections: list[str] = []
    counts: list[tuple[str, int]] = []

    for kotlin_name, swift_name, comment in SETS:
        values = entries(block_for(text, kotlin_name))
        counts.append((swift_name, len(values)))
        body = "\n".join(f"        {swift_literal(value)}," for value in values)
        sections.append(
            f"    /// {comment}\n"
            f"    ///\n"
            f"    /// Generated from Android's `BlockRepository.{kotlin_name}` — "
            f"{len(values)} entries.\n"
            f"    static let {swift_name}: [String] = [\n{body}\n    ]\n"
        )

    header_counts = "\n".join(f"///   - `{name}`: {count} entries" for name, count in counts)
    document = f'''import Foundation

/// The built-in rule sets, **generated** from the Android app's `BlockRepository.kt`.
///
/// Do not edit by hand: run `python3 ios/scripts/generate_protection_presets.py`
/// from the repository root after changing the Android lists, and commit the
/// result. `ProtectionPresetTests` pins the counts below, so a regeneration that
/// loses a list fails a test instead of silently blocking less.
///
/// A generated file rather than a hand-typed one because the value of these lists
/// is that both platforms enforce the *same* 700-odd terms: a keyword that blocks
/// on Android and not on iOS is invisible until it is the one that mattered.
///
{header_counts}
///
/// Order is Android's own (longest-first scanning is a matcher detail, not a
/// property of the list), and duplicates — the Android literal repeats a few
/// terms under two headings — are collapsed to their first occurrence, exactly as
/// a `Set` does on the Android side.
internal enum ProtectionPresets {{

{chr(10).join(sections)}}}
'''

    TARGET.parent.mkdir(parents=True, exist_ok=True)
    TARGET.write_text(document, encoding="utf-8")
    print(f"wrote {TARGET.relative_to(ROOT)}")
    for name, count in counts:
        print(f"  {name}: {count}")


if __name__ == "__main__":
    main()
