#!/usr/bin/env python3
"""Checks that an AOT snapshot was built with renamed symbols.

usage: aot_names.py <binary> <source dir> [<source dir> ...]

Collects the class names declared in the given source dirs (14 characters or more), then
counts how many of them stand as whole strings in the binary. A normal release build keeps
most of them; a renamed one keeps almost none. Prints only the two counts. Fails when more
than a tenth of the names are readable, or when too few names were found to judge.
"""
import os
import re
import sys

DECL = re.compile(
    rb"^\s*(?:(?:abstract|final|base|sealed|interface|mixin)\s+)*(?:class|mixin|enum|extension type)\s+"
    rb"([A-Z][A-Za-z0-9_]{13,})\b",
    re.M,
)
RUN = re.compile(rb"[\x20-\x7e]{8,}")


def names(dirs):
    found = set()
    for top in dirs:
        for root, subdirs, files in os.walk(top):
            subdirs[:] = [d for d in subdirs if d not in ("build", ".dart_tool", "test")]
            for f in files:
                if f.endswith(".dart") and not f.endswith((".g.dart", ".freezed.dart")):
                    with open(os.path.join(root, f), "rb") as fh:
                        found.update(DECL.findall(fh.read()))
    return found


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    with open(sys.argv[1], "rb") as fh:
        strings = set(RUN.findall(fh.read()))
    wanted = names(sys.argv[2:])
    readable = sum(1 for n in wanted if n in strings)
    print("class names checked: %d, readable in the binary: %d" % (len(wanted), readable))
    if len(wanted) < 20:
        sys.exit("too few class names to judge")
    if readable * 10 > len(wanted):
        sys.exit("the binary keeps its class names: it was not built with renamed symbols")


if __name__ == "__main__":
    main()
