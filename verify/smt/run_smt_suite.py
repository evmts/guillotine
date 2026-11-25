#!/usr/bin/env python3
"""
Guillotine standalone SMT-LIB2 verification suite.

Generates one self-contained, human-readable `.smt2` file per theorem into
`verify/smt/proofs/`, solves each with Bitwuzla (primary) and/or Z3, and audits
`src/opcodes/opcode_data.zig` against the Cancun/Osaka opcode specification.

Every theorem file asserts its hypotheses and the NEGATION of its claim, so the
expected answer is `unsat` (no counterexample exists over the full bit-precise
input space). Every theorem with hypotheses also gets a vacuity file in
`proofs/vacuity/` that asserts only the hypotheses; its expected answer is `sat`,
which proves the hypotheses are not contradictory (a contradictory hypothesis
set would make any claim vacuously `unsat`).

Replay any proof by hand:
    bitwuzla verify/smt/proofs/sdiv_branchless_equiv.smt2
    z3       verify/smt/proofs/sdiv_branchless_equiv.smt2

Model drift guard: the Zig source text of every modeled function is hashed and
compared with `verify/smt/model_pins.json`. A changed function fails the suite
until a human re-reviews the SMT model and runs `--update-pins`. A missing
pin file also fails; only `--update-pins` creates it.

Dependencies: Python 3 standard library, `bitwuzla` and/or `z3` on PATH.
"""

from __future__ import annotations

import argparse
import ast
import concurrent.futures
import dataclasses
import hashlib
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable, Dict, List, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
PROOFS = HERE / "proofs"
PINS_FILE = HERE / "model_pins.json"

VERIFIED_OPS = "src/core/verified_ops.zig"
OPCODE_DATA = "src/opcodes/opcode_data.zig"
OPCODE_ENUM = "src/opcodes/opcode.zig"
GAS_CONSTANTS = "lib/voltaire/src/primitives/gas_constants.zig"
ARITH_SYN = "src/instructions/handlers_arithmetic_synthetic.zig"
BITWISE_SYN = "src/instructions/handlers_bitwise_synthetic.zig"
ADV_SYN = "src/instructions/handlers_advanced_synthetic.zig"
BYTECODE_ANALYZE = "src/bytecode/bytecode_analyze.zig"
STACK = "src/stack/stack.zig"

# ---------------------------------------------------------------------------
# Zig source extraction (read-only)
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class SourceRef:
    path: str
    fn: str


_source_cache: Dict[str, str] = {}


def read_source(rel: str) -> str:
    if rel not in _source_cache:
        _source_cache[rel] = (REPO / rel).read_text()
    return _source_cache[rel]


def extract_fn(ref: SourceRef) -> Tuple[int, str]:
    """Return (1-based line, full text) of `fn <name>(` in `ref.path` by brace matching."""
    text = read_source(ref.path)
    m = re.search(r"^[ \t]*(?:pub )?(?:inline )?fn " + re.escape(ref.fn) + r"\(", text, re.M)
    if not m:
        raise LookupError(f"{ref.path}: function `{ref.fn}` not found (model is stale)")
    start = m.start()
    brace = text.index("{", m.end())
    depth = 0
    i = brace
    while i < len(text):
        c = text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    line = text.count("\n", 0, start) + 1
    return line, text[start : i + 1]


def fn_hash(ref: SourceRef) -> str:
    _, body = extract_fn(ref)
    normalized = "\n".join(l.rstrip() for l in body.strip().splitlines())
    return hashlib.sha256(normalized.encode()).hexdigest()[:16]


# ---------------------------------------------------------------------------
# SMT-LIB2 text helpers
# ---------------------------------------------------------------------------


def bv(value: int, width: int) -> str:
    """Bit-vector literal: hex when width is a multiple of 4, else binary."""
    value &= (1 << width) - 1
    if width % 4 == 0:
        return "#x" + format(value, "0" + str(width // 4) + "x")
    return "#b" + format(value, "0" + str(width) + "b")


def w(value: int) -> str:
    return bv(value, 256)


def zext(term: str, from_w: int, to_w: int) -> str:
    if to_w == from_w:
        return term
    return f"((_ zero_extend {to_w - from_w}) {term})"


def conj(terms: Sequence[str]) -> str:
    if not terms:
        return "true"
    if len(terms) == 1:
        return terms[0]
    return "(and\n    " + "\n    ".join(terms) + ")"


MIN256 = w(1 << 255)
ONES256 = w((1 << 256) - 1)

COMMON_DEFS = """(define-sort Word () (_ BitVec 256))"""

# Branchless two's-complement helpers transcribed from verified_ops.zig.
ABS_TWO_COMP = f"""; verified_ops.zig absTwoComp: sign = x >> 255; mask = 0 -% sign; (x ^ mask) -% mask
(define-fun absTwoComp ((x Word)) Word
  (let ((mask (bvsub {w(0)} (bvlshr x {w(255)}))))
    (bvsub (bvxor x mask) mask)))"""

SPEC_ABS = f"""; Yellow Paper |x| for a two's-complement word, as an unsigned word (|MIN| = 2^255).
(define-fun specAbs ((x Word)) Word
  (ite (bvslt x {w(0)}) (bvneg x) x))"""


def clz_chain(var: str) -> str:
    """EIP-7939 CLZ as a priority chain: index of the highest set bit from bit 255; 256 if none."""
    out = w(256)
    for k in range(256):  # build from bit 0 outward so bit 255 is the outermost test
        bit = k
        out = f"(ite (= ((_ extract {bit} {bit}) {var}) #b1) {w(255 - bit)} {out})"
    return out


def clz_binary_search_fun(name: str) -> str:
    """Zero-defined `llvm.ctlz.i256(x, false)` lowered as the Hacker's Delight binary search."""
    lines = [f"(define-fun {name} ((x0 Word)) Word"]
    lets = []
    x, n = "x0", w(0)
    depth = 0
    for i, s in enumerate([128, 64, 32, 16, 8, 4, 2, 1]):
        z = f"z{i}"
        lets.append(f"  (let (({z} (= (bvlshr {x} {w(256 - s)}) {w(0)})))")
        lets.append(
            f"  (let ((n{i + 1} (ite {z} (bvadd {n} {w(s)}) {n})) (x{i + 1} (ite {z} (bvshl {x} {w(s)}) {x})))"
        )
        x, n = f"x{i + 1}", f"n{i + 1}"
        depth += 2
    lets.append(f"    (bvadd {n} (bvsub {w(1)} (bvlshr {x} {w(255)})))" + ")" * depth + ")")
    return "\n".join(lines + lets)


# ---------------------------------------------------------------------------
# Theorem model
# ---------------------------------------------------------------------------


@dataclasses.dataclass
class Theorem:
    name: str
    claim: str
    logic: str
    decls: str  # declare-const / declare-fun / define-fun block
    hyps: List[Tuple[str, str]]  # (label, term)
    goal: str
    sources: List[SourceRef]
    notes: str = ""
    structural_error: str = ""  # set when Python-level structure (e.g. stack shape) mismatches
    # Minimum per-query solver budget in seconds; --timeout applies when larger.
    timeout: int = 0

    def render(self, vacuity: bool) -> str:
        status = "sat" if vacuity else "unsat"
        out: List[str] = []
        out.append(";; " + "=" * 74)
        out.append(f";; Theorem : {self.name}" + ("  [VACUITY CHECK]" if vacuity else ""))
        out.append(";; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)")
        out.append(";; Claim   :")
        for l in self.claim.strip().splitlines():
            out.append(";;   " + l)
        if self.notes:
            out.append(";; Notes   :")
            for l in self.notes.strip().splitlines():
                out.append(";;   " + l)
        if vacuity:
            out.append(";; This file asserts ONLY the hypotheses. Expected `sat`: the hypotheses")
            out.append(";; are consistent, so the companion `unsat` proof is not vacuous.")
        else:
            out.append(";; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no")
            out.append(";;           counterexample exists over the whole input space.")
        out.append(";; Modeled Zig source:")
        for ref in self.sources:
            line, body = extract_fn(ref)
            out.append(f";; --- {ref.path}:{line} ({ref.fn})")
            for l in body.splitlines():
                out.append(";;   | " + l)
        out.append(";; " + "=" * 74)
        out.append("(set-info :smt-lib-version 2.6)")
        out.append(f"(set-info :status {status})")
        out.append(f"(set-logic {self.logic})")
        out.append(COMMON_DEFS)
        out.append("")
        out.append(self.decls.strip())
        out.append("")
        if self.hyps:
            out.append(";; ---- Hypotheses")
            for label, term in self.hyps:
                out.append(f"; {label}")
                out.append(f"(assert {term})")
            out.append("")
        if not vacuity:
            out.append(";; ---- Negated claim (a model would be a counterexample)")
            out.append(f"(assert (not {self.goal}))")
        out.append("(check-sat)")
        out.append("(exit)")
        return "\n".join(out) + "\n"


THEOREMS: List[Theorem] = []


def theorem(t: Theorem) -> None:
    THEOREMS.append(t)


def src(path: str, *fns: str) -> List[SourceRef]:
    return [SourceRef(path, f) for f in fns]


# ---------------------------------------------------------------------------
# SDIV / SMOD (QF_UFBV, uninterpreted unsigned divide / remainder)
# ---------------------------------------------------------------------------


def uf_axioms(fn: str, args: List[Tuple[str, str]], at_one_is_x: bool) -> List[Tuple[str, str]]:
    """Ground instances of `f(x,0) = 0` and `f(x,1) = x` (div) or `f(x,1) = 0` (rem)."""
    hyps = []
    for x, y in args:
        app = f"({fn} {x} {y})"
        hyps.append((f"axiom {fn}(x, 0) = 0  at x = {x}", f"(=> (= {y} {w(0)}) (= {app} {w(0)}))"))
        one = x if at_one_is_x else w(0)
        tag = "x" if at_one_is_x else "0"
        hyps.append((f"axiom {fn}(x, 1) = {tag}  at x = {x}", f"(=> (= {y} {w(1)}) (= {app} {one}))"))
    return hyps


theorem(
    Theorem(
        name="sdiv_branchless_equiv",
        claim=f"""For ALL 2^512 (top, second): Guillotine's branchless SDIV
  sdivFromUnsignedQuotient(top, second, udiv(absTwoComp(top), absTwoComp(second)))
equals the Yellow Paper SDIV:
  0                                  if second = 0
  -2^255                             if top = -2^255 and second = -1
  sgn(top*second) * floor(|top|/|second|)  otherwise.
udiv is UNINTERPRETED; the only facts used are udiv(x,0)=0 and udiv(x,1)=x.
The fast path contains no second==0 or MIN/-1 branch.""",
        logic="QF_UFBV",
        decls=f"""(declare-fun udiv ((Word) (Word)) Word)
(declare-const top Word)
(declare-const second Word)
{ABS_TWO_COMP}
{SPEC_ABS}
; verified_ops.zig sdivFromUnsignedQuotient
(define-fun sdivFast ((top Word) (second Word)) Word
  (let ((q (udiv (absTwoComp top) (absTwoComp second))))
  (let ((result_mask (bvsub {w(0)} (bvxor (bvlshr top {w(255)}) (bvlshr second {w(255)})))))
    (bvsub (bvxor q result_mask) result_mask))))
; Yellow Paper SDIV (explicit special cases, sign by comparison, negation by bvneg)
(define-fun sdivSpec ((a Word) (b Word)) Word
  (ite (= b {w(0)}) {w(0)}
  (ite (and (= a {MIN256}) (= b {ONES256})) {MIN256}
  (let ((q (udiv (specAbs a) (specAbs b))))
    (ite (xor (bvslt a {w(0)}) (bvslt b {w(0)})) (bvneg q) q)))))""",
        hyps=uf_axioms(
            "udiv",
            [("(absTwoComp top)", "(absTwoComp second)"), ("(specAbs top)", "(specAbs second)")],
            True,
        ),
        goal="(= (sdivFast top second) (sdivSpec top second))",
        sources=src(VERIFIED_OPS, "sdivFromUnsignedQuotient", "absTwoComp"),
        notes="""Axioms are instantiated at every udiv application (QF_UFBV, no quantifiers).
Dropping hypotheses only strengthens an unsat result, so the proof holds for
every function satisfying the two axioms, including floor division of naturals.""",
    )
)

theorem(
    Theorem(
        name="smod_branchless_equiv",
        claim=f"""For ALL 2^512 (top, second): Guillotine's branchless SMOD
  smodFromUnsignedRem(top, urem(absTwoComp(top), absTwoComp(second)))
equals the Yellow Paper SMOD:
  0                               if second = 0
  0                               if top = -2^255 and second = -1
  sgn(top) * (|top| mod |second|)  otherwise.
urem is UNINTERPRETED; the only facts used are urem(x,0)=0 and urem(x,1)=0.
The fast path contains no second==0 or MIN%-1 branch.""",
        logic="QF_UFBV",
        decls=f"""(declare-fun urem ((Word) (Word)) Word)
(declare-const top Word)
(declare-const second Word)
{ABS_TWO_COMP}
{SPEC_ABS}
; verified_ops.zig smodFromUnsignedRem
(define-fun smodFast ((top Word) (second Word)) Word
  (let ((r (urem (absTwoComp top) (absTwoComp second))))
  (let ((top_mask (bvsub {w(0)} (bvlshr top {w(255)}))))
    (bvsub (bvxor r top_mask) top_mask))))
; Yellow Paper SMOD
(define-fun smodSpec ((a Word) (b Word)) Word
  (ite (= b {w(0)}) {w(0)}
  (ite (and (= a {MIN256}) (= b {ONES256})) {w(0)}
  (let ((r (urem (specAbs a) (specAbs b))))
    (ite (bvslt a {w(0)}) (bvneg r) r)))))""",
        hyps=uf_axioms(
            "urem",
            [("(absTwoComp top)", "(absTwoComp second)"), ("(specAbs top)", "(specAbs second)")],
            False,
        ),
        goal="(= (smodFast top second) (smodSpec top second))",
        sources=src(VERIFIED_OPS, "smodFromUnsignedRem", "absTwoComp"),
    )
)

# ---------------------------------------------------------------------------
# SIGNEXTEND / SAR / BYTE / CLZ / EXP byte length
# ---------------------------------------------------------------------------

SIGNEXTEND_DEFS = f"""(declare-const ext Word)
(declare-const value Word)
; verified_ops.zig signextendRef
(define-fun signextendRef ((ext Word) (value Word)) Word
  (ite (bvuge ext {w(31)}) value
  (let ((byte_index ((_ extract 7 0) ext)))
  (let ((bit_index (bvadd (bvmul byte_index #x08) #x07)))
  (let ((sign_bit_mask (bvshl {w(1)} {zext("bit_index", 8, 256)})))
  (let ((is_negative (not (= (bvand value sign_bit_mask) {w(0)}))))
  (let ((value_mask (bvsub sign_bit_mask {w(1)})))
    (ite is_negative (bvor value (bvnot value_mask)) (bvand value value_mask)))))))))
; verified_ops.zig signextendFast
(define-fun signextendFast ((ext Word) (value Word)) Word
  (ite (bvuge ext {w(31)}) value
  (let ((byte_index ((_ extract 7 0) ext)))
  (let ((shift ((_ zero_extend 248) (bvsub #xf8 (bvshl byte_index #x03)))))
    (bvashr (bvshl value shift) shift)))))"""

theorem(
    Theorem(
        name="signextend_branchless_equiv",
        claim="For ALL 2^512 (ext, value): signextendFast(ext, value) = signextendRef(ext, value).",
        logic="QF_BV",
        decls=SIGNEXTEND_DEFS,
        hyps=[],
        goal="(= (signextendFast ext value) (signextendRef ext value))",
        sources=src(VERIFIED_OPS, "signextendRef", "signextendFast"),
        notes="All u8 arithmetic is 8-bit modular here; signextend_u8_no_overflow proves it never wraps.",
    )
)

theorem(
    Theorem(
        name="signextend_u8_no_overflow",
        claim="""For ALL ext < 31: the u8 operations in signextendRef (byte_index*8+7) and
signextendFast (248 - (byte_index<<3)) never wrap, and the @intCast(ext) to u8
in signextendRef is in range. So Zig safety checks never fire and modular
arithmetic in the equivalence proof equals integer arithmetic.""",
        logic="QF_BV",
        decls="(declare-const ext Word)",
        hyps=[("guarded branch: ext < 31", f"(bvult ext {w(31)})")],
        goal=f"""(let ((bi ((_ extract 7 0) ext)) (bi16 ((_ zero_extend 8) ((_ extract 7 0) ext))))
  (and (bvule ext {w(255)})
       (= ((_ zero_extend 8) (bvadd (bvmul bi #x08) #x07)) (bvadd (bvmul bi16 #x0008) #x0007))
       (= ((_ zero_extend 8) (bvshl bi #x03)) (bvshl bi16 #x0003))
       (bvule (bvshl bi #x03) #xf8)))""",
        sources=src(VERIFIED_OPS, "signextendRef", "signextendFast"),
    )
)


def signextend_yp_bits(ext: str, value: str) -> str:
    """Yellow Paper SIGNEXTEND, bit by bit (LSB index j): t = 8*ext+7 (ext < 31);
    bit j = value[t] if j > t else value[j]. Built as a 256-bit concat."""
    t = f"(bvadd (bvmul {ext} {w(8)}) {w(7)})"
    sign = f"((_ extract 0 0) (bvlshr {value} {t}))"
    bits = []
    for j in range(255, -1, -1):
        bits.append(f"(ite (bvugt {w(j)} t) sign ((_ extract {j} {j}) {value}))")
    body = "(concat " + " ".join(bits) + ")"
    return f"(ite (bvuge {ext} {w(31)}) {value} (let ((t {t})) (let ((sign {sign})) {body})))"


theorem(
    Theorem(
        name="signextend_ref_matches_yellow_paper",
        claim="""For ALL 2^512 (ext, value): signextendRef equals the Yellow Paper bitwise
definition: for b = 8*ext+7 with ext < 31, every bit above b copies bit b and every
bit at or below b is kept; ext >= 31 returns value unchanged.""",
        logic="QF_BV",
        decls=SIGNEXTEND_DEFS,
        hyps=[],
        goal=f"(= (signextendRef ext value) {signextend_yp_bits('ext', 'value')})",
        sources=src(VERIFIED_OPS, "signextendRef"),
    )
)

theorem(
    Theorem(
        name="sar_branchless_equiv",
        claim="For ALL 2^512 (shift, value): sarFast(shift, value) = sarRef(shift, value).",
        logic="QF_BV",
        decls=f"""(declare-const shift Word)
(declare-const value Word)
; verified_ops.zig sarRef
(define-fun sarRef ((shift Word) (value Word)) Word
  (ite (bvuge shift {w(256)})
       (ite (bvslt value {w(0)}) {ONES256} {w(0)})
       (bvashr value {zext("((_ extract 7 0) shift)", 8, 256)})))
; verified_ops.zig sarFast
(define-fun sarFast ((shift Word) (value Word)) Word
  (let ((shift_amt (ite (bvuge shift {w(255)}) #xff ((_ extract 7 0) shift))))
    (bvashr value ((_ zero_extend 248) shift_amt))))""",
        hyps=[],
        goal="(= (sarFast shift value) (sarRef shift value))",
        sources=src(VERIFIED_OPS, "sarRef", "sarFast"),
    )
)

BYTE_DEFS = f"""(declare-const index Word)
(declare-const value Word)
; verified_ops.zig byteRef
(define-fun byteRef ((index Word) (value Word)) Word
  (ite (bvuge index {w(32)}) {w(0)}
  (let ((shift_bits (bvmul (bvsub #x1f ((_ extract 7 0) index)) #x08)))
    (bvand (bvlshr value ((_ zero_extend 248) shift_bits)) {w(0xFF)}))))
; verified_ops.zig byteFast
(define-fun byteFast ((index Word) (value Word)) Word
  (ite (bvuge index {w(32)}) {w(0)}
  (let ((shift_bits (bvshl (bvsub #x1f ((_ extract 7 0) index)) #x03)))
    (bvand (bvlshr value ((_ zero_extend 248) shift_bits)) {w(0xFF)}))))"""

theorem(
    Theorem(
        name="byte_fast_equiv",
        claim="For ALL 2^512 (index, value): byteFast(index, value) = byteRef(index, value).",
        logic="QF_BV",
        decls=BYTE_DEFS,
        hyps=[],
        goal="(= (byteFast index value) (byteRef index value))",
        sources=src(VERIFIED_OPS, "byteRef", "byteFast"),
    )
)


def byte_yp(index: str, value: str) -> str:
    """Yellow Paper BYTE: big-endian byte `index` of value (byte 0 = most significant), 0 if index >= 32."""
    out = w(0)
    for i in range(31, -1, -1):
        hi = 255 - 8 * i
        out = f"(ite (= {index} {w(i)}) ((_ zero_extend 248) ((_ extract {hi} {hi - 7}) {value})) {out})"
    return out


theorem(
    Theorem(
        name="byte_ref_matches_yellow_paper",
        claim="""For ALL 2^512 (index, value): byteRef equals the Yellow Paper BYTE, which
selects big-endian byte `index` (byte 0 = bits 255..248) and returns 0 for index >= 32.""",
        logic="QF_BV",
        decls=BYTE_DEFS,
        hyps=[],
        goal=f"(= (byteRef index value) {byte_yp('index', 'value')})",
        sources=src(VERIFIED_OPS, "byteRef"),
    )
)

CLZ_DEFS = f"""(declare-const value Word)
; Zig @clz(u256) lowers to llvm.ctlz.i256(x, i1 false): zero input is DEFINED as 256.
; Modeled independently as the Hacker's Delight branchless binary search.
{clz_binary_search_fun("zigClz")}
; verified_ops.zig clzFast = @clz(value)
(define-fun clzFast ((value Word)) Word (zigClz value))
; verified_ops.zig clzRef, with EIP-7939 CLZ as a highest-set-bit priority chain
(define-fun clzRef ((value Word)) Word
  (ite (= value {w(0)}) {w(256)}
    {clz_chain("value")}))"""

theorem(
    Theorem(
        name="clz_fast_equiv",
        claim="""For ALL 2^256 values: clzFast(value) = clzRef(value), where clzRef is EIP-7939
(256 for zero, else 255 - floor(log2 value)) and clzFast is the zero-defined @clz.""",
        logic="QF_BV",
        decls=CLZ_DEFS,
        hyps=[],
        goal="(= (clzFast value) (clzRef value))",
        sources=src(VERIFIED_OPS, "clzRef", "clzFast"),
    )
)


def exp_ref_unrolled(var: str) -> str:
    """expGasByteLenRef: `while (temp > 0) : (temp >>= 8) byte_size += 1;` After k iterations
    temp = exp >> 8k, and the loop stops for good once temp = 0 (exp >> 256 = 0), so the
    count is the number of k in [0, 32) with exp >> 8k != 0."""
    terms = [f"(ite (= (bvlshr {var} {w(8 * k)}) {w(0)}) #x00000000 #x00000001)" for k in range(32)]
    out = terms[0]
    for t in terms[1:]:
        out = f"(bvadd {out}\n    {t})"
    return out


theorem(
    Theorem(
        name="exp_gas_bytes_equiv",
        claim="""For ALL 2^256 exponents: expGasByteLenFast(exp) = expGasByteLenRef(exp) as u32,
and the u32 subtraction 263 - @clz(exp) never underflows (Zig safety check never fires).""",
        logic="QF_BV",
        decls=f"""(declare-const exp Word)
{clz_binary_search_fun("zigClz")}
; verified_ops.zig expGasByteLenFast: (263 - @as(u32, @clz(exp))) >> 3
(define-fun expGasByteLenFast ((exp Word)) (_ BitVec 32)
  (bvlshr (bvsub #x00000107 ((_ extract 31 0) (zigClz exp))) #x00000003))
; verified_ops.zig expGasByteLenRef, loop unrolled 32 times
(define-fun expGasByteLenRef ((exp Word)) (_ BitVec 32)
  {exp_ref_unrolled("exp")})""",
        hyps=[],
        goal=f"""(and (= (expGasByteLenFast exp) (expGasByteLenRef exp))
     (bvule (zigClz exp) {w(263)}))""",
        sources=src(VERIFIED_OPS, "expGasByteLenRef", "expGasByteLenFast"),
    )
)

# ---------------------------------------------------------------------------
# Memory bounds, word count, alignment, gas
# ---------------------------------------------------------------------------

MEMORY_LIMIT = 0xFFFFFF  # src/frame/frame_config.zig default memory_limit


def memory_bounds_defs(limit_term: str) -> str:
    return f"""; verified_ops.zig checkMemoryBoundsRef
(define-fun checkMemoryBoundsRef ((offset Word) (size (_ BitVec 64)) (L (_ BitVec 64))) Bool
  (ite (bvugt offset {zext(bv(2**64 - 1, 64), 64, 256)}) false
  (let ((off_u ((_ extract 63 0) offset)))
  (let ((sum65 (bvadd ((_ zero_extend 1) off_u) ((_ zero_extend 1) size))))
  (ite (= ((_ extract 64 64) sum65) #b1) false
    (bvule ((_ extract 63 0) sum65) L))))))
; verified_ops.zig checkMemoryBoundsFast
(define-fun checkMemoryBoundsFast ((offset Word) (size (_ BitVec 64)) (L (_ BitVec 64))) Bool
  (ite (bvugt size L) false
    (bvule offset ((_ zero_extend 192) (bvsub L size)))))
(define-fun L () (_ BitVec 64) {limit_term})"""


for tname, size_term, desc in [
    ("memory_bounds_dyn_equiv", None, "ALL u64 sizes (dynamic-size ops: CALLDATACOPY, RETURN, ...)"),
    ("memory_bounds_word32_equiv", bv(32, 64), "size = 32 (MLOAD / MSTORE)"),
    ("memory_bounds_byte1_equiv", bv(1, 64), "size = 1 (MSTORE8)"),
]:
    decl = "(declare-const offset Word)\n"
    if size_term is None:
        decl += "(declare-const size (_ BitVec 64))\n"
        s = "size"
    else:
        s = size_term
    theorem(
        Theorem(
            name=tname,
            claim=f"""For ALL u256 offsets and {desc}, with memory_limit L = 0xFFFFFF:
checkMemoryBoundsFast(offset, size, L) = checkMemoryBoundsRef(offset, size, L).""",
            logic="QF_BV",
            decls=decl + memory_bounds_defs(bv(MEMORY_LIMIT, 64)),
            hyps=[],
            goal=f"(= (checkMemoryBoundsFast offset {s} L) (checkMemoryBoundsRef offset {s} L))",
            sources=src(VERIFIED_OPS, "checkMemoryBoundsRef", "checkMemoryBoundsFast"),
        )
    )

theorem(
    Theorem(
        name="memory_bounds_any_limit_equiv",
        claim="""For ALL u256 offsets, u64 sizes, AND u64 memory limits L:
checkMemoryBoundsFast = checkMemoryBoundsRef. The rewrite does not depend on the
default limit; any FrameConfig.memory_limit is covered.""",
        logic="QF_BV",
        decls="(declare-const offset Word)\n(declare-const size (_ BitVec 64))\n(declare-const limit (_ BitVec 64))\n"
        + memory_bounds_defs("limit"),
        hyps=[],
        goal="(= (checkMemoryBoundsFast offset size L) (checkMemoryBoundsRef offset size L))",
        sources=src(VERIFIED_OPS, "checkMemoryBoundsRef", "checkMemoryBoundsFast"),
    )
)

theorem(
    Theorem(
        name="memory_word_count_equiv",
        claim="""For ALL u32 byte sizes: memoryWordCountFast(b) = memoryWordCountRef(b) = ceil(b/32)
(u64 arithmetic; the reference holds on the full u32 domain, not only b <= 0xFFFFFF).""",
        logic="QF_BV",
        decls="""(declare-const byte_size (_ BitVec 32))
; verified_ops.zig memoryWordCountRef
(define-fun memoryWordCountRef ((byte_size (_ BitVec 32))) (_ BitVec 64)
  (let ((b ((_ zero_extend 32) byte_size)))
    (ite (= b #x0000000000000000) #x0000000000000000
      (bvadd (bvudiv (bvsub b #x0000000000000001) #x0000000000000020) #x0000000000000001))))
; verified_ops.zig memoryWordCountFast
(define-fun memoryWordCountFast ((byte_size (_ BitVec 32))) (_ BitVec 64)
  (bvlshr (bvadd ((_ zero_extend 32) byte_size) #x000000000000001f) #x0000000000000005))""",
        hyps=[],
        goal="""(let ((wc (memoryWordCountFast byte_size)) (b ((_ zero_extend 32) byte_size)))
  (and (= wc (memoryWordCountRef byte_size))
       (bvuge (bvmul wc #x0000000000000020) b)
       (bvult (bvsub (bvmul wc #x0000000000000020) b) #x0000000000000020)))""",
        sources=src(VERIFIED_OPS, "memoryWordCountRef", "memoryWordCountFast"),
    )
)

theorem(
    Theorem(
        name="memory_align_up_32_equiv",
        claim="""For ALL u32 n <= 0xFFFFFF: alignUp32(n) = (n + 31) & ~31 never overflows u32,
equals 32 * memoryWordCountRef(n), is a multiple of 32, is >= n, and is < n + 32.""",
        logic="QF_BV",
        decls="""(declare-const n (_ BitVec 32))
; verified_ops.zig alignUp32
(define-fun alignUp32 ((n (_ BitVec 32))) (_ BitVec 32)
  (bvand (bvadd n #x0000001f) (bvnot #x0000001f)))
(define-fun memoryWordCountRef ((byte_size (_ BitVec 32))) (_ BitVec 64)
  (let ((b ((_ zero_extend 32) byte_size)))
    (ite (= b #x0000000000000000) #x0000000000000000
      (bvadd (bvudiv (bvsub b #x0000000000000001) #x0000000000000020) #x0000000000000001))))""",
        hyps=[("domain: n <= 0xFFFFFF (memory_limit)", "(bvule n #x00ffffff)")],
        goal="""(let ((a (alignUp32 n)) (n64 ((_ zero_extend 32) n)))
  (and (= ((_ zero_extend 32) (bvadd n #x0000001f)) (bvadd n64 #x000000000000001f))
       (= ((_ zero_extend 32) a) (bvmul (memoryWordCountRef n) #x0000000000000020))
       (= (bvand a #x0000001f) #x00000000)
       (bvuge a n)
       (bvult (bvsub a n) #x00000020)))""",
        sources=src(VERIFIED_OPS, "alignUp32", "memoryWordCountRef"),
    )
)

theorem(
    Theorem(
        name="memory_gas_mono_and_no_overflow",
        claim="""For ALL words w1, w2 <= 524288 (memory_limit 0xFFFFFF = 16 MiB):
  (1) memoryGasCost(w) = 3w + floor(w^2/512) is computed exactly in u64 (no wrap),
  (2) memoryGasCost(w) <= 538443776,
  (3) memoryGasCost(524288) = 538443776 (the bound is tight),
  (4) w1 <= w2 implies memoryGasCost(w1) <= memoryGasCost(w2) (monotone).""",
        logic="QF_BV",
        decls="""; A u64 `words <= 524288 = 2^19` is exactly the zero extension of a 20-bit value.
(declare-const a1 (_ BitVec 20))
(declare-const a2 (_ BitVec 20))
(define-fun w1 () (_ BitVec 64) ((_ zero_extend 44) a1))
(define-fun w2 () (_ BitVec 64) ((_ zero_extend 44) a2))
; verified_ops.zig memoryGasCost (u64 wrapping model)
(define-fun memoryGasCost ((words (_ BitVec 64))) (_ BitVec 64)
  (bvadd (bvmul words #x0000000000000003) (bvlshr (bvmul words words) #x0000000000000009)))
; Exact integer cost in 128 bits
(define-fun exactCost ((words (_ BitVec 64))) (_ BitVec 128)
  (let ((x ((_ zero_extend 64) words)))
    (bvadd (bvmul x ((_ zero_extend 64) #x0000000000000003))
           (bvlshr (bvmul x x) ((_ zero_extend 64) #x0000000000000009)))))""",
        hyps=[
            ("domain: w1 <= 524288", "(bvule a1 #x80000)"),
            ("domain: w2 <= 524288", "(bvule a2 #x80000)"),
        ],
        goal="""(and (= ((_ zero_extend 64) (memoryGasCost w1)) (exactCost w1))
     (bvule (memoryGasCost w1) #x0000000020180000)
     (= (memoryGasCost #x0000000000080000) #x0000000020180000)
     (=> (bvule w1 w2) (bvule (memoryGasCost w1) (memoryGasCost w2))))""",
        sources=src(VERIFIED_OPS, "memoryGasCost"),
        notes="538443776 = 0x20180000 = 3*2^19 + 2^29.",
        # The 64-bit words*words product is hard for bit-blasting: Bitwuzla 0.11.0
        # needs ~540 s on nyc-01 and Z3 5.3.3 exceeds 60 s.
        timeout=1800,
    )
)

# ---------------------------------------------------------------------------
# Basic-block stack guard and dense jump bounds
# ---------------------------------------------------------------------------

GUARD_DEFS = """(declare-const size (_ BitVec 32))
(declare-const min_stack (_ BitVec 16))
(declare-const max_stack (_ BitVec 16))
; BlockStackResult encoding: ok = 0, underflow = 1, overflow = 2
(define-fun OK () (_ BitVec 2) #b00)
(define-fun UNDERFLOW () (_ BitVec 2) #b01)
(define-fun OVERFLOW () (_ BitVec 2) #b10)
; verified_ops.zig blockStackGuardRef
(define-fun blockStackGuardRef ((size (_ BitVec 32)) (min_stack (_ BitVec 16)) (max_stack (_ BitVec 16)) (cap (_ BitVec 32))) (_ BitVec 2)
  (ite (bvult size ((_ zero_extend 16) min_stack)) UNDERFLOW
  (ite (bvugt (bvadd ((_ zero_extend 32) size) ((_ zero_extend 48) max_stack)) ((_ zero_extend 32) cap)) OVERFLOW
    OK)))
; verified_ops.zig blockStackGuardFast
(define-fun blockStackGuardFast ((size (_ BitVec 32)) (min_stack (_ BitVec 16)) (max_stack (_ BitVec 16)) (cap (_ BitVec 32))) (_ BitVec 2)
  (let ((min_u ((_ zero_extend 16) min_stack)) (max_u ((_ zero_extend 16) max_stack)))
  (let ((needed (bvadd min_u max_u)))
  (ite (and (bvule needed cap) (bvule (bvsub size min_u) (bvsub cap needed))) OK
    (ite (bvult size min_u) UNDERFLOW OVERFLOW)))))"""

theorem(
    Theorem(
        name="block_stack_guard_equiv",
        claim="""For ALL u32 size, u16 min_stack, u16 max_stack, with stack_capacity = 1024:
blockStackGuardFast = blockStackGuardRef (ok / underflow / overflow all agree), and
min_u + max_u cannot wrap u32.""",
        logic="QF_BV",
        decls=GUARD_DEFS + "\n(define-fun CAP () (_ BitVec 32) #x00000400)",
        hyps=[],
        goal="""(and (= (blockStackGuardFast size min_stack max_stack CAP) (blockStackGuardRef size min_stack max_stack CAP))
     (bvuge (bvadd ((_ zero_extend 16) min_stack) ((_ zero_extend 16) max_stack)) ((_ zero_extend 16) min_stack)))""",
        sources=src(VERIFIED_OPS, "blockStackGuardRef", "blockStackGuardFast"),
    )
)

theorem(
    Theorem(
        name="block_stack_guard_any_capacity_equiv",
        claim="""For ALL u32 size, u16 min_stack, u16 max_stack, and ALL stack capacities
cap <= 2^31: blockStackGuardFast = blockStackGuardRef. Covers every FrameConfig.stack_size.""",
        logic="QF_BV",
        decls=GUARD_DEFS + "\n(declare-const cap (_ BitVec 32))",
        hyps=[("domain: cap <= 2^31", "(bvule cap #x80000000)")],
        goal="(= (blockStackGuardFast size min_stack max_stack cap) (blockStackGuardRef size min_stack max_stack cap))",
        sources=src(VERIFIED_OPS, "blockStackGuardRef", "blockStackGuardFast"),
    )
)

for pc_bits in (8, 12, 16, 32):
    max_pc = (1 << pc_bits) - 1
    theorem(
        Theorem(
            name=f"dense_jump_bounds_equiv_u{pc_bits}",
            claim=f"""PcType = u{pc_bits}. For ALL u256 dest and ALL u32 dense_len <= maxInt(u{pc_bits}) + 1:
denseJumpInBoundsFast(dest, dense_len) = denseJumpInBoundsRef(dest, dense_len, u{pc_bits}),
and the @intCast(dest) to u32 in the reference is in range when reached.""",
            logic="QF_BV",
            decls=f"""(declare-const dest Word)
(declare-const dense_len (_ BitVec 32))
(define-fun MAX_PC () Word {w(max_pc)})
; verified_ops.zig denseJumpInBoundsRef
(define-fun denseJumpInBoundsRef ((dest Word) (dense_len (_ BitVec 32))) Bool
  (ite (bvugt dest MAX_PC) false
    (bvult ((_ extract 31 0) dest) dense_len)))
; verified_ops.zig denseJumpInBoundsFast
(define-fun denseJumpInBoundsFast ((dest Word) (dense_len (_ BitVec 32))) Bool
  (bvult dest ((_ zero_extend 224) dense_len)))""",
            hyps=[
                (
                    f"precondition: dense_len <= maxInt(u{pc_bits}) + 1",
                    f"(bvule ((_ zero_extend 32) dense_len) {bv(max_pc + 1, 64)})",
                )
            ],
            goal="""(and (= (denseJumpInBoundsFast dest dense_len) (denseJumpInBoundsRef dest dense_len))
     (=> (bvule dest MAX_PC) (bvule dest #x00000000000000000000000000000000000000000000000000000000ffffffff)))""",
            sources=src(VERIFIED_OPS, "denseJumpInBoundsRef", "denseJumpInBoundsFast"),
        )
    )

# ---------------------------------------------------------------------------
# Fusions: symbolic stack execution, EVM sequence vs fused handler
# ---------------------------------------------------------------------------


class EvmStack:
    """Yellow Paper stack semantics. Index -1 is mu_s[0] (top)."""

    def __init__(self, items: List[str]):
        self.items = list(items)

    def push(self, v: str) -> None:
        self.items.append(v)

    def binop(self, op: str) -> None:
        a = self.items.pop()  # mu_s[0]
        b = self.items.pop()  # mu_s[1]
        self.items.append(f"({op} {a} {b})")  # mu'_s[0] = mu_s[0] op mu_s[1]

    def iszero(self) -> None:
        a = self.items.pop()
        self.items.append(f"(ite (= {a} {w(0)}) {w(1)} {w(0)})")

    def dup(self, n: int) -> None:
        self.items.append(self.items[-n])

    def swap(self, n: int) -> None:
        self.items[-1], self.items[-1 - n] = self.items[-1 - n], self.items[-1]

    def jumpi(self) -> Tuple[str, str]:
        dest = self.items.pop()  # mu_s[0]
        cond = self.items.pop()  # mu_s[1]
        return f"(not (= {cond} {w(0)}))", dest


class ZigStack:
    """src/stack/stack.zig unsafe API (index -1 is top)."""

    def __init__(self, items: List[str]):
        self.items = list(items)

    def pop_unsafe(self) -> str:
        return self.items.pop()

    def peek_unsafe(self) -> str:
        return self.items[-1]

    def set_top_unsafe(self, v: str) -> None:
        self.items[-1] = v

    def push_unsafe(self, v: str) -> None:
        self.items.append(v)

    def dup_n_unsafe(self, n: int) -> None:
        self.items.append(self.items[-n])  # stack_ptr[n - 1] is nth from top


def stack_vars(depth: int) -> Tuple[str, List[str]]:
    names = [f"s{i}" for i in range(depth)]  # s{depth-1} is the top
    return "\n".join(f"(declare-const {n} Word)" for n in names), names


def stack_goal(evm: List[str], fused: List[str]) -> Tuple[str, str]:
    if len(evm) != len(fused):
        return "false", f"stack depth mismatch: EVM {len(evm)} vs fused {len(fused)}"
    return conj([f"(= {a} {b})" for a, b in zip(evm, fused)]), ""


def fusion_theorem(
    name: str,
    seq: str,
    min_depth: int,
    evm_run: Callable[[EvmStack, str], None],
    fused_run: Callable[[ZigStack, str], None],
    sources: List[SourceRef],
    notes: str = "",
) -> None:
    depth = min_depth + 2  # two untouched words below prove the rest of the stack is preserved
    decls, items = stack_vars(depth)
    decls = "(declare-const v Word) ; PUSH immediate, any 256-bit value (inline and pointer forms)\n" + decls
    e = EvmStack(items)
    evm_run(e, "v")
    f = ZigStack(items)
    fused_run(f, "v")
    goal, err = stack_goal(e.items, f.items)
    theorem(
        Theorem(
            name=name,
            claim=f"""For ALL 256-bit push values and ALL {depth}-word stacks (top {min_depth} consumed,
2 below preserved): executing `{seq}` under Yellow Paper semantics yields a stack
bit-for-bit equal to the fused handler's stack (same depth, every word equal).""",
            logic="QF_BV",
            decls=decls,
            hyps=[],
            goal=goal,
            sources=sources,
            notes=notes,
            structural_error=err,
        )
    )


PUSH_BINOP_FUSIONS = [
    # (name, opcode, SMT op, fused handler (inline, pointer), handler expression builder, file)
    ("fusion_push_add_equiv", "ADD", "bvadd", ("push_add_inline", "push_add_pointer"), lambda v, t: f"(bvadd {v} {t})", ARITH_SYN),
    ("fusion_push_sub_equiv", "SUB", "bvsub", ("push_sub_inline", "push_sub_pointer"), lambda v, t: f"(bvsub {v} {t})", ARITH_SYN),
    ("fusion_push_mul_equiv", "MUL", "bvmul", ("push_mul_inline", "push_mul_pointer"), lambda v, t: f"(bvmul {v} {t})", ARITH_SYN),
    ("fusion_push_and_equiv", "AND", "bvand", ("push_and_inline", "push_and_pointer"), lambda v, t: f"(bvand {t} {v})", BITWISE_SYN),
    ("fusion_push_or_equiv", "OR", "bvor", ("push_or_inline", "push_or_pointer"), lambda v, t: f"(bvor {t} {v})", BITWISE_SYN),
    ("fusion_push_xor_equiv", "XOR", "bvxor", ("push_xor_inline", "push_xor_pointer"), lambda v, t: f"(bvxor {t} {v})", BITWISE_SYN),
]

for _name, _op, _smt, _fns, _expr, _file in PUSH_BINOP_FUSIONS:

    def _evm(s: EvmStack, v: str, smt=_smt) -> None:
        s.push(v)
        s.binop(smt)

    def _fused(s: ZigStack, v: str, expr=_expr) -> None:
        top = s.peek_unsafe()
        s.set_top_unsafe(expr(v, top))

    fusion_theorem(
        _name,
        f"PUSH v; {_op}",
        1,
        _evm,
        _fused,
        src(_file, *_fns),
        notes="""Stack depth >= 1 is a precondition established by the basic-block stack guard
(PUSH then a binary op requires 1 incoming item); see block_stack_guard_equiv.""",
    )


def _evm_push_add_dup1(s: EvmStack, v: str) -> None:
    s.push(v)
    s.binop("bvadd")
    s.dup(1)


def _fused_push_add_dup1(s: ZigStack, v: str) -> None:
    s.push_unsafe(v)
    b = s.pop_unsafe()
    a = s.pop_unsafe()
    result = f"(bvadd {a} {b})"
    s.push_unsafe(result)
    s.push_unsafe(result)


fusion_theorem(
    "fusion_push_add_dup1_equiv", "PUSH v; ADD; DUP1", 1, _evm_push_add_dup1, _fused_push_add_dup1, src(ADV_SYN, "push_add_dup1", "push_add_dup1_inline", "push_add_dup1_pointer")
)


# ISZERO; PUSH target; JUMPI  -> ISZERO_JUMPI
_decls, _items = stack_vars(3)
_e = EvmStack(_items)
_e.iszero()
_e.push("target")
_evm_taken, _evm_dest = _e.jumpi()
_f = ZigStack(_items)
_value = _f.pop_unsafe()
_fused_taken = f"(= {_value} {w(0)})"
_sgoal, _serr = stack_goal(_e.items, _f.items)
theorem(
    Theorem(
        name="fusion_iszero_push_jumpi_equiv",
        claim="""For ALL 256-bit jump targets, ALL 3-word stacks, and EVERY jumpdest table:
`ISZERO; PUSH target; JUMPI` (Yellow Paper) and the fused ISZERO_JUMPI handler agree on
  (a) the remaining stack (bit-for-bit, same depth),
  (b) the control outcome: fall through / jump / exceptional halt (InvalidJump),
  (c) the jump destination when the jump is taken.""",
        logic="QF_UFBV",
        decls=f"""(declare-const target Word)
{_decls}
; PcType = u16 (default max_bytecode_size 24576 <= 65535, enforced by FrameConfig.validate).
(define-fun MAX_PC () Word {w(0xFFFF)})
; jump_table.findJumpTarget(dest_pc: PcType) != null: uninterpreted, any jumpdest table.
(declare-fun isJumpdest ((_ BitVec 16)) Bool)
; Outcome encoding: 0 = fall through, 1 = jump, 2 = exceptional halt (InvalidJump)
(define-fun FALL () (_ BitVec 2) #b00)
(define-fun JUMP () (_ BitVec 2) #b01)
(define-fun HALT () (_ BitVec 2) #b10)
; Yellow Paper JUMPI validity: dest in D(code). Code length <= maxInt(PcType), so a valid
; dest is <= MAX_PC and is a jumpdest of the truncated PC.
(define-fun evmValidDest ((d Word)) Bool
  (and (bvule d MAX_PC) (isJumpdest ((_ extract 15 0) d))))
(define-fun evmOutcome () (_ BitVec 2)
  (ite {_evm_taken} (ite (evmValidDest {_evm_dest}) JUMP HALT) FALL))
; handlers_advanced_synthetic.zig iszero_jumpi
(define-fun fusedOutcome () (_ BitVec 2)
  (ite {_fused_taken}
       (ite (bvugt target MAX_PC) HALT
         (ite (isJumpdest ((_ extract 15 0) target)) JUMP HALT))
       FALL))""",
        hyps=[],
        goal=f"""(and (= evmOutcome fusedOutcome)
     (=> (= evmOutcome JUMP) (= {_evm_dest} target))
     {_sgoal})""",
        sources=src(ADV_SYN, "iszero_jumpi"),
        structural_error=_serr,
    )
)

# Constant folding: PUSH1 a; PUSH1 b; {ADD,SUB,MUL} -> PUSH folded_value
_decls, _items = stack_vars(2)
_fold_goals = []
_fold_err = ""
for _op_smt, _fold in [
    ("bvadd", "(bvadd v1 v2)"),  # folded_value = value1 +% value2
    ("bvsub", "(bvsub v2 v1)"),  # folded_value = value2 -% value1
    ("bvmul", "(bvmul v1 v2)"),  # folded_value = value1 *% value2
]:
    _e = EvmStack(_items)
    _e.push("v1")
    _e.push("v2")
    _e.binop(_op_smt)
    _f = ZigStack(_items)
    _f.push_unsafe(_fold)
    _g, _err = stack_goal(_e.items, _f.items)
    _fold_goals.append(_g)
    _fold_err = _fold_err or _err
theorem(
    Theorem(
        name="fusion_const_fold_add_sub_mul_equiv",
        claim="""For ALL PUSH1 immediates (value1, value2) and ALL 2-word stacks:
`PUSH1 value1; PUSH1 value2; OP` (Yellow Paper) leaves exactly the stack produced by
pushing bytecode_analyze.zig's folded_value, for OP in {ADD, SUB, MUL}.""",
        logic="QF_BV",
        decls=f"""(declare-const value1 (_ BitVec 8))
(declare-const value2 (_ BitVec 8))
(define-fun v1 () Word ((_ zero_extend 248) value1))
(define-fun v2 () Word ((_ zero_extend 248) value2))
{_decls}""",
        hyps=[],
        goal=conj(_fold_goals),
        sources=src(BYTECODE_ANALYZE, "check"),
        notes="""Folder transcription: ADD -> value1 +% value2; SUB -> value2 -% value1;
MUL -> value1 *% value2 (bytecode_analyze.zig checkConstantFoldingPatternWithFusion).""",
        structural_error=_fold_err,
    )
)

# ---------------------------------------------------------------------------
# Solver driver
# ---------------------------------------------------------------------------


@dataclasses.dataclass
class Job:
    theorem: str
    kind: str  # "proof" or "vacuity"
    path: Path
    expected: str
    timeout: int = 0


@dataclasses.dataclass
class Outcome:
    job: Job
    solver: str
    answer: str
    seconds: float
    detail: str = ""


def solver_cmd(solver: str, path: Path, timeout: int) -> List[str]:
    if solver == "bitwuzla":
        return ["bitwuzla", f"--time-limit={timeout * 1000}", str(path)]
    return ["z3", f"-T:{timeout}", str(path)]


def run_solver(solver: str, job: Job, timeout: int) -> Outcome:
    t0 = time.monotonic()
    try:
        proc = subprocess.run(
            solver_cmd(solver, job.path, timeout), capture_output=True, text=True, timeout=timeout + 5
        )
    except subprocess.TimeoutExpired:
        return Outcome(job, solver, "timeout", time.monotonic() - t0)
    dt = time.monotonic() - t0
    lines = [l.strip() for l in proc.stdout.splitlines() if l.strip()]
    answer = lines[0] if lines else "error"
    if answer not in ("sat", "unsat", "unknown"):
        return Outcome(job, solver, "error", dt, (proc.stdout + proc.stderr).strip()[:2000])
    detail = ""
    if answer != job.expected and answer == "sat":
        detail = counterexample(solver, job.path, timeout)
    return Outcome(job, solver, answer, dt, detail)


def counterexample(solver: str, path: Path, timeout: int) -> str:
    text = path.read_text().replace("(check-sat)\n(exit)", "(check-sat)\n(get-model)\n(exit)")
    text = text.replace("(set-logic", "(set-option :produce-models true)\n(set-logic", 1)
    cex = path.with_suffix(".cex.smt2")
    cex.write_text(text)
    try:
        proc = subprocess.run(solver_cmd(solver, cex, timeout), capture_output=True, text=True, timeout=timeout + 5)
        return proc.stdout.strip()[:4000]
    except subprocess.TimeoutExpired:
        return "(counterexample extraction timed out)"
    finally:
        cex.unlink()


# ---------------------------------------------------------------------------
# Opcode table audit
# ---------------------------------------------------------------------------

# Cancun + Osaka (EIP-7939 CLZ) opcode specification.
# (name, inputs delta, outputs alpha, constant gas charged before dynamic gas)
# Constant gas follows ethereum/execution-specs (osaka) `charge_gas` constants; warm-access
# opcodes (EIP-2929) list the warm cost, with the cold surcharge dynamic.
SPEC: Dict[int, Tuple[str, int, int, int]] = {
    0x00: ("STOP", 0, 0, 0),
    0x01: ("ADD", 2, 1, 3), 0x02: ("MUL", 2, 1, 5), 0x03: ("SUB", 2, 1, 3), 0x04: ("DIV", 2, 1, 5),
    0x05: ("SDIV", 2, 1, 5), 0x06: ("MOD", 2, 1, 5), 0x07: ("SMOD", 2, 1, 5), 0x08: ("ADDMOD", 3, 1, 8),
    0x09: ("MULMOD", 3, 1, 8), 0x0A: ("EXP", 2, 1, 10), 0x0B: ("SIGNEXTEND", 2, 1, 5),
    0x10: ("LT", 2, 1, 3), 0x11: ("GT", 2, 1, 3), 0x12: ("SLT", 2, 1, 3), 0x13: ("SGT", 2, 1, 3),
    0x14: ("EQ", 2, 1, 3), 0x15: ("ISZERO", 1, 1, 3), 0x16: ("AND", 2, 1, 3), 0x17: ("OR", 2, 1, 3),
    0x18: ("XOR", 2, 1, 3), 0x19: ("NOT", 1, 1, 3), 0x1A: ("BYTE", 2, 1, 3), 0x1B: ("SHL", 2, 1, 3),
    0x1C: ("SHR", 2, 1, 3), 0x1D: ("SAR", 2, 1, 3), 0x1E: ("CLZ", 1, 1, 5),
    0x20: ("KECCAK256", 2, 1, 30),
    0x30: ("ADDRESS", 0, 1, 2), 0x31: ("BALANCE", 1, 1, 100), 0x32: ("ORIGIN", 0, 1, 2),
    0x33: ("CALLER", 0, 1, 2), 0x34: ("CALLVALUE", 0, 1, 2), 0x35: ("CALLDATALOAD", 1, 1, 3),
    0x36: ("CALLDATASIZE", 0, 1, 2), 0x37: ("CALLDATACOPY", 3, 0, 3), 0x38: ("CODESIZE", 0, 1, 2),
    0x39: ("CODECOPY", 3, 0, 3), 0x3A: ("GASPRICE", 0, 1, 2), 0x3B: ("EXTCODESIZE", 1, 1, 100),
    0x3C: ("EXTCODECOPY", 4, 0, 100), 0x3D: ("RETURNDATASIZE", 0, 1, 2), 0x3E: ("RETURNDATACOPY", 3, 0, 3),
    0x3F: ("EXTCODEHASH", 1, 1, 100),
    0x40: ("BLOCKHASH", 1, 1, 20), 0x41: ("COINBASE", 0, 1, 2), 0x42: ("TIMESTAMP", 0, 1, 2),
    0x43: ("NUMBER", 0, 1, 2), 0x44: ("PREVRANDAO", 0, 1, 2), 0x45: ("GASLIMIT", 0, 1, 2),
    0x46: ("CHAINID", 0, 1, 2), 0x47: ("SELFBALANCE", 0, 1, 5), 0x48: ("BASEFEE", 0, 1, 2),
    0x49: ("BLOBHASH", 1, 1, 3), 0x4A: ("BLOBBASEFEE", 0, 1, 2),
    0x50: ("POP", 1, 0, 2), 0x51: ("MLOAD", 1, 1, 3), 0x52: ("MSTORE", 2, 0, 3), 0x53: ("MSTORE8", 2, 0, 3),
    0x54: ("SLOAD", 1, 1, 100), 0x55: ("SSTORE", 2, 0, 0), 0x56: ("JUMP", 1, 0, 8), 0x57: ("JUMPI", 2, 0, 10),
    0x58: ("PC", 0, 1, 2), 0x59: ("MSIZE", 0, 1, 2), 0x5A: ("GAS", 0, 1, 2), 0x5B: ("JUMPDEST", 0, 0, 1),
    0x5C: ("TLOAD", 1, 1, 100), 0x5D: ("TSTORE", 2, 0, 100), 0x5E: ("MCOPY", 3, 0, 3), 0x5F: ("PUSH0", 0, 1, 2),
    0xF0: ("CREATE", 3, 1, 32000), 0xF1: ("CALL", 7, 1, 100), 0xF2: ("CALLCODE", 7, 1, 100),
    0xF3: ("RETURN", 2, 0, 0), 0xF4: ("DELEGATECALL", 6, 1, 100), 0xF5: ("CREATE2", 4, 1, 32000),
    0xFA: ("STATICCALL", 6, 1, 100), 0xFD: ("REVERT", 2, 0, 0), 0xFE: ("INVALID", 0, 0, 0),
    0xFF: ("SELFDESTRUCT", 1, 0, 5000),
}
for _i in range(32):
    SPEC[0x60 + _i] = (f"PUSH{_i + 1}", 0, 1, 3)
for _i in range(16):
    SPEC[0x80 + _i] = (f"DUP{_i + 1}", _i + 1, _i + 2, 3)
    SPEC[0x90 + _i] = (f"SWAP{_i + 1}", _i + 2, _i + 2, 3)
for _i in range(5):
    SPEC[0xA0 + _i] = (f"LOG{_i}", _i + 2, 0, 375 + 375 * _i)

# Documented Guillotine conventions where the table's static gas intentionally differs from
# the execution-specs constant. Each is reported as NOTE, never silently accepted.
GAS_CONVENTIONS: Dict[int, Tuple[int, str]] = {
    0xF0: (0, "CreateGas 32000 is charged with EIP-3860 initcode word gas in Evm.executeCreate"),
    0xF5: (0, "CreateGas 32000 is charged with EIP-1014/3860 word gas in Evm.executeCreate2"),
}

# Opcodes the frame maps to the `invalid` handler although the table carries metadata.
WITHDRAWN = {0xF6: "AUTH (EIP-3074, withdrawn)", 0xF7: "AUTHCALL (EIP-3074, withdrawn)"}


class Expr:
    """Tiny integer expression evaluator for the opcode table (ints, names, + - * only)."""

    def __init__(self, names: Dict[str, int]):
        self.names = names

    def eval(self, text: str) -> int:
        text = re.sub(r"@as\(\s*u\d+\s*,\s*", "(", text)
        text = re.sub(r"@intFromEnum\(\s*Opcode\.(\w+)\s*\)", r"OPCODE_\1", text)
        text = text.replace("GasConstants.", "GC_")
        tree = ast.parse(text.strip(), mode="eval")
        return self._ev(tree.body)

    def _ev(self, node: ast.AST) -> int:
        if isinstance(node, ast.Constant) and isinstance(node.value, int):
            return node.value
        if isinstance(node, ast.Name):
            if node.id not in self.names:
                raise KeyError(f"unknown name `{node.id}`")
            return self.names[node.id]
        if isinstance(node, ast.BinOp) and type(node.op) in (ast.Add, ast.Sub, ast.Mult):
            l, r = self._ev(node.left), self._ev(node.right)
            return l + r if isinstance(node.op, ast.Add) else l - r if isinstance(node.op, ast.Sub) else l * r
        raise ValueError(f"unsupported expression node {ast.dump(node)}")


def parse_opcode_table() -> Tuple[Dict[int, Tuple[int, int, int, int]], List[str]]:
    """Return {opcode: (gas, inputs, outputs, line)} from opcode_data.zig, plus parse errors."""
    names: Dict[str, int] = {}
    for m in re.finditer(r"pub const (\w+)\s*:\s*u\d+\s*=\s*(\d+)\s*;", read_source(GAS_CONSTANTS)):
        names["GC_" + m.group(1)] = int(m.group(2))
    enum_text = read_source(OPCODE_ENUM)
    enum_body = enum_text[enum_text.index("pub const Opcode = enum(u8) {") :]
    enum_body = enum_body[: enum_body.index("\n};")]
    for m in re.finditer(r"^\s*(\w+)\s*=\s*0x([0-9a-fA-F]+)\s*,", enum_body, re.M):
        names["OPCODE_" + m.group(1)] = int(m.group(2), 16)
    ev = Expr(names)

    text = read_source(OPCODE_DATA)
    body = text[text.index("pub const OPCODE_INFO") :]
    body = body[: body.index("break :blk info;")]
    base_line = text[: text.index("pub const OPCODE_INFO")].count("\n") + 1
    table: Dict[int, Tuple[int, int, int, int]] = {}
    errors: List[str] = []
    assign = re.compile(
        r"info\[(?P<idx>[^\]]+)\]\s*=\s*\.\{\s*\.gas_cost\s*=\s*(?P<gas>[^,]+?)\s*,\s*"
        r"\.stack_inputs\s*=\s*(?P<inp>.+?)\s*,\s*\.stack_outputs\s*=\s*(?P<out>[^}]+?)\s*\}\s*;"
    )
    loop_re = re.compile(r"while\s*\(\s*i\s*(<=|<)\s*(\d+)\s*\)")
    loop: Optional[range] = None
    lines = body.splitlines()
    for n, raw in enumerate(lines):
        lm = loop_re.search(raw)
        if lm:
            hi = int(lm.group(2)) + (1 if lm.group(1) == "<=" else 0)
            loop = range(0, hi)
            continue
        m = assign.search(raw)
        if not m:
            if "info[" in raw and "=" in raw and not raw.strip().startswith("var info"):
                errors.append(f"{OPCODE_DATA}:{base_line + n}: unparsed table line: {raw.strip()}")
            continue
        uses_i = re.search(r"\bi\b", m.group("idx")) is not None
        iters = loop if uses_i and loop is not None else [None]
        for i in iters:
            local = dict(names)
            if i is not None:
                local["i"] = i
            ev.names = local
            try:
                idx = ev.eval(m.group("idx"))
                gas = ev.eval(m.group("gas"))
                inp = ev.eval(m.group("inp"))
                out = ev.eval(m.group("out"))
            except (KeyError, ValueError, SyntaxError) as exc:
                errors.append(f"{OPCODE_DATA}:{base_line + n}: {exc}")
                continue
            if idx in table:
                errors.append(f"{OPCODE_DATA}:{base_line + n}: opcode 0x{idx:02x} assigned twice")
            table[idx] = (gas, inp, out, base_line + n)
        if uses_i and "}" in "".join(lines[n + 1 : n + 2]):
            loop = None
    return table, errors


def audit_opcode_table() -> Tuple[List[str], List[str], List[str]]:
    """Return (errors, warnings, notes)."""
    table, errors = parse_opcode_table()
    warnings: List[str] = []
    notes: List[str] = []
    data = read_source(OPCODE_DATA)
    dup_rule = "return (opcode - 0x80) + 1;" in data
    swap_rule = "return (opcode - 0x90) + 2;" in data
    if not dup_rule or not swap_rule:
        errors.append(f"{OPCODE_DATA}: getMinStackRequired DUP/SWAP depth rules not found")

    for op in range(256):
        entry = table.get(op)
        gas, inp, out, line = entry if entry else (0, 0, 0, 0)
        loc = f"{OPCODE_DATA}:{line}" if line else OPCODE_DATA
        for field, val in (("gas_cost", gas), ("stack_inputs", inp), ("stack_outputs", out)):
            limit = 0xFFFF if field == "gas_cost" else 0xF
            if not 0 <= val <= limit:
                errors.append(f"{loc}: 0x{op:02x} {field} = {val} does not fit its field type")
        if op not in SPEC:
            if op in WITHDRAWN:
                if entry and (gas, inp, out) != (0, 0, 0):
                    warnings.append(
                        f"{loc}: 0x{op:02x} {WITHDRAWN[op]} is undefined in Cancun/Osaka but the table "
                        f"carries gas={gas} in={inp} out={out}. frame_handlers.zig maps it to `invalid`, so "
                        "execution still halts exceptionally with all gas consumed; static block analysis "
                        "may report StackUnderflow/OutOfGas instead of InvalidOpcode. Expected (0, 0, 0)."
                    )
                continue
            if entry and (gas, inp, out) != (0, 0, 0):
                errors.append(f"{loc}: 0x{op:02x} is undefined in Cancun/Osaka but has gas={gas} in={inp} out={out}")
            continue
        name, delta, alpha, spec_gas = SPEC[op]
        if not entry:
            errors.append(f"{OPCODE_DATA}: 0x{op:02x} {name} is defined in the spec but missing from OPCODE_INFO")
            continue
        if 0x80 <= op <= 0x9F:
            # Table stores DUP/SWAP as net effect; required depth comes from getMinStackRequired.
            depth = (op - 0x80 + 1) if op <= 0x8F else (op - 0x90 + 2)
            if out - inp != alpha - delta:
                errors.append(f"{loc}: 0x{op:02x} {name} net stack effect {out - inp} != spec {alpha - delta}")
            if depth != delta:
                errors.append(f"{loc}: 0x{op:02x} {name} required depth {depth} != spec {delta}")
        elif (inp, out) != (delta, alpha):
            errors.append(f"{loc}: 0x{op:02x} {name} stack (in={inp}, out={out}) != spec (in={delta}, out={alpha})")
        expected_gas = spec_gas
        if op in GAS_CONVENTIONS:
            expected_gas, why = GAS_CONVENTIONS[op]
            notes.append(f"{loc}: 0x{op:02x} {name} static gas {gas} (spec constant {spec_gas}): {why}")
        if gas != expected_gas:
            errors.append(f"{loc}: 0x{op:02x} {name} gas_cost {gas} != spec {expected_gas}")
    notes.append(
        f"{OPCODE_DATA}: DUPn/SWAPn are stored as net effect (0,1)/(0,0); depth n / n+1 verified via getMinStackRequired"
    )
    notes.append(f"audited {len(table)} table entries against {len(SPEC)} Cancun/Osaka opcodes")
    return errors, warnings, notes


# ---------------------------------------------------------------------------
# Model pins (drift guard)
# ---------------------------------------------------------------------------


def all_sources() -> List[SourceRef]:
    seen: Dict[Tuple[str, str], SourceRef] = {}
    for t in THEOREMS:
        for ref in t.sources:
            seen[(ref.path, ref.fn)] = ref
    return sorted(seen.values(), key=lambda r: (r.path, r.fn))


def check_pins(update: bool) -> List[str]:
    current = {f"{r.path}::{r.fn}": fn_hash(r) for r in all_sources()}
    if update:
        PINS_FILE.write_text(json.dumps(current, indent=2, sort_keys=True) + "\n")
        return []
    # Fail closed: a missing pin file must never be regenerated silently, or
    # unreviewed source drift would pass as "proved".
    if not PINS_FILE.exists():
        return [f"{PINS_FILE.relative_to(REPO)} is missing; review the SMT models and run --update-pins"]
    pinned = json.loads(PINS_FILE.read_text())
    errs = []
    for key, h in current.items():
        if key not in pinned:
            errs.append(f"{key}: no pin; review the model and run --update-pins")
        elif pinned[key] != h:
            errs.append(f"{key}: source changed since the SMT model was reviewed (pin {pinned[key]}, now {h})")
    return errs


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--solver", choices=["auto", "bitwuzla", "z3", "both"], default="auto")
    ap.add_argument("--only", default="", help="regex; run only matching theorems")
    ap.add_argument("--timeout", type=int, default=60, help="per-query solver timeout in seconds")
    ap.add_argument("--jobs", type=int, default=0, help="parallel solver processes (default: CPU count)")
    ap.add_argument("--no-vacuity", action="store_true", help="skip hypothesis consistency checks")
    ap.add_argument("--strict-audit", action="store_true", help="treat opcode audit warnings as failures")
    ap.add_argument("--update-pins", action="store_true", help="re-pin modeled Zig sources after review")
    ap.add_argument("--emit-only", action="store_true", help="write .smt2 files without solving")
    ap.add_argument("--list", action="store_true", help="list theorems and exit")
    args = ap.parse_args()

    if args.list:
        for t in THEOREMS:
            print(f"{t.name:44s} {t.logic}")
        print("opcode_table_audit")
        return 0

    t_start = time.monotonic()
    failures: List[str] = []

    fallback: Optional[str] = None
    if args.solver == "auto":
        solvers = ["bitwuzla"] if shutil.which("bitwuzla") else ["z3"] if shutil.which("z3") else []
        # Neither solver dominates (Bitwuzla: memory gas in minutes; Z3: SDIV/SMOD
        # in seconds). Retry only non-definitive answers with the other solver.
        if solvers == ["bitwuzla"] and shutil.which("z3"):
            fallback = "z3"
    elif args.solver == "both":
        solvers = ["bitwuzla", "z3"]
    else:
        solvers = [args.solver]
    missing = [s for s in solvers if not shutil.which(s)]
    if not solvers or missing:
        print(f"error: solver not found on PATH: {missing or 'bitwuzla/z3'}", file=sys.stderr)
        return 2

    selected = [t for t in THEOREMS if re.search(args.only, t.name)]
    PROOFS.mkdir(exist_ok=True)
    (PROOFS / "vacuity").mkdir(exist_ok=True)
    for stale in list(PROOFS.glob("*.smt2")) + list((PROOFS / "vacuity").glob("*.smt2")):
        stale.unlink()

    jobs: List[Job] = []
    for t in selected:
        if t.structural_error:
            failures.append(f"{t.name}: {t.structural_error}")
        p = PROOFS / f"{t.name}.smt2"
        p.write_text(t.render(vacuity=False))
        jobs.append(Job(t.name, "proof", p, "unsat", t.timeout))
        if t.hyps and not args.no_vacuity:
            v = PROOFS / "vacuity" / f"{t.name}.smt2"
            v.write_text(t.render(vacuity=True))
            jobs.append(Job(t.name, "vacuity", v, "sat", t.timeout))

    pin_errors = check_pins(args.update_pins)
    failures.extend(f"model pin: {e}" for e in pin_errors)

    print(f"Guillotine SMT suite: {len(selected)} theorems, {len(jobs)} queries, solver(s): {', '.join(solvers)}")
    print(f"proof files: {PROOFS.relative_to(REPO)}/")
    if args.emit_only:
        return 1 if failures else 0

    outcomes: List[Outcome] = []
    workers = args.jobs or max(2, (os_cpu() or 4))
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futs = [pool.submit(run_solver, s, j, max(args.timeout, j.timeout)) for j in jobs for s in solvers]
        for fut in futs:
            outcomes.append(fut.result())
        if fallback:
            retry = [i for i, o in enumerate(outcomes) if o.answer not in ("sat", "unsat")]
            retried = [pool.submit(run_solver, fallback, outcomes[i].job, max(args.timeout, outcomes[i].job.timeout)) for i in retry]
            for i, fut in zip(retry, retried):
                outcomes[i] = fut.result()

    by_theorem: Dict[str, List[Outcome]] = {}
    for o in outcomes:
        by_theorem.setdefault(o.job.theorem, []).append(o)

    print()
    print(f"{'theorem':44s} {'result':8s} {'vacuity':8s} {'time':>7s}")
    print("-" * 70)
    for t in selected:
        os_ = by_theorem.get(t.name, [])
        proof = [o for o in os_ if o.job.kind == "proof"]
        vac = [o for o in os_ if o.job.kind == "vacuity"]
        ok_proof = all(o.answer == "unsat" for o in proof) and not t.structural_error
        ok_vac = all(o.answer == "sat" for o in vac)
        res = "unsat" if ok_proof else "/".join(sorted({o.answer for o in proof})) or "skipped"
        if t.structural_error:
            res = "STRUCT"
        vres = "n/a" if not vac else ("sat" if ok_vac else "/".join(sorted({o.answer for o in vac})))
        secs = max((o.seconds for o in os_), default=0.0)
        mark = "PASS" if ok_proof and ok_vac else "FAIL"
        print(f"{t.name:44s} {res:8s} {vres:8s} {secs:6.2f}s  {mark}")
        for o in proof:
            if o.answer != "unsat":
                failures.append(f"{t.name} [{o.solver}]: expected unsat, got {o.answer}")
                if o.detail:
                    failures.append("  counterexample / output:\n    " + o.detail.replace("\n", "\n    "))
        for o in vac:
            if o.answer != "sat":
                failures.append(f"{t.name} vacuity [{o.solver}]: hypotheses gave {o.answer}, expected sat")
                if o.detail:
                    failures.append("  output:\n    " + o.detail.replace("\n", "\n    "))

    errors, warnings, notes = audit_opcode_table()
    audit_ok = not errors and not (args.strict_audit and warnings)
    print(f"{'opcode_table_audit':44s} {'errors=' + str(len(errors)):8s} {'warn=' + str(len(warnings)):8s} {'':>7s}  {'PASS' if audit_ok else 'FAIL'}")
    for e in errors:
        print(f"  ERROR {e}")
        failures.append(f"opcode_table_audit: {e}")
    for wmsg in warnings:
        print(f"  WARN  {wmsg}")
        if args.strict_audit:
            failures.append(f"opcode_table_audit (strict): {wmsg}")
    for nmsg in notes:
        print(f"  NOTE  {nmsg}")

    total = time.monotonic() - t_start
    print("-" * 70)
    if failures:
        print(f"FAILED ({len(failures)} problem(s)) in {total:.2f}s")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(f"ALL {len(selected)} THEOREMS PROVED (unsat) and opcode audit clean in {total:.2f}s")
    return 0


def os_cpu() -> Optional[int]:
    import os

    return os.cpu_count()


if __name__ == "__main__":
    sys.exit(main())
