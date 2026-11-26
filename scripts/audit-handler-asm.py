#!/usr/bin/env python3
"""Audit native dispatch handlers in a disassembled x86_64 binary.

`preserve_none` has no callee-saved registers, so a non-tail call inside a
handler makes LLVM spill the live handler arguments (frame, cursor, sp, gas)
around it. This script counts, per handler, the `call` instructions and the
stack-frame instructions (`push`, `pop`, `sub $N,%rsp`).

Usage:
    objdump -d --no-show-raw-insn zig-out/bin/guillotine-compare > /tmp/d.txt
    scripts/audit-handler-asm.py /tmp/d.txt [--all] [--tsv]

Without --all only handlers that have a call or a frame are listed.
"""
import re
import sys

MODULES = (
    "handlers_arithmetic_synthetic",
    "handlers_arithmetic",
    "handlers_bitwise_synthetic",
    "handlers_bitwise",
    "handlers_comparison",
    "handlers_jump_synthetic",
    "handlers_jump",
    "handlers_memory_synthetic",
    "handlers_memory",
    "handlers_stack",
)

HEADER = re.compile(r"^[0-9a-f]+ <(.+)>:$")
CALL = re.compile(r"\bcall[ql]?\b\s+(.*)$")
SUB_RSP = re.compile(r"\bsubq?\s+\$0x[0-9a-f]+,\s*%rsp")
TARGET = re.compile(r"<(.+)>")


def module_of(symbol):
    for module in MODULES:
        if "instructions." + module + ".Handlers(" in symbol:
            return module
    return None


def short(symbol):
    """`a.b.Handlers(Frame(...)).name` -> `name`, keeping a trailing hash suffix."""
    tail = symbol.rsplit(").", 1)[-1]
    return tail


def frame_kind(symbol):
    """Tell the fusion-on and fusion-off instantiations apart when both exist."""
    match = re.search(r"Frame\(([^)]*)", symbol)
    return match.group(1)[:24] if match else ""


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    show_all = "--all" in sys.argv
    tsv = "--tsv" in sys.argv
    if len(args) != 1:
        sys.stderr.write(__doc__)
        return 2

    rows = []
    current = None
    with open(args[0], errors="replace") as handle:
        for line in handle:
            line = line.rstrip("\n")
            header = HEADER.match(line)
            if header:
                symbol = header.group(1)
                module = module_of(symbol)
                current = None
                if module:
                    current = {
                        "module": module,
                        "name": short(symbol),
                        "symbol": symbol,
                        "calls": 0,
                        "push": 0,
                        "pop": 0,
                        "sub": 0,
                        "insns": 0,
                        "targets": [],
                    }
                    rows.append(current)
                continue
            if current is None or "\t" not in line:
                continue
            text = line.split("\t", 1)[1].strip()
            current["insns"] += 1
            call = CALL.search(text)
            if call:
                current["calls"] += 1
                target = TARGET.search(call.group(1))
                current["targets"].append(target.group(1) if target else call.group(1))
            elif re.match(r"push[ql]?\b", text):
                current["push"] += 1
            elif re.match(r"pop[ql]?\b", text):
                current["pop"] += 1
            elif SUB_RSP.search(text):
                current["sub"] += 1

    rows.sort(key=lambda r: (r["module"], r["name"], r["symbol"]))
    total = {"handlers": 0, "calls": 0, "push": 0, "pop": 0, "sub": 0, "dirty": 0}
    for row in rows:
        total["handlers"] += 1
        for key in ("calls", "push", "pop", "sub"):
            total[key] += row[key]
        dirty = row["calls"] or row["push"] or row["pop"] or row["sub"]
        if dirty:
            total["dirty"] += 1
        if not (dirty or show_all):
            continue
        targets = sorted(set(t.rsplit(".", 1)[-1][:40] for t in row["targets"]))
        if tsv:
            print("\t".join([row["module"], row["name"], str(row["calls"]), str(row["push"]), str(row["pop"]), str(row["sub"]), str(row["insns"]), ",".join(targets)]))
        else:
            print("%-30s %-34s call=%-2d push=%-2d pop=%-2d subrsp=%-2d insns=%-4d %s" % (
                row["module"], row["name"][:34], row["calls"], row["push"], row["pop"], row["sub"], row["insns"], ",".join(targets)))
    print("TOTAL handlers=%(handlers)d with_call_or_frame=%(dirty)d call=%(calls)d push=%(push)d pop=%(pop)d subrsp=%(sub)d" % total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
