#!/usr/bin/env python3
"""
Direct LLVM 20 SSA IR -> SMT-LIB2 Equivalence & Poison/UB Verifier for Zig.

Compares pairs of exported functions (`<name>_ref` vs `<name>_fast`) directly in
the LLVM 20 IR (.ll) emitted by `zig build-obj -fllvm -OReleaseFast -femit-llvm-ir=...`
and discharges proof obligations using Bitwuzla (primary) and/or Z3.

Implements LLVM 20 LangRef value-level poison semantics (like Alive2):
  - Every SSA value carries `(bv_expr, poison_bool)`.
  - `nuw`, `nsw`, `exact`, `disjoint`, `nneg`, and out-of-range shifts set the
    result's `poison_bool` rather than triggering immediate UB.
  - `select i1 %c, %t, %f` masks deferred poison on the unselected arm:
    `poison(select) = poison(c) || (c ? poison(t) : poison(f))`.
  - `br i1 %c` on poison, `unreachable`, and div/rem by zero are immediate UB.
  - Returning a poisoned value from `fast` fails verification (`ret_poison`).
  - Functional equivalence verifies `ref_ret == fast_ret` for ALL inputs.
"""

from __future__ import annotations

import argparse
import dataclasses
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple


@dataclasses.dataclass
class IRFunction:
    name: str
    ret_ty: str
    params: List[Tuple[str, str]]  # (ty, name)
    blocks: List[Tuple[str, List[str]]]  # (label, instructions)


def strip_dbg_and_metadata(line: str) -> str:
    line = re.sub(r";.*$", "", line).strip()
    if not line or line.startswith("#dbg_"):
        return ""
    line = re.sub(r",\s*![A-Za-z0-9_.]+\s+![0-9]+", "", line)
    line = re.sub(r"\s+![A-Za-z0-9_.]+\s+![0-9]+", "", line)
    return line.strip()


def parse_llvm_ir(ll_text: str) -> Dict[str, IRFunction]:
    funcs: Dict[str, IRFunction] = {}
    lines = ll_text.splitlines()
    i = 0
    n = len(lines)
    define_re = re.compile(
        r"^define\b.*?\s+(i\d+|void|ptr)\s+@([A-Za-z0-9_$.]+)\(((?:[^()]|\([^)]*\))*)\)"
    )

    while i < n:
        line = lines[i].strip()
        m = define_re.match(line)
        if not m:
            i += 1
            continue

        ret_ty, name, params_str = m.group(1), m.group(2), m.group(3).strip()
        params: List[Tuple[str, str]] = []
        if params_str:
            param_idx = 0
            # Split parameters on top-level commas (ignore commas inside attributes like captures(address, provenance))
            raw_params: List[str] = []
            depth = 0
            cur: List[str] = []
            for ch in params_str:
                if ch == "(":
                    depth += 1
                    cur.append(ch)
                elif ch == ")":
                    depth -= 1
                    cur.append(ch)
                elif ch == "," and depth == 0:
                    raw_params.append("".join(cur))
                    cur = []
                else:
                    cur.append(ch)
            if cur:
                raw_params.append("".join(cur))
            for raw_p in raw_params:
                raw_p = raw_p.strip()
                if not raw_p:
                    continue
                toks = raw_p.split()
                ty = toks[0]
                pname = None
                for t in reversed(toks):
                    if t.startswith("%"):
                        pname = t
                        break
                if pname is None:
                    pname = f"%{param_idx}"
                    param_idx += 1
                params.append((ty, pname))

        i += 1
        blocks: List[Tuple[str, List[str]]] = []
        cur_label = "entry"
        cur_insts: List[str] = []
        while i < n:
            raw = lines[i]
            if raw.strip() == "}":
                break
            cleaned = strip_dbg_and_metadata(raw)
            if not cleaned:
                i += 1
                continue
            label_m = re.match(r'^"?([A-Za-z0-9_.$%-]+)"?:$', cleaned)
            if label_m:
                if cur_insts or blocks:
                    blocks.append((cur_label, cur_insts))
                cur_label = label_m.group(1)
                cur_insts = []
            else:
                cur_insts.append(cleaned)
            i += 1
        if cur_insts or not blocks:
            blocks.append((cur_label, cur_insts))

        funcs[name] = IRFunction(name=name, ret_ty=ret_ty, params=params, blocks=blocks)
        i += 1

    return funcs


def parse_int_width(ty: str) -> int:
    m = re.fullmatch(r"i(\d+)", ty)
    if not m:
        raise ValueError(f"Unsupported integer type: {ty}")
    return int(m.group(1))


def bv_const(val: int, width: int) -> str:
    mask = (1 << width) - 1
    return f"(_ bv{val & mask} {width})"


def smt_or(*conds: str) -> str:
    filtered = [c for c in conds if c != "false"]
    if not filtered:
        return "false"
    if "true" in filtered:
        return "true"
    if len(filtered) == 1:
        return filtered[0]
    return f"(or {' '.join(filtered)})"


def smt_and(*conds: str) -> str:
    filtered = [c for c in conds if c != "true"]
    if not filtered:
        return "true"
    if "false" in filtered:
        return "false"
    if len(filtered) == 1:
        return filtered[0]
    return f"(and {' '.join(filtered)})"


def split_top_level_commas(s: str) -> List[str]:
    parts: List[str] = []
    depth = 0
    start = 0
    for idx, ch in enumerate(s):
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            parts.append(s[start:idx].strip())
            start = idx + 1
    tail = s[start:].strip()
    if tail:
        parts.append(tail)
    return parts


class SMTBuilder:
    """Translates an acyclic LLVM 20 SSA function to SMT-LIB2 with Alive2-style poison tracking."""

    def __init__(self, prefix: str):
        self.prefix = prefix
        self.defs: List[str] = []
        self.ub_conds: List[Tuple[str, str]] = []  # (desc, smt_bool_expr)
        self._tmp = 0
        self.uf_decls: Dict[str, str] = {}

    def fresh(self, hint: str = "v") -> str:
        self._tmp += 1
        safe = re.sub(r"[^A-Za-z0-9_]", "_", hint)
        return f"{self.prefix}_{safe}_{self._tmp}"

    def define(self, name: str, sort: str, expr: str) -> str:
        self.defs.append(f"(define-fun {name} () {sort} {expr})")
        return name

    def def_bool(self, hint: str, expr: str) -> str:
        if expr in ("true", "false"):
            return expr
        return self.define(self.fresh(hint), "Bool", expr)

    def translate_function(
        self,
        fn: IRFunction,
        arg_exprs: List[Tuple[str, str]],  # (kind: 'bv'|'ptr_u256', smt_name)
        track_ub: bool = False,
        all_funcs: Optional[Dict[str, IRFunction]] = None,
    ) -> Tuple[str, str, int]:
        """Returns (ret_bv_smt_expr, ret_poison_bool, ret_width)."""
        # env[ssa] =
        #   ('bv', width, bv_expr, poison_bool)
        #   ('ptr_u256', byte_offset, bv256_expr, 'false')
        #   ('alloca', slot_name, None, 'false')
        #   ('struct2', (w0, e0, p0, w1, e1, p1), None, 'false')
        env: Dict[str, Tuple] = {}
        alloca_mem: Dict[str, Tuple[int, str, str]] = {}  # slot -> (width, bv_expr, poison_bool)

        for (pty, pname), (akind, aexpr) in zip(fn.params, arg_exprs):
            if pty == "ptr":
                env[pname] = (akind, 0, aexpr, "false")
            else:
                w = parse_int_width(pty)
                env[pname] = ("bv", w, aexpr, "false")

        label_to_block = {lbl: insts for lbl, insts in fn.blocks}
        succs: Dict[str, List[str]] = {lbl: [] for lbl, _ in fn.blocks}
        preds: Dict[str, List[str]] = {lbl: [] for lbl, _ in fn.blocks}

        for lbl, insts in fn.blocks:
            if not insts:
                continue
            term = insts[-1]
            targets = re.findall(r'label\s+%"?([A-Za-z0-9_.$%-]+)"?', term)
            for t in targets:
                if t in label_to_block:
                    succs[lbl].append(t)
                    preds[t].append(lbl)

        in_deg = {lbl: len(preds[lbl]) for lbl, _ in fn.blocks}
        entry_lbl = fn.blocks[0][0]
        order: List[str] = []
        queue = [lbl for lbl, _ in fn.blocks if in_deg[lbl] == 0]
        if entry_lbl in queue:
            queue.remove(entry_lbl)
            queue.insert(0, entry_lbl)
        while queue:
            u = queue.pop(0)
            order.append(u)
            for v in succs[u]:
                in_deg[v] -= 1
                if in_deg[v] == 0:
                    queue.append(v)
        if len(order) != len(fn.blocks):
            raise ValueError(f"Function @{fn.name} contains a loop (cyclic CFG)")

        edge_cond: Dict[Tuple[str, str], str] = {}
        block_alloca_out: Dict[str, Dict[str, Tuple[int, str, str]]] = {}
        ret_branches: List[Tuple[str, str, str, int]] = []  # (reach, ret_bv, ret_poison, width)

        def eval_val(tok: str, width: int) -> Tuple[str, str]:
            tok = tok.strip()
            if tok == "true":
                return "(_ bv1 1)", "false"
            if tok == "false":
                return "(_ bv0 1)", "false"
            if tok == "null":
                return bv_const(0, width), "false"
            if tok in ("undef", "poison"):
                return bv_const(0, width), "true"
            if re.fullmatch(r"-?\d+", tok):
                return bv_const(int(tok), width), "false"
            if tok in env:
                entry = env[tok]
                if entry[0] == "bv":
                    return entry[2], entry[3]
                raise ValueError(f"Expected bv for {tok}, got {entry[0]}")
            raise ValueError(f"Unknown operand {tok!r} (width {width}) in @{fn.name}")

        def add_ub(reach: str, desc: str, cond_bool: str) -> None:
            if track_ub and cond_bool != "false":
                self.ub_conds.append((desc, self.def_bool("ub", smt_and(reach, cond_bool))))

        for lbl in order:
            if lbl == entry_lbl:
                reach = "true"
            else:
                incoming = [edge_cond[(p, lbl)] for p in preds[lbl] if (p, lbl) in edge_cond]
                reach = self.def_bool(f"reach_{lbl}", smt_or(*incoming))

            alloca_mem = {}
            all_allocas = set()
            for p in preds[lbl]:
                all_allocas.update(block_alloca_out.get(p, {}).keys())
            for aname in sorted(all_allocas):
                merged_expr: Optional[str] = None
                merged_p = "false"
                merged_w = 0
                for p in preds[lbl]:
                    pmap = block_alloca_out.get(p, {})
                    if aname in pmap:
                        w, ex, ep = pmap[aname]
                        merged_w = w
                        if merged_expr is None:
                            merged_expr, merged_p = ex, ep
                        else:
                            ec = edge_cond[(p, lbl)]
                            merged_expr = f"(ite {ec} {ex} {merged_expr})"
                            merged_p = self.def_bool("ap", f"(ite {ec} {ep} {merged_p})")
                if merged_expr is not None:
                    alloca_mem[aname] = (merged_w, merged_expr, merged_p)

            for inst in label_to_block[lbl]:
                # 1. ret
                m = re.match(r"^ret\s+(i\d+)\s+(.+)$", inst)
                if m:
                    rw = parse_int_width(m.group(1))
                    rval, rp = eval_val(m.group(2), rw)
                    add_ub(reach, f"{fn.name}:{lbl}: returns poison", rp)
                    ret_branches.append((reach, rval, rp, rw))
                    continue

                # 2. unconditional br
                m = re.match(r'^br\s+label\s+%"?([A-Za-z0-9_.$%-]+)"?$', inst)
                if m:
                    edge_cond[(lbl, m.group(1))] = reach
                    continue

                # 3. conditional br
                m = re.match(
                    r'^br\s+i1\s+([^,]+),\s*label\s+%"?([A-Za-z0-9_.$%-]+)"?,\s*label\s+%"?([A-Za-z0-9_.$%-]+)"?$',
                    inst,
                )
                if m:
                    cond_bv, cond_p = eval_val(m.group(1), 1)
                    add_ub(reach, f"{fn.name}:{lbl}: branch on poison", cond_p)
                    t_dst, f_dst = m.group(2), m.group(3)
                    cond_b = self.def_bool("br", f"(= {cond_bv} (_ bv1 1))")
                    edge_cond[(lbl, t_dst)] = self.def_bool(f"e_{lbl}_{t_dst}", smt_and(reach, cond_b))
                    edge_cond[(lbl, f_dst)] = self.def_bool(f"e_{lbl}_{f_dst}", smt_and(reach, f"(not {cond_b})"))
                    continue

                # 4. switch
                m = re.match(r'^switch\s+(i\d+)\s+([^,]+),\s*label\s+%"?([A-Za-z0-9_.$%-]+)"?\s*\[(.*)\]$', inst)
                if m:
                    sw = parse_int_width(m.group(1))
                    sval, sp = eval_val(m.group(2), sw)
                    add_ub(reach, f"{fn.name}:{lbl}: switch on poison", sp)
                    def_dst = m.group(3)
                    cases = re.findall(r'i\d+\s+(-?\d+),\s*label\s+%"?([A-Za-z0-9_.$%-]+)"?', m.group(4))
                    any_case = []
                    for cval_s, cdst in cases:
                        eq = f"(= {sval} {bv_const(int(cval_s), sw)})"
                        any_case.append(eq)
                        prev = edge_cond.get((lbl, cdst), "false")
                        edge_cond[(lbl, cdst)] = self.def_bool(f"sw_{cdst}", smt_or(prev, smt_and(reach, eq)))
                    not_any = f"(not {smt_or(*any_case)})" if any_case else "true"
                    prev = edge_cond.get((lbl, def_dst), "false")
                    edge_cond[(lbl, def_dst)] = self.def_bool(f"sw_{def_dst}", smt_or(prev, smt_and(reach, not_any)))
                    continue

                # 5. unreachable
                if inst == "unreachable":
                    add_ub(reach, f"{fn.name}:{lbl}: unreachable executed", "true")
                    continue

                # 6. store into alloca
                m = re.match(r"^store\s+(i\d+)\s+([^,]+),\s*ptr\s+(%[^,\s]+)", inst)
                if m:
                    sw = parse_int_width(m.group(1))
                    sval, sp = eval_val(m.group(2), sw)
                    ptr_name = m.group(3)
                    if ptr_name not in env or env[ptr_name][0] != "alloca":
                        raise ValueError(f"Unsupported store target {ptr_name} in @{fn.name}")
                    alloca_mem[env[ptr_name][1]] = (sw, sval, sp)
                    continue

                am = re.match(r"^(%[^\s=]+)\s*=\s*(.+)$", inst)
                if not am:
                    raise ValueError(f"Unrecognized instruction in @{fn.name}: {inst}")
                dst, rhs = am.group(1), am.group(2).strip()

                # 7. alloca
                if rhs.startswith("alloca "):
                    env[dst] = ("alloca", dst, None, "false")
                    continue

                # 8. phi
                if rhs.startswith("phi "):
                    pm = re.match(r"^phi\s+(i\d+)\s+(.+)$", rhs)
                    if not pm:
                        raise ValueError(f"Unsupported phi in @{fn.name}: {inst}")
                    pw = parse_int_width(pm.group(1))
                    pairs = re.findall(r'\[\s*([^,\]]+),\s*%"?([A-Za-z0-9_.$%-]+)"?\s*\]', pm.group(2))
                    expr: Optional[str] = None
                    pexpr = "false"
                    for val_s, pred_lbl in reversed(pairs):
                        v_smt, v_p = eval_val(val_s, pw)
                        if expr is None:
                            expr, pexpr = v_smt, v_p
                        else:
                            ec = edge_cond.get((pred_lbl, lbl), "false")
                            expr = f"(ite {ec} {v_smt} {expr})"
                            pexpr = self.def_bool("phip", f"(ite {ec} {v_p} {pexpr})")
                    assert expr is not None
                    sym = self.define(self.fresh("phi"), f"(_ BitVec {pw})", expr)
                    env[dst] = ("bv", pw, sym, pexpr)
                    continue

                # 9. getelementptr
                if rhs.startswith("getelementptr "):
                    gm = re.search(r",\s*ptr\s+(%[^,\s]+),\s*i\d+\s+(-?\d+)$", rhs)
                    if not gm:
                        raise ValueError(f"Unsupported GEP in @{fn.name}: {inst}")
                    base_p, byte_off = gm.group(1), int(gm.group(2))
                    bkind, boff, bexpr, bp = env[base_p]
                    env[dst] = (bkind, boff + byte_off, bexpr, bp)
                    continue

                # 10. load
                if rhs.startswith("load "):
                    lm = re.match(r"^load\s+(i\d+),\s*ptr\s+(%[^,\s]+)", rhs)
                    if not lm:
                        raise ValueError(f"Unsupported load in @{fn.name}: {inst}")
                    lw = parse_int_width(lm.group(1))
                    pinfo = env[lm.group(2)]
                    if pinfo[0] == "alloca":
                        sw, sval, sp = alloca_mem[pinfo[1]]
                        if sw == lw:
                            ex = sval
                        elif sw < lw:
                            ex = f"((_ zero_extend {lw - sw}) {sval})"
                        else:
                            ex = f"((_ extract {lw - 1} 0) {sval})"
                        sym = self.define(self.fresh("ld"), f"(_ BitVec {lw})", ex)
                        env[dst] = ("bv", lw, sym, sp)
                    elif pinfo[0] == "ptr_u256":
                        boff, bexpr = pinfo[1], pinfo[2]
                        lo_bit = boff * 8
                        hi_bit = lo_bit + lw - 1
                        ex = f"((_ extract {hi_bit} {lo_bit}) {bexpr})"
                        sym = self.define(self.fresh("ld256"), f"(_ BitVec {lw})", ex)
                        env[dst] = ("bv", lw, sym, "false")
                    else:
                        raise ValueError(f"Unsupported load pointer kind {pinfo[0]} in @{fn.name}")
                    continue

                # 11. Casts
                cm = re.match(r"^(zext|sext|trunc)\s+(?:nneg\s+|nuw\s+|nsw\s+)*?(i\d+)\s+(\S+)\s+to\s+(i\d+)$", rhs)
                if cm:
                    op, src_ty, src_v, dst_ty = cm.group(1), cm.group(2), cm.group(3), cm.group(4)
                    sw = parse_int_width(src_ty)
                    dw = parse_int_width(dst_ty)
                    sv, sp = eval_val(src_v, sw)
                    op_p = "false"
                    if op == "zext":
                        if " nneg " in f" {rhs} ":
                            op_p = f"(bvslt {sv} {bv_const(0, sw)})"
                        ex = f"((_ zero_extend {dw - sw}) {sv})"
                    elif op == "sext":
                        ex = f"((_ sign_extend {dw - sw}) {sv})"
                    else:
                        ex = f"((_ extract {dw - 1} 0) {sv})"
                    sym = self.define(self.fresh(op), f"(_ BitVec {dw})", ex)
                    env[dst] = ("bv", dw, sym, self.def_bool("cp", smt_or(sp, op_p)))
                    continue

                # 12. select (Alive2 exact poison masking!)
                sm = re.match(r"^select\s+i1\s+([^,]+),\s*(i\d+)\s+([^,]+),\s*i\d+\s+(.+)$", rhs)
                if sm:
                    c_bv, c_p = eval_val(sm.group(1), 1)
                    w = parse_int_width(sm.group(2))
                    tv, tp = eval_val(sm.group(3), w)
                    fv, fp = eval_val(sm.group(4), w)
                    cond_b = f"(= {c_bv} (_ bv1 1))"
                    ex = f"(ite {cond_b} {tv} {fv})"
                    sel_p = self.def_bool("selp", smt_or(c_p, f"(ite {cond_b} {tp} {fp})"))
                    sym = self.define(self.fresh("sel"), f"(_ BitVec {w})", ex)
                    env[dst] = ("bv", w, sym, sel_p)
                    continue

                # 13. icmp (supports LLVM 20 `samesign` flag + poison check)
                im = re.match(r"^icmp\s+(samesign\s+)?(eq|ne|ugt|uge|ult|ule|sgt|sge|slt|sle)\s+(i\d+)\s+([^,]+),\s*(.+)$", rhs)
                if im:
                    has_samesign = im.group(1) is not None
                    pred, w = im.group(2), parse_int_width(im.group(3))
                    lhs, lp = eval_val(im.group(4), w)
                    rhs_v, rp = eval_val(im.group(5), w)
                    pred_map = {
                        "eq": f"(= {lhs} {rhs_v})",
                        "ne": f"(not (= {lhs} {rhs_v}))",
                        "ugt": f"(bvugt {lhs} {rhs_v})",
                        "uge": f"(bvuge {lhs} {rhs_v})",
                        "ult": f"(bvult {lhs} {rhs_v})",
                        "ule": f"(bvule {lhs} {rhs_v})",
                        "sgt": f"(bvsgt {lhs} {rhs_v})",
                        "sge": f"(bvsge {lhs} {rhs_v})",
                        "slt": f"(bvslt {lhs} {rhs_v})",
                        "sle": f"(bvsle {lhs} {rhs_v})",
                    }
                    ex = f"(ite {pred_map[pred]} (_ bv1 1) (_ bv0 1))"
                    sym = self.define(self.fresh("cmp"), "(_ BitVec 1)", ex)
                    ss_p = (
                        f"(not (= ((_ extract {w - 1} {w - 1}) {lhs}) ((_ extract {w - 1} {w - 1}) {rhs_v})))"
                        if has_samesign
                        else "false"
                    )
                    env[dst] = ("bv", 1, sym, self.def_bool("cmpp", smt_or(lp, rp, ss_p)))
                    continue

                # 14. Binary ops
                bm = re.match(
                    r"^(add|sub|mul|udiv|sdiv|urem|srem|shl|lshr|ashr|and|or|xor)\s+((?:nuw\s+|nsw\s+|exact\s+|disjoint\s+)*)(i\d+)\s+([^,]+),\s*(.+)$",
                    rhs,
                )
                if bm:
                    op, flags_s, w = bm.group(1), bm.group(2), parse_int_width(bm.group(3))
                    flags = set(flags_s.split())
                    lhs, lp = eval_val(bm.group(4), w)
                    rhs_v, rp = eval_val(bm.group(5), w)
                    op_ps: List[str] = [lp, rp]

                    if op == "add":
                        if "nuw" in flags:
                            op_ps.append(f"(bvugt (bvadd ((_ zero_extend 1) {lhs}) ((_ zero_extend 1) {rhs_v})) {bv_const((1 << w) - 1, w + 1)})")
                        if "nsw" in flags:
                            s = f"(bvadd ((_ sign_extend 1) {lhs}) ((_ sign_extend 1) {rhs_v}))"
                            op_ps.append(f"(not (= ((_ extract {w} {w}) {s}) ((_ extract {w - 1} {w - 1}) {s})))")
                        ex = f"(bvadd {lhs} {rhs_v})"
                    elif op == "sub":
                        if "nuw" in flags:
                            op_ps.append(f"(bvult {lhs} {rhs_v})")
                        if "nsw" in flags:
                            s = f"(bvsub ((_ sign_extend 1) {lhs}) ((_ sign_extend 1) {rhs_v}))"
                            op_ps.append(f"(not (= ((_ extract {w} {w}) {s}) ((_ extract {w - 1} {w - 1}) {s})))")
                        ex = f"(bvsub {lhs} {rhs_v})"
                    elif op == "mul":
                        if "nuw" in flags:
                            p = f"(bvmul ((_ zero_extend {w}) {lhs}) ((_ zero_extend {w}) {rhs_v}))"
                            op_ps.append(f"(not (= ((_ extract {2*w - 1} {w}) {p}) {bv_const(0, w)}))")
                        ex = f"(bvmul {lhs} {rhs_v})"
                    elif op == "udiv":
                        add_ub(reach, f"{fn.name}:{dst}: udiv by zero or poison divisor", smt_or(rp, f"(= {rhs_v} {bv_const(0, w)})"))
                        if "exact" in flags:
                            op_ps.append(f"(not (= (bvurem {lhs} {rhs_v}) {bv_const(0, w)}))")
                        ex = f"(bvudiv {lhs} {rhs_v})"
                    elif op == "urem":
                        add_ub(reach, f"{fn.name}:{dst}: urem by zero or poison divisor", smt_or(rp, f"(= {rhs_v} {bv_const(0, w)})"))
                        ex = f"(bvurem {lhs} {rhs_v})"
                    elif op == "sdiv":
                        add_ub(reach, f"{fn.name}:{dst}: sdiv by zero or INT_MIN/-1", smt_or(rp, f"(= {rhs_v} {bv_const(0, w)})", f"(and (= {lhs} {bv_const(1 << (w - 1), w)}) (= {rhs_v} {bv_const((1 << w) - 1, w)}))"))
                        ex = f"(bvsdiv {lhs} {rhs_v})"
                    elif op == "srem":
                        add_ub(reach, f"{fn.name}:{dst}: srem by zero or INT_MIN/-1", smt_or(rp, f"(= {rhs_v} {bv_const(0, w)})", f"(and (= {lhs} {bv_const(1 << (w - 1), w)}) (= {rhs_v} {bv_const((1 << w) - 1, w)}))"))
                        ex = f"(bvsrem {lhs} {rhs_v})"
                    elif op == "shl":
                        op_ps.append(f"(bvuge {rhs_v} {bv_const(w, w)})")
                        if "nuw" in flags:
                            op_ps.append(f"(not (= (bvlshr (bvshl {lhs} {rhs_v}) {rhs_v}) {lhs}))")
                        ex = f"(bvshl {lhs} {rhs_v})"
                    elif op == "lshr":
                        op_ps.append(f"(bvuge {rhs_v} {bv_const(w, w)})")
                        if "exact" in flags:
                            op_ps.append(f"(not (= (bvshl (bvlshr {lhs} {rhs_v}) {rhs_v}) {lhs}))")
                        ex = f"(bvlshr {lhs} {rhs_v})"
                    elif op == "ashr":
                        op_ps.append(f"(bvuge {rhs_v} {bv_const(w, w)})")
                        ex = f"(bvashr {lhs} {rhs_v})"
                    elif op == "and":
                        ex = f"(bvand {lhs} {rhs_v})"
                    elif op == "or":
                        if "disjoint" in flags:
                            op_ps.append(f"(not (= (bvand {lhs} {rhs_v}) {bv_const(0, w)}))")
                        ex = f"(bvor {lhs} {rhs_v})"
                    elif op == "xor":
                        ex = f"(bvxor {lhs} {rhs_v})"
                    else:
                        raise ValueError(f"Unhandled binop {op}")

                    sym = self.define(self.fresh(op), f"(_ BitVec {w})", ex)
                    env[dst] = ("bv", w, sym, self.def_bool(f"{op}p", smt_or(*op_ps)))
                    continue

                # 15. LLVM intrinsics
                cm_call = re.match(r"^(?:tail\s+)?call\s+(?:[^@]+?)\s+@([A-Za-z0-9_.$]+)\((.*)\)", rhs)
                if cm_call:
                    callee, args_s = cm_call.group(1), cm_call.group(2)
                    args = split_top_level_commas(args_s)

                    def parse_typed_arg(a: str) -> Tuple[int, str, str]:
                        toks = a.strip().split()
                        for tok in toks:
                            if re.fullmatch(r"i\d+", tok):
                                w = parse_int_width(tok)
                                v, vp = eval_val(toks[-1], w)
                                return w, v, vp
                        raise ValueError(f"Cannot parse call arg {a!r}")

                    if callee.startswith("llvm.uadd.with.overflow.i"):
                        w, a0, p0 = parse_typed_arg(args[0])
                        _, a1, p1 = parse_typed_arg(args[1])
                        pp = self.def_bool("uaddp", smt_or(p0, p1))
                        sum_bv = self.define(self.fresh("uadd_s"), f"(_ BitVec {w})", f"(bvadd {a0} {a1})")
                        ovf_b = f"(bvugt (bvadd ((_ zero_extend 1) {a0}) ((_ zero_extend 1) {a1})) {bv_const((1 << w) - 1, w + 1)})"
                        ovf_bv = self.define(self.fresh("uadd_o"), "(_ BitVec 1)", f"(ite {ovf_b} (_ bv1 1) (_ bv0 1))")
                        env[dst] = ("struct2", (w, sum_bv, pp, 1, ovf_bv, pp), None, "false")
                        continue
                    if callee.startswith("llvm.usub.with.overflow.i"):
                        w, a0, p0 = parse_typed_arg(args[0])
                        _, a1, p1 = parse_typed_arg(args[1])
                        pp = self.def_bool("usubp", smt_or(p0, p1))
                        diff_bv = self.define(self.fresh("usub_d"), f"(_ BitVec {w})", f"(bvsub {a0} {a1})")
                        ovf_bv = self.define(self.fresh("usub_o"), "(_ BitVec 1)", f"(ite (bvult {a0} {a1}) (_ bv1 1) (_ bv0 1))")
                        env[dst] = ("struct2", (w, diff_bv, pp, 1, ovf_bv, pp), None, "false")
                        continue
                    if callee.startswith("llvm.umin.i"):
                        w, a0, p0 = parse_typed_arg(args[0])
                        _, a1, p1 = parse_typed_arg(args[1])
                        sym = self.define(self.fresh("umin"), f"(_ BitVec {w})", f"(ite (bvult {a0} {a1}) {a0} {a1})")
                        env[dst] = ("bv", w, sym, self.def_bool("uminp", smt_or(p0, p1)))
                        continue
                    if callee.startswith("llvm.umax.i"):
                        w, a0, p0 = parse_typed_arg(args[0])
                        _, a1, p1 = parse_typed_arg(args[1])
                        sym = self.define(self.fresh("umax"), f"(_ BitVec {w})", f"(ite (bvugt {a0} {a1}) {a0} {a1})")
                        env[dst] = ("bv", w, sym, self.def_bool("umaxp", smt_or(p0, p1)))
                        continue
                    if callee.startswith("llvm.ctlz.i"):
                        w, a0, p0 = parse_typed_arg(args[0])
                        _, izp, p1 = parse_typed_arg(args[1])
                        op_p = smt_or(p0, p1, f"(and (= {izp} (_ bv1 1)) (= {a0} {bv_const(0, w)}))")
                        ex = bv_const(w, w)
                        for bit in range(w):
                            ex = f"(ite (= ((_ extract {bit} {bit}) {a0}) (_ bv1 1)) {bv_const(w - 1 - bit, w)} {ex})"
                        sym = self.define(self.fresh("ctlz"), f"(_ BitVec {w})", ex)
                        env[dst] = ("bv", w, sym, self.def_bool("ctlzp", op_p))
                        continue
                    if callee.startswith("llvm.fshl.i"):
                        w, a0, p0 = parse_typed_arg(args[0])
                        _, a1, p1 = parse_typed_arg(args[1])
                        _, sh, p2 = parse_typed_arg(args[2])
                        sh_mod = f"(bvurem {sh} {bv_const(w, w)})"
                        shifted = f"(bvshl (concat {a0} {a1}) ((_ zero_extend {w}) {sh_mod}))"
                        sym = self.define(self.fresh("fshl"), f"(_ BitVec {w})", f"((_ extract {2*w - 1} {w}) {shifted})")
                        env[dst] = ("bv", w, sym, self.def_bool("fshlp", smt_or(p0, p1, p2)))
                        continue
                    if callee.startswith("llvm.fshr.i"):
                        w, a0, p0 = parse_typed_arg(args[0])
                        _, a1, p1 = parse_typed_arg(args[1])
                        _, sh, p2 = parse_typed_arg(args[2])
                        sh_mod = f"(bvurem {sh} {bv_const(w, w)})"
                        shifted = f"(bvlshr (concat {a0} {a1}) ((_ zero_extend {w}) {sh_mod}))"
                        sym = self.define(self.fresh("fshr"), f"(_ BitVec {w})", f"((_ extract {w - 1} 0) {shifted})")
                        env[dst] = ("bv", w, sym, self.def_bool("fshrp", smt_or(p0, p1, p2)))
                        continue
                    if callee.startswith("llvm.bswap.i"):
                        w, a0, p0 = parse_typed_arg(args[0])
                        nbytes = w // 8
                        parts = [f"((_ extract {b*8 + 7} {b*8}) {a0})" for b in range(nbytes)]
                        ex = parts[0]
                        for p in parts[1:]:
                            ex = f"(concat {ex} {p})"
                        sym = self.define(self.fresh("bswap"), f"(_ BitVec {w})", ex)
                        env[dst] = ("bv", w, sym, p0)
                        continue
                    if callee.startswith("llvm.abs.i"):
                        w, a0, p0 = parse_typed_arg(args[0])
                        _, imp, p1 = parse_typed_arg(args[1])
                        op_p = smt_or(p0, p1, f"(and (= {imp} (_ bv1 1)) (= {a0} {bv_const(1 << (w - 1), w)}))")
                        ex = f"(ite (bvslt {a0} {bv_const(0, w)}) (bvneg {a0}) {a0})"
                        sym = self.define(self.fresh("abs"), f"(_ BitVec {w})", ex)
                        env[dst] = ("bv", w, sym, self.def_bool("absp", op_p))
                        continue
                    if callee.startswith("llvm.usub.sat.i"):
                        w, a0, p0 = parse_typed_arg(args[0])
                        _, a1, p1 = parse_typed_arg(args[1])
                        ex = f"(ite (bvult {a0} {a1}) {bv_const(0, w)} (bvsub {a0} {a1}))"
                        sym = self.define(self.fresh("usubsat"), f"(_ BitVec {w})", ex)
                        env[dst] = ("bv", w, sym, self.def_bool("usubsatp", smt_or(p0, p1)))
                        continue
                    if callee.startswith("llvm.uadd.sat.i"):
                        w, a0, p0 = parse_typed_arg(args[0])
                        _, a1, p1 = parse_typed_arg(args[1])
                        ovf = f"(bvugt (bvadd ((_ zero_extend 1) {a0}) ((_ zero_extend 1) {a1})) {bv_const((1 << w) - 1, w + 1)})"
                        ex = f"(ite {ovf} {bv_const((1 << w) - 1, w)} (bvadd {a0} {a1}))"
                        sym = self.define(self.fresh("uaddsat"), f"(_ BitVec {w})", ex)
                        env[dst] = ("bv", w, sym, self.def_bool("uaddsatp", smt_or(p0, p1)))
                        continue
                    if all_funcs is not None and callee in all_funcs:
                        callee_fn = all_funcs[callee]
                        c_args: List[Tuple[str, str]] = []
                        arg_ps: List[str] = []
                        for a in args:
                            toks = a.strip().split()
                            val_tok = toks[-1]
                            if toks[0] == "ptr":
                                pinfo = env[val_tok]
                                c_args.append((pinfo[0], pinfo[2]))
                                arg_ps.append(pinfo[3])
                            else:
                                cw, cv, cp = parse_typed_arg(a)
                                c_args.append(("bv", cv))
                                arg_ps.append(cp)
                        cret, cret_p, crw = self.translate_function(
                            callee_fn, c_args, track_ub=track_ub, all_funcs=all_funcs
                        )
                        env[dst] = ("bv", crw, cret, self.def_bool("callp", smt_or(cret_p, *arg_ps)))
                        continue
                    raise ValueError(f"Unsupported call @{callee} in @{fn.name}: {inst}")

                # 16. extractvalue
                em = re.match(r"^extractvalue\s+\{[^}]+\}\s+(%[^,\s]+),\s*(\d+)$", rhs)
                if em:
                    src_s, idx = em.group(1), int(em.group(2))
                    sinfo = env[src_s]
                    if sinfo[0] != "struct2":
                        raise ValueError(f"extractvalue on non-struct2 {src_s} in @{fn.name}")
                    w0, e0, p0, w1, e1, p1 = sinfo[1]
                    if idx == 0:
                        env[dst] = ("bv", w0, e0, p0)
                    elif idx == 1:
                        env[dst] = ("bv", w1, e1, p1)
                    else:
                        raise ValueError(f"extractvalue index {idx} out of range in @{fn.name}")
                    continue

                # 17. freeze (eliminates poison)
                fm = re.match(r"^freeze\s+(i\d+)\s+(.+)$", rhs)
                if fm:
                    w = parse_int_width(fm.group(1))
                    fv, _ = eval_val(fm.group(2), w)
                    env[dst] = ("bv", w, fv, "false")
                    continue

                raise ValueError(f"Unsupported instruction in @{fn.name}: {inst}")

            block_alloca_out[lbl] = dict(alloca_mem)

        if not ret_branches:
            raise ValueError(f"Function @{fn.name} has no return instruction")
        rw = ret_branches[0][3]
        ret_expr = ret_branches[-1][1]
        ret_p = ret_branches[-1][2]
        for r_reach, r_val, r_p, _ in reversed(ret_branches[:-1]):
            ret_expr = f"(ite {r_reach} {r_val} {ret_expr})"
            ret_p = self.def_bool("retp", f"(ite {r_reach} {r_p} {ret_p})")
        ret_sym = self.define(self.fresh("ret"), f"(_ BitVec {rw})", ret_expr)
        return ret_sym, ret_p, rw


def run_solver(solver_cmd: List[str], smt2: str, timeout_s: int = 30) -> Tuple[str, float, str]:
    t0 = time.monotonic()
    proc = subprocess.run(
        solver_cmd,
        input=smt2,
        text=True,
        capture_output=True,
        timeout=timeout_s,
    )
    dt = time.monotonic() - t0
    out = proc.stdout.strip()
    err = proc.stderr.strip()
    first = out.splitlines()[0].strip() if out else ""
    if proc.returncode != 0 and first not in ("sat", "unsat", "unknown"):
        raise RuntimeError(f"Solver {solver_cmd} failed (rc={proc.returncode}): {err or out}")
    return first, dt, out


def verify_pair(
    funcs: Dict[str, IRFunction],
    base_name: str,
    solver_cmd: List[str],
    check_ub: bool,
    dump_dir: Optional[Path] = None,
) -> Tuple[bool, str]:
    ref_fn = funcs[f"{base_name}_ref"]
    fast_fn = funcs[f"{base_name}_fast"]
    if len(ref_fn.params) != len(fast_fn.params):
        return False, f"Arity mismatch: {len(ref_fn.params)} vs {len(fast_fn.params)}"

    arg_decls: List[str] = []
    arg_exprs: List[Tuple[str, str]] = []
    for idx, (pty, _) in enumerate(ref_fn.params):
        aname = f"arg_{idx}"
        if pty == "ptr":
            arg_decls.append(f"(declare-const {aname} (_ BitVec 256))")
            arg_exprs.append(("ptr_u256", aname))
        else:
            w = parse_int_width(pty)
            arg_decls.append(f"(declare-const {aname} (_ BitVec {w}))")
            arg_exprs.append(("bv", aname))

    b_ref = SMTBuilder("ref")
    b_fast = SMTBuilder("fast")
    ref_ret, _, rw = b_ref.translate_function(ref_fn, arg_exprs, track_ub=False, all_funcs=funcs)
    fast_ret, _, fw = b_fast.translate_function(fast_fn, arg_exprs, track_ub=check_ub, all_funcs=funcs)
    if rw != fw:
        return False, f"Return width mismatch: i{rw} vs i{fw}"

    logic = "QF_UFBV" if (b_ref.uf_decls or b_fast.uf_decls) else "QF_BV"
    common_lines = [
        f"(set-logic {logic})",
        *arg_decls,
        *b_ref.uf_decls.values(),
        *b_fast.uf_decls.values(),
        *b_ref.defs,
        *b_fast.defs,
    ]

    equiv_smt = "\n".join([
        *common_lines,
        f"(assert (not (= {ref_ret} {fast_ret})))",
        "(check-sat)",
        "(get-model)",
    ]) + "\n"

    if dump_dir is not None:
        dump_dir.mkdir(parents=True, exist_ok=True)
        (dump_dir / f"{base_name}.equiv.smt2").write_text(equiv_smt)

    res, dt_eq, raw_out = run_solver(solver_cmd, equiv_smt)
    if res != "unsat":
        return False, f"EQUIV FAILED ({res} in {dt_eq:.2f}s):\n{raw_out[:600]}"

    dt_ub = 0.0
    n_ub = len(b_fast.ub_conds)
    if check_ub and n_ub > 0:
        any_ub = smt_or(*(c for _, c in b_fast.ub_conds))
        ub_smt = "\n".join([
            f"(set-logic {logic})",
            *arg_decls,
            *b_fast.uf_decls.values(),
            *b_fast.defs,
            f"(assert {any_ub})",
            "(check-sat)",
        ]) + "\n"
        if dump_dir is not None:
            (dump_dir / f"{base_name}.ub.smt2").write_text(ub_smt)
        pres, dt_ub, _ = run_solver(solver_cmd, ub_smt)
        if pres != "unsat":
            culprits = []
            for desc, cond in b_fast.ub_conds:
                q = "\n".join([
                    f"(set-logic {logic})",
                    *arg_decls,
                    *b_fast.uf_decls.values(),
                    *b_fast.defs,
                    f"(assert {cond})",
                    "(check-sat)",
                ]) + "\n"
                r, _, _ = run_solver(solver_cmd, q)
                if r != "unsat":
                    culprits.append(desc)
            return False, f"UB/POISON POSSIBLE ({pres} in {dt_ub:.2f}s): {', '.join(culprits)}"

    return True, f"PROVED equiv ({dt_eq:.2f}s) + UB/poison-free ({n_ub} checks, {dt_ub:.2f}s)"


def main() -> int:
    ap = argparse.ArgumentParser(description="Verify Zig LLVM 20 IR ref/fast pairs via Bitwuzla/Z3")
    ap.add_argument("ll_file", type=Path, help="Path to Zig-emitted LLVM IR (.ll)")
    ap.add_argument("--solver", choices=["auto", "bitwuzla", "z3"], default="auto")
    ap.add_argument("--no-ub", action="store_true", help="Skip LLVM UB/poison checks")
    ap.add_argument("--dump-smt", type=Path, default=None, help="Directory to dump generated .smt2 files")
    ap.add_argument("--filter", type=str, default="", help="Only verify pairs matching substring")
    args = ap.parse_args()

    if args.solver == "auto":
        if shutil.which("bitwuzla"):
            solver_cmd = ["bitwuzla", "--produce-models"]
            solver_name = "bitwuzla"
        elif shutil.which("z3"):
            solver_cmd = ["z3", "-in"]
            solver_name = "z3"
        else:
            print("ERROR: Neither bitwuzla nor z3 found in PATH", file=sys.stderr)
            return 2
    elif args.solver == "bitwuzla":
        solver_cmd = ["bitwuzla", "--produce-models"]
        solver_name = "bitwuzla"
    else:
        solver_cmd = ["z3", "-in"]
        solver_name = "z3"

    ll_text = args.ll_file.read_text()
    funcs = parse_llvm_ir(ll_text)
    pairs = sorted(
        name[:-4]
        for name in funcs
        if name.endswith("_ref") and f"{name[:-4]}_fast" in funcs
    )
    if args.filter:
        pairs = [p for p in pairs if args.filter in p]
    if not pairs:
        print(f"ERROR: No <name>_ref / <name>_fast function pairs found in {args.ll_file}", file=sys.stderr)
        return 2

    print(f"[llvm-ir-verify] file={args.ll_file} solver={solver_name} pairs={len(pairs)}")
    failed = 0
    for base in pairs:
        ok, msg = verify_pair(funcs, base, solver_cmd, check_ub=not args.no_ub, dump_dir=args.dump_smt)
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {base}: {msg}")
        if not ok:
            failed += 1

    print(f"[llvm-ir-verify] summary: {len(pairs) - failed}/{len(pairs)} proved")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
