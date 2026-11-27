/-
  GuillotineZean.ScalarOps.Proofs

  Direct Zig 0.17.1 AIR -> Lean 4 formal proofs for Guillotine's scalar hot-path
  kernels in `src/core/verified_ops.zig`, captured via Zean (`zean --check`).

  Every theorem quantifies directly over the executable Lean AIR definitions
  emitted by Zean (`GuillotineZean.ScalarOps.Generated`), each backed by a
  kernel-checked `CapturedScalar.decode` correspondence theorem, and proves
  exact equivalence to `GuillotineVerify` specifications.
-/
import GuillotineZean.ScalarOps.Generated
import Compiler.ZigAir.BitwiseProofs
import GuillotineVerify.Memory
import GuillotineVerify.BasicBlock

namespace GuillotineZean.ScalarOps
open Compiler.ZigAir Compiler.ZigAir.Scalar

private def guardCode : GuillotineVerify.BasicBlock.StackGuard → Int
  | .ok => 0
  | .underflow => 1
  | .overflow => 2

private theorem valid_uint {w : Nat} {x : Int} (hlo : 0 ≤ x) (hhi : x < (2 : Int) ^ w) :
    (Value.int false w x).valid = true := by
  simp [Value.valid, Ty.contains, Ty.lower, Ty.upper, hlo, hhi]

private theorem hasType_of_valid {w : Nat} {x : Int} (hv : (Value.int false w x).valid = true) :
    (Value.int false w x).hasType (.int false w) = true := by
  simp only [Value.hasType, Value.type, hv, decide_true, Bool.and_self]

private theorem valid_bool (b : Bool) : (Value.bool b).valid = true := rfl
private theorem hasType_bool (b : Bool) : (Value.bool b).hasType .bool = true := rfl
private theorem valid_unit : Value.unit.valid = true := rfl
private theorem hasType_unit : Value.unit.hasType .unit = true := rfl

private theorem integer_unchecked_of_valid {w : Nat} {x : Int}
    (hv : (Value.int false w x).valid = true) :
    integer false w x .unchecked = .ok (.int false w x) := by
  simp only [Value.valid] at hv
  simp only [integer, hv, reduceCtorEq, ↓reduceIte]

private theorem integer_wrapping_uint {w : Nat} (x : Int) :
    integer false w x .wrapping = .ok (.int false w (x % (2 : Int) ^ w)) := by
  simp [integer, normalize]

private theorem ref_const_eval {v : Value} {env : Env} (hv : v.valid = true) :
    (Ref.constant v).eval env = .ok v := by
  simp only [Ref.eval, hv, ↓reduceIte]

private theorem ref_local_eval {id : Nat} {v : Value} {env : Env}
    (hl : env id = some v) (hv : v.valid = true) :
    (Ref.local id).eval env = .ok v := by
  simp only [Ref.eval, hl, hv, ↓reduceIte]

private theorem arg_eval {i : Nat} {args : List Value} {env : Env} {v : Value}
    (ha : args[i]? = some v) (hv : v.valid = true) :
    (Prim.argument i).eval args env = .ok v := by
  simp only [Prim.eval, ha, hv, ↓reduceIte]

private theorem arith_eval {op : Arithmetic} {mode : Overflow} {left right : Ref}
    {args : List Value} {env : Env} {s : Bool} {w : Nat} {x y : Int} {v : Value}
    (hl : left.eval env = .ok (.int s w x))
    (hr : right.eval env = .ok (.int s w y))
    (hi : integer s w (op.eval x y) mode = .ok v) :
    (Prim.arithmetic op mode left right).eval args env = .ok v := by
  simp [Prim.eval, hl, hr, hi, bind, Except.bind]

private theorem cmp_eval {op : Comparison} {left right : Ref}
    {args : List Value} {env : Env} {s : Bool} {w : Nat} {x y : Int} {b : Bool}
    (hl : left.eval env = .ok (.int s w x))
    (hr : right.eval env = .ok (.int s w y))
    (hb : op.eval x y = b) :
    (Prim.comparison op left right).eval args env = .ok (.bool b) := by
  simp [Prim.eval, hl, hr, hb, bind, Except.bind]

private theorem cast_unchecked_eval {operand : Ref} {args : List Value} {env : Env}
    {s t : Bool} {n m : Nat} {x : Int} {v : Value}
    (ho : operand.eval env = .ok (.int s n x))
    (hi : integer t m x .unchecked = .ok v) :
    (Prim.cast .unchecked (.int t m) operand).eval args env = .ok v := by
  simp [Prim.eval, ho, hi, bind, Except.bind]

private theorem eval_bind_ok {id : Nat} {ty : Ty} {prim : Prim} {next : Code}
    {args : List Value} {env : Env} {v : Value}
    (hp : prim.eval args env = .ok v) (ht : v.hasType ty = true) :
    Control.Code.eval controlSemantics (.bind id ty prim next) args env () =
      Control.Code.eval controlSemantics next args (Control.Env.set env id v) () := by
  simp [Control.Code.eval, controlSemantics, hp, ht]

private theorem eval_ret_ok {ref : Ref} {args : List Value} {env : Env} {v : Value}
    (hr : ref.eval env = .ok v) :
    Control.Code.eval controlSemantics (.ret ref) args env () = .returned v () := by
  simp [Control.Code.eval, controlSemantics, hr]

private theorem eval_jump_ok {target : Nat} {ref : Ref} {args : List Value} {env : Env} {v : Value}
    (hr : ref.eval env = .ok v) :
    Control.Code.eval controlSemantics (.jump target ref) args env () = .jumped target v env () := by
  simp [Control.Code.eval, controlSemantics, hr]

private theorem eval_branch_true {cond : Ref} {t f : Code} {args : List Value} {env : Env}
    (hc : cond.eval env = .ok (.bool true)) :
    Control.Code.eval controlSemantics (.branch cond t f) args env () =
      Control.Code.eval controlSemantics t args env () := by
  simp [Control.Code.eval, controlSemantics, hc]

private theorem eval_branch_false {cond : Ref} {t f : Code} {args : List Value} {env : Env}
    (hc : cond.eval env = .ok (.bool false)) :
    Control.Code.eval controlSemantics (.branch cond t f) args env () =
      Control.Code.eval controlSemantics f args env () := by
  simp [Control.Code.eval, controlSemantics, hc]

private theorem eval_block_jump_hit {label : Nat} {ty : Ty} {body next : Code}
    {args : List Value} {env env' : Env} {v : Value}
    (hb : Control.Code.eval controlSemantics body args env () = .jumped label v env' ())
    (ht : v.hasType ty = true) :
    Control.Code.eval controlSemantics (.block label ty body next) args env () =
      Control.Code.eval controlSemantics next args (Control.Env.set env' label v) () := by
  rw [Control.Code.eval, hb]
  simp [controlSemantics, ht]

private theorem eval_block_jump_miss {label target : Nat} {ty : Ty} {body next : Code}
    {args : List Value} {env env' : Env} {v : Value}
    (hb : Control.Code.eval controlSemantics body args env () = .jumped target v env' ())
    (hne : target ≠ label) :
    Control.Code.eval controlSemantics (.block label ty body next) args env () =
      .jumped target v env' () := by
  rw [Control.Code.eval, hb]
  simp [hne]

private theorem run_of_eval_one {p : Program} {t rt : Ty} {v r : Value}
    (hp : p.parameters = [t]) (hrt : p.returnType = rt) (hv : v.hasType t = true)
    (he : Control.Code.eval controlSemantics p.body [v] (fun _ => none) () = .returned r ())
    (hr : r.hasType rt = true) :
    p.run [v] = .ok r := by
  simp [Program.run, Code.eval, Outcome.ofControl, hp, hrt, hv, he, hr]

private theorem run_of_eval_three {p : Program} {t0 t1 t2 rt : Ty} {v0 v1 v2 r : Value}
    (hp : p.parameters = [t0, t1, t2]) (hrt : p.returnType = rt)
    (h0 : v0.hasType t0 = true) (h1 : v1.hasType t1 = true) (h2 : v2.hasType t2 = true)
    (he : Control.Code.eval controlSemantics p.body [v0, v1, v2] (fun _ => none) () = .returned r ())
    (hr : r.hasType rt = true) :
    p.run [v0, v1, v2] = .ok r := by
  simp [Program.run, Code.eval, Outcome.ofControl, hp, hrt, h0, h1, h2, he, hr]

private theorem env_set_self (env : Control.Env Value) (id : Nat) (v : Value) :
    (Control.Env.set env id v) id = some v := by
  simp only [Control.Env.set, ↓reduceIte]

private theorem env_set_ne (env : Control.Env Value) (id q : Nat) (v : Value) (hne : q ≠ id) :
    (Control.Env.set env id v) q = env q :=
  Control.Env.set_ne env id q v hne

/-- Direct Zig AIR proof: `verified_ops.alignUp32` never overflows for `n ≤ 0xFFFFFF`
    and returns the exact Yellow Paper 32-byte aligned size `ceilWords(n) * 32`. -/
theorem align_up_32_correct (n : BitVec 32) (hn : n.toNat ≤ 0xFFFFFF) :
    Generated.fn_align_up_32.run [.int false 32 n.toNat] =
      .ok (.int false 32 (GuillotineVerify.Memory.ceilWords n.toNat * 32)) := by
  have hlt := n.isLt
  have hadd : n.toNat + 31 < 2 ^ 32 := by omega
  have hspec := GuillotineVerify.Memory.alignUp32_eq_ceil_mult32 n hn
  have hmask : ((n.toNat + 31) &&& 4294967264) =
      GuillotineVerify.Memory.ceilWords n.toNat * 32 := by
    rw [← hspec]
    have hbv : (GuillotineVerify.Memory.alignUp32 n).toNat =
        ((n.toNat + 31) % 2 ^ 32) &&& (4294967264 : Nat) := by
      unfold GuillotineVerify.Memory.alignUp32
      rw [BitVec.toNat_and, BitVec.toNat_add]
      rfl
    rw [hbv, Nat.mod_eq_of_lt hadd]
  have h_out : GuillotineVerify.Memory.ceilWords n.toNat * 32 < 2 ^ 32 := by
    rw [← hspec]; exact (GuillotineVerify.Memory.alignUp32 n).isLt
  have hcast : ((GuillotineVerify.Memory.ceilWords n.toNat * 32 : Nat) : Int) =
      (GuillotineVerify.Memory.ceilWords n.toNat : Int) * 32 := by omega
  have hv_n : (Value.int false 32 n.toNat).valid = true := unsigned_nat_valid _ 32 hlt
  have hv_31 : (Value.int false 32 31).valid = true := unsigned_nat_valid 31 32 (by omega)
  have hv_mask : (Value.int false 32 4294967264).valid = true := unsigned_nat_valid 4294967264 32 (by omega)
  have hv_add : (Value.int false 32 ↑(n.toNat + 31)).valid = true := unsigned_nat_valid _ 32 hadd
  have hv_out : (Value.int false 32 (↑(GuillotineVerify.Memory.ceilWords n.toNat) * 32)).valid = true := by
    rw [← hcast]; exact unsigned_nat_valid _ 32 h_out
  have hi_add : integer false 32 (Arithmetic.add.eval n.toNat 31) .unchecked =
      .ok (.int false 32 ↑(n.toNat + 31)) := by
    change integer false 32 ((n.toNat : Int) + 31) .unchecked = _
    rw [show (n.toNat : Int) + 31 = ↑(n.toNat + 31) by omega]
    exact integer_unchecked_of_valid hv_add
  refine run_of_eval_one rfl rfl (hasType_of_valid hv_n) ?_ (hasType_of_valid hv_out)
  unfold Generated.fn_align_up_32; dsimp only
  rw [eval_bind_ok (arg_eval rfl hv_n) (hasType_of_valid hv_n)]
  rw [eval_bind_ok (arith_eval (ref_local_eval (env_set_self ..) hv_n) (ref_const_eval hv_31) hi_add) (hasType_of_valid hv_add)]
  have hbit := bitAnd_eval (.local 2) (.constant (.int false 32 4294967264))
    [.int false 32 n.toNat]
    ((Control.Env.set (fun _ => none) 0 (.int false 32 n.toNat)).set 2 (.int false 32 ↑(n.toNat + 31)))
    (n.toNat + 31) 4294967264 32
    (ref_local_eval (env_set_self ..) hv_add)
    (ref_const_eval hv_mask)
  rw [hmask, hcast] at hbit
  rw [eval_bind_ok hbit (hasType_of_valid hv_out)]
  exact eval_ret_ok (ref_local_eval (env_set_self ..) hv_out)

/-- Direct Zig AIR proof: `verified_ops.memoryWordCountFast` never overflows for any
    `u32` input and equals `ceilWords(n)` across all `2^32` inputs. -/
theorem memory_word_count_fast_correct (n : BitVec 32) :
    Generated.fn_memory_word_count_fast.run [.int false 32 n.toNat] =
      .ok (.int false 64 (GuillotineVerify.Memory.ceilWords n.toNat)) := by
  have hlt := n.isLt
  have hceil : (n.toNat + 31) >>> 5 = GuillotineVerify.Memory.ceilWords n.toNat := by
    rw [Nat.shiftRight_eq_div_pow]
    unfold GuillotineVerify.Memory.ceilWords
    split <;> omega
  have hbound : GuillotineVerify.Memory.ceilWords n.toNat < 2 ^ 64 := by
    unfold GuillotineVerify.Memory.ceilWords; split <;> omega
  have hv_n32 : (Value.int false 32 n.toNat).valid = true := unsigned_nat_valid _ 32 hlt
  have hv_n64 : (Value.int false 64 n.toNat).valid = true := unsigned_nat_valid _ 64 (by omega)
  have hv_31 : (Value.int false 64 31).valid = true := unsigned_nat_valid 31 64 (by omega)
  have hv_add : (Value.int false 64 ↑(n.toNat + 31)).valid = true := unsigned_nat_valid _ 64 (by omega)
  have hv_5 : (Value.int false 6 5).valid = true := unsigned_nat_valid 5 6 (by omega)
  have hv_out : (Value.int false 64 (GuillotineVerify.Memory.ceilWords n.toNat)).valid = true :=
    unsigned_nat_valid _ 64 hbound
  have hi_add : integer false 64 (Arithmetic.add.eval n.toNat 31) .unchecked =
      .ok (.int false 64 ↑(n.toNat + 31)) := by
    change integer false 64 ((n.toNat : Int) + 31) .unchecked = _
    rw [show (n.toNat : Int) + 31 = ↑(n.toNat + 31) by omega]
    exact integer_unchecked_of_valid hv_add
  refine run_of_eval_one rfl rfl (hasType_of_valid hv_n32) ?_ (hasType_of_valid hv_out)
  unfold Generated.fn_memory_word_count_fast; dsimp only
  rw [eval_bind_ok (arg_eval rfl hv_n32) (hasType_of_valid hv_n32)]
  rw [eval_bind_ok (cast_unchecked_eval (ref_local_eval (env_set_self ..) hv_n32) (integer_unchecked_of_valid hv_n64)) (hasType_of_valid hv_n64)]
  rw [eval_bind_ok (arith_eval (ref_local_eval (env_set_self ..) hv_n64) (ref_const_eval hv_31) hi_add) (hasType_of_valid hv_add)]
  have hsh := shiftRight_eval (.local 3) (.constant (.int false 6 5))
    [.int false 32 n.toNat]
    (((Control.Env.set (fun _ => none) 0 (.int false 32 n.toNat)).set 2 (.int false 64 n.toNat)).set 3 (.int false 64 ↑(n.toNat + 31)))
    (n.toNat + 31) 5 64
    (ref_local_eval (env_set_self ..) hv_add)
    (ref_const_eval hv_5)
    (by omega)
  rw [hceil] at hsh
  rw [eval_bind_ok hsh (hasType_of_valid hv_out)]
  exact eval_ret_ok (ref_local_eval (env_set_self ..) hv_out)

/-- Direct Zig AIR proof: `verified_ops.memoryGasCost` is overflow-free in `u64`
    for all word counts up to 16 MiB (`words ≤ 524_288`) and equals the exact
    Yellow Paper quadratic memory expansion cost `3 * w + floor(w^2 / 512)`. -/
theorem memory_gas_cost_correct (w : Nat) (hw : w ≤ 524288) :
    Generated.fn_memory_gas_cost.run [.int false 64 w] =
      .ok (.int false 64 (GuillotineVerify.Memory.memoryGasCost w)) := by
  have hsq : w * w ≤ 524288 * 524288 := Nat.mul_le_mul hw hw
  have hcost : GuillotineVerify.Memory.memoryGasCost w < 2 ^ 63 :=
    GuillotineVerify.Memory.memoryGasCost_no_overflow w hw
  have hshr : (w * w) >>> 9 = (w * w) / 512 := Nat.shiftRight_eq_div_pow (w * w) 9
  have hv_w : (Value.int false 64 w).valid = true := unsigned_nat_valid _ 64 (by omega)
  have hv_3 : (Value.int false 64 3).valid = true := unsigned_nat_valid 3 64 (by omega)
  have hv_3w : (Value.int false 64 ↑(w * 3)).valid = true := unsigned_nat_valid _ 64 (by omega)
  have hv_ww : (Value.int false 64 ↑(w * w)).valid = true := unsigned_nat_valid _ 64 (by omega)
  have hv_9 : (Value.int false 6 9).valid = true := unsigned_nat_valid 9 6 (by omega)
  have hv_q : (Value.int false 64 ↑((w * w) / 512)).valid = true := unsigned_nat_valid _ 64 (by omega)
  have hv_sum : (Value.int false 64 (GuillotineVerify.Memory.memoryGasCost w)).valid = true :=
    unsigned_nat_valid _ 64 (by omega)
  have hi_3w : integer false 64 (Arithmetic.mul.eval w 3) .unchecked = .ok (.int false 64 ↑(w * 3)) := by
    change integer false 64 ((w : Int) * 3) .unchecked = _
    rw [show (w : Int) * 3 = ↑(w * 3) by omega]
    exact integer_unchecked_of_valid hv_3w
  have hi_ww : integer false 64 (Arithmetic.mul.eval w w) .unchecked = .ok (.int false 64 ↑(w * w)) := by
    change integer false 64 ((w : Int) * (w : Int)) .unchecked = _
    rw [← Int.natCast_mul]
    exact integer_unchecked_of_valid hv_ww
  have hi_sum : integer false 64 (Arithmetic.add.eval ↑(w * 3) ↑((w * w) / 512)) .unchecked =
      .ok (.int false 64 (GuillotineVerify.Memory.memoryGasCost w)) := by
    change integer false 64 (↑(w * 3) + ↑((w * w) / 512)) .unchecked = _
    rw [show (↑(w * 3) : Int) + ↑((w * w) / 512) = ↑(GuillotineVerify.Memory.memoryGasCost w) by
      unfold GuillotineVerify.Memory.memoryGasCost; omega]
    exact integer_unchecked_of_valid hv_sum
  refine run_of_eval_one rfl rfl (hasType_of_valid hv_w) ?_ (hasType_of_valid hv_sum)
  unfold Generated.fn_memory_gas_cost; dsimp only
  rw [eval_bind_ok (arg_eval rfl hv_w) (hasType_of_valid hv_w)]
  rw [eval_bind_ok (arith_eval (ref_local_eval (env_set_self ..) hv_w) (ref_const_eval hv_3) hi_3w) (hasType_of_valid hv_3w)]
  rw [eval_bind_ok (arith_eval
    (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), env_set_self]) hv_w)
    (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), env_set_self]) hv_w)
    hi_ww) (hasType_of_valid hv_ww)]
  have hsh := shiftRight_eval (.local 3) (.constant (.int false 6 9))
    [.int false 64 w]
    (((Control.Env.set (fun _ => none) 0 (.int false 64 w)).set 2 (.int false 64 ↑(w * 3))).set 3 (.int false 64 ↑(w * w)))
    (w * w) 9 64
    (ref_local_eval (env_set_self ..) hv_ww)
    (ref_const_eval hv_9)
    (by omega)
  rw [hshr] at hsh
  rw [eval_bind_ok hsh (hasType_of_valid hv_q)]
  rw [eval_bind_ok (arith_eval
    (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self]) hv_3w)
    (ref_local_eval (env_set_self ..) hv_q)
    hi_sum) (hasType_of_valid hv_sum)]
  exact eval_ret_ok (ref_local_eval (env_set_self ..) hv_sum)

/-- Direct Zig AIR monotonicity corollary for `verified_ops.memoryGasCost`. -/
theorem memory_gas_cost_monotone (w1 w2 : Nat) (h12 : w1 ≤ w2) (h2 : w2 ≤ 524288) :
    ∃ g1 g2,
      Generated.fn_memory_gas_cost.run [.int false 64 w1] = .ok (.int false 64 g1) ∧
      Generated.fn_memory_gas_cost.run [.int false 64 w2] = .ok (.int false 64 g2) ∧
      g1 ≤ g2 := by
  refine ⟨GuillotineVerify.Memory.memoryGasCost w1, GuillotineVerify.Memory.memoryGasCost w2,
    memory_gas_cost_correct w1 (Nat.le_trans h12 h2), memory_gas_cost_correct w2 h2, ?_⟩
  exact Int.ofNat_le.mpr (GuillotineVerify.Memory.memoryGasCost_mono w1 w2 h12)

/-- Direct Zig AIR proof: `verified_ops.blockStackGuardRefCode` matches
    `GuillotineVerify.BasicBlock.blockStackGuardRef` for ALL `2^32 × 2^16 × 2^16` inputs. -/
theorem block_stack_guard_ref_correct (size : BitVec 32) (mn mx : BitVec 16) :
    Generated.fn_block_stack_guard_ref.run
        [.int false 32 size.toNat, .int false 16 mn.toNat, .int false 16 mx.toNat] =
      .ok (.int false 8 (guardCode (GuillotineVerify.BasicBlock.blockStackGuardRef size mn mx 1024))) := by
  have hs := size.isLt
  have hmn := mn.isLt
  have hmx := mx.isLt
  have hv_s : (Value.int false 32 size.toNat).valid = true := unsigned_nat_valid _ 32 hs
  have hv_mn : (Value.int false 16 mn.toNat).valid = true := unsigned_nat_valid _ 16 hmn
  have hv_mx : (Value.int false 16 mx.toNat).valid = true := unsigned_nat_valid _ 16 hmx
  have hv_mn32 : (Value.int false 32 mn.toNat).valid = true := unsigned_nat_valid _ 32 (by omega)
  have hv_s64 : (Value.int false 64 size.toNat).valid = true := unsigned_nat_valid _ 64 (by omega)
  have hv_mx64 : (Value.int false 64 mx.toNat).valid = true := unsigned_nat_valid _ 64 (by omega)
  have hv_sum64 : (Value.int false 64 ↑(size.toNat + mx.toNat)).valid = true := unsigned_nat_valid _ 64 (by omega)
  have hv_1024 : (Value.int false 64 1024).valid = true := unsigned_nat_valid 1024 64 (by omega)
  have hv_0 : (Value.int false 8 0).valid = true := unsigned_nat_valid 0 8 (by omega)
  have hv_1 : (Value.int false 8 1).valid = true := unsigned_nat_valid 1 8 (by omega)
  have hv_2 : (Value.int false 8 2).valid = true := unsigned_nat_valid 2 8 (by omega)
  have hi_sum64 : integer false 64 (Arithmetic.add.eval size.toNat mx.toNat) .unchecked =
      .ok (.int false 64 ↑(size.toNat + mx.toNat)) := by
    change integer false 64 ((size.toNat : Int) + mx.toNat) .unchecked = _
    rw [show (size.toNat : Int) + mx.toNat = ↑(size.toNat + mx.toNat) by omega]
    exact integer_unchecked_of_valid hv_sum64
  have ht_res : (Value.int false 8 (guardCode (GuillotineVerify.BasicBlock.blockStackGuardRef size mn mx 1024))).hasType (.int false 8) = true := by
    cases GuillotineVerify.BasicBlock.blockStackGuardRef size mn mx 1024
    · exact hasType_of_valid hv_0
    · exact hasType_of_valid hv_1
    · exact hasType_of_valid hv_2
  refine run_of_eval_three rfl rfl (hasType_of_valid hv_s) (hasType_of_valid hv_mn) (hasType_of_valid hv_mx) ?_ ht_res
  unfold Generated.fn_block_stack_guard_ref GuillotineVerify.BasicBlock.blockStackGuardRef
  dsimp only
  have h1024 : (1024 : BitVec 32).toNat = 1024 := by
    change (BitVec.ofNat 32 1024).toNat = 1024; rw [BitVec.toNat_ofNat]
  rw [h1024]
  rw [eval_bind_ok (arg_eval rfl hv_s) (hasType_of_valid hv_s)]
  rw [eval_bind_ok (arg_eval rfl hv_mn) (hasType_of_valid hv_mn)]
  rw [eval_bind_ok (arg_eval rfl hv_mx) (hasType_of_valid hv_mx)]
  let args := [Value.int false 32 size.toNat, .int false 16 mn.toNat, .int false 16 mx.toNat]
  let env0 : Env := ((Control.Env.set (fun _ => none) 0 (.int false 32 size.toNat)).set 1 (.int false 16 mn.toNat)).set 2 (.int false 16 mx.toNat)
  change Control.Code.eval controlSemantics _ args env0 () = _
  have he0_0 : env0 0 = some (.int false 32 size.toNat) := by
    simp only [env0]; rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self]
  have he0_1 : env0 1 = some (.int false 16 mn.toNat) := by
    simp only [env0]; rw [env_set_ne _ _ _ _ (by decide), env_set_self]
  have he0_2 : env0 2 = some (.int false 16 mx.toNat) := by
    simp only [env0]; rw [env_set_self]
  by_cases hlt : size.toNat < mn.toNat
  · simp only [hlt, ↓reduceIte, guardCode]
    have hb4 : Control.Code.eval controlSemantics
        (.bind 5 (.int false 32) (.cast .unchecked (.int false 32) (.local 1))
        (.bind 6 .bool (.comparison .lt (.local 0) (.local 5))
        (.branch (.local 6) (.jump 3 (.constant (.int false 8 1))) (.jump 4 (.constant .unit)))))
        args env0 () = .jumped 3 (.int false 8 1) ((env0.set 5 (.int false 32 mn.toNat)).set 6 (.bool true)) () := by
      rw [eval_bind_ok (cast_unchecked_eval (ref_local_eval he0_1 hv_mn) (integer_unchecked_of_valid hv_mn32)) (hasType_of_valid hv_mn32)]
      rw [eval_bind_ok (cmp_eval
        (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), he0_0]) hv_s)
        (ref_local_eval (env_set_self ..) hv_mn32)
        (show Comparison.lt.eval size.toNat mn.toNat = true by simp [Comparison.eval, hlt])) (hasType_bool true)]
      rw [eval_branch_true (ref_local_eval (env_set_self ..) (valid_bool true))]
      exact eval_jump_ok (ref_const_eval hv_1)
    rw [eval_block_jump_hit (eval_block_jump_miss hb4 (by decide)) (hasType_of_valid hv_1)]
    exact eval_ret_ok (ref_local_eval (env_set_self ..) hv_1)
  · simp only [hlt, ↓reduceIte]
    have hb4 : Control.Code.eval controlSemantics
        (.bind 5 (.int false 32) (.cast .unchecked (.int false 32) (.local 1))
        (.bind 6 .bool (.comparison .lt (.local 0) (.local 5))
        (.branch (.local 6) (.jump 3 (.constant (.int false 8 1))) (.jump 4 (.constant .unit)))))
        args env0 () = .jumped 4 .unit ((env0.set 5 (.int false 32 mn.toNat)).set 6 (.bool false)) () := by
      rw [eval_bind_ok (cast_unchecked_eval (ref_local_eval he0_1 hv_mn) (integer_unchecked_of_valid hv_mn32)) (hasType_of_valid hv_mn32)]
      rw [eval_bind_ok (cmp_eval
        (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), he0_0]) hv_s)
        (ref_local_eval (env_set_self ..) hv_mn32)
        (show Comparison.lt.eval size.toNat mn.toNat = false by simp [Comparison.eval, hlt])) (hasType_bool false)]
      rw [eval_branch_false (ref_local_eval (env_set_self ..) (valid_bool false))]
      exact eval_jump_ok (ref_const_eval valid_unit)
    let env4 : Env := ((env0.set 5 (.int false 32 mn.toNat)).set 6 (.bool false)).set 4 .unit
    have he4_0 : env4 0 = some (.int false 32 size.toNat) := by
      simp only [env4, Env.set]; rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he0_0]
    have he4_2 : env4 2 = some (.int false 16 mx.toNat) := by
      simp only [env4, Env.set]; rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he0_2]
    let env13 : Env := ((env4.set 11 (.int false 64 size.toNat)).set 12 (.int false 64 mx.toNat)).set 13 (.int false 64 ↑(size.toNat + mx.toNat))
    have hpre10 : ∀ (rest : Code),
        Control.Code.eval controlSemantics
          (.bind 11 (.int false 64) (.cast .unchecked (.int false 64) (.local 0))
          (.bind 12 (.int false 64) (.cast .unchecked (.int false 64) (.local 2))
          (.bind 13 (.int false 64) (.arithmetic .add .unchecked (.local 11) (.local 12)) rest)))
          args env4 () = Control.Code.eval controlSemantics rest args env13 () := by
      intro rest
      rw [eval_bind_ok (cast_unchecked_eval (ref_local_eval he4_0 hv_s) (integer_unchecked_of_valid hv_s64)) (hasType_of_valid hv_s64)]
      rw [eval_bind_ok (cast_unchecked_eval (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), he4_2]) hv_mx) (integer_unchecked_of_valid hv_mx64)) (hasType_of_valid hv_mx64)]
      rw [eval_bind_ok (arith_eval
        (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), env_set_self]) hv_s64)
        (ref_local_eval (env_set_self ..) hv_mx64)
        hi_sum64) (hasType_of_valid hv_sum64)]
    by_cases hov : size.toNat + mx.toNat > 1024
    · simp only [hov, ↓reduceIte, guardCode]
      have hb10 : Control.Code.eval controlSemantics
          (.bind 11 (.int false 64) (.cast .unchecked (.int false 64) (.local 0))
          (.bind 12 (.int false 64) (.cast .unchecked (.int false 64) (.local 2))
          (.bind 13 (.int false 64) (.arithmetic .add .unchecked (.local 11) (.local 12))
          (.bind 14 .bool (.comparison .gt (.local 13) (.constant (.int false 64 1024)))
          (.branch (.local 14) (.jump 3 (.constant (.int false 8 2))) (.jump 10 (.constant .unit)))))))
          args env4 () = .jumped 3 (.int false 8 2) (env13.set 14 (.bool true)) () := by
        rw [hpre10]
        rw [eval_bind_ok (cmp_eval
          (ref_local_eval (env_set_self ..) hv_sum64)
          (ref_const_eval hv_1024)
          (show Comparison.gt.eval ↑(size.toNat + mx.toNat) 1024 = true by simp [Comparison.eval]; omega)) (hasType_bool true)]
        rw [eval_branch_true (ref_local_eval (env_set_self ..) (valid_bool true))]
        exact eval_jump_ok (ref_const_eval hv_2)
      rw [eval_block_jump_hit (by rw [eval_block_jump_hit hb4 hasType_unit]; exact eval_block_jump_miss hb10 (by decide)) (hasType_of_valid hv_2)]
      exact eval_ret_ok (ref_local_eval (env_set_self ..) hv_2)
    · simp only [hov, ↓reduceIte, guardCode]
      have hb10 : Control.Code.eval controlSemantics
          (.bind 11 (.int false 64) (.cast .unchecked (.int false 64) (.local 0))
          (.bind 12 (.int false 64) (.cast .unchecked (.int false 64) (.local 2))
          (.bind 13 (.int false 64) (.arithmetic .add .unchecked (.local 11) (.local 12))
          (.bind 14 .bool (.comparison .gt (.local 13) (.constant (.int false 64 1024)))
          (.branch (.local 14) (.jump 3 (.constant (.int false 8 2))) (.jump 10 (.constant .unit)))))))
          args env4 () = .jumped 10 .unit (env13.set 14 (.bool false)) () := by
        rw [hpre10]
        rw [eval_bind_ok (cmp_eval
          (ref_local_eval (env_set_self ..) hv_sum64)
          (ref_const_eval hv_1024)
          (show Comparison.gt.eval ↑(size.toNat + mx.toNat) 1024 = false by simp [Comparison.eval]; omega)) (hasType_bool false)]
        rw [eval_branch_false (ref_local_eval (env_set_self ..) (valid_bool false))]
        exact eval_jump_ok (ref_const_eval valid_unit)
      rw [eval_block_jump_hit (by rw [eval_block_jump_hit hb4 hasType_unit, eval_block_jump_hit hb10 hasType_unit]; exact eval_jump_ok (ref_const_eval hv_0)) (hasType_of_valid hv_0)]
      exact eval_ret_ok (ref_local_eval (env_set_self ..) hv_0)

/-- Direct Zig AIR proof: `verified_ops.blockStackGuardFastCode` matches
    `GuillotineVerify.BasicBlock.blockStackGuardRef` for ALL `2^32 × 2^16 × 2^16` inputs
    with zero illegal behavior or safety panics. -/
theorem block_stack_guard_fast_correct (size : BitVec 32) (mn mx : BitVec 16) :
    Generated.fn_block_stack_guard_fast.run
        [.int false 32 size.toNat, .int false 16 mn.toNat, .int false 16 mx.toNat] =
      .ok (.int false 8 (guardCode (GuillotineVerify.BasicBlock.blockStackGuardRef size mn mx 1024))) := by
  have hs := size.isLt
  have hmn := mn.isLt
  have hmx := mx.isLt
  have hv_s : (Value.int false 32 size.toNat).valid = true := unsigned_nat_valid _ 32 hs
  have hv_mn : (Value.int false 16 mn.toNat).valid = true := unsigned_nat_valid _ 16 hmn
  have hv_mx : (Value.int false 16 mx.toNat).valid = true := unsigned_nat_valid _ 16 hmx
  have hv_mn32 : (Value.int false 32 mn.toNat).valid = true := unsigned_nat_valid _ 32 (by omega)
  have hv_mx32 : (Value.int false 32 mx.toNat).valid = true := unsigned_nat_valid _ 32 (by omega)
  have hv_need : (Value.int false 32 ↑(mn.toNat + mx.toNat)).valid = true := unsigned_nat_valid _ 32 (by omega)
  have hv_1024 : (Value.int false 32 1024).valid = true := unsigned_nat_valid 1024 32 (by omega)
  have hi_need : integer false 32 (Arithmetic.add.eval mn.toNat mx.toNat) .unchecked =
      .ok (.int false 32 ↑(mn.toNat + mx.toNat)) := by
    change integer false 32 ((mn.toNat : Int) + mx.toNat) .unchecked = _
    rw [show (mn.toNat : Int) + mx.toNat = ↑(mn.toNat + mx.toNat) by omega]
    exact integer_unchecked_of_valid hv_need
  have hwrap_eq : ((size.toNat : Int) - mn.toNat) % (2 : Int) ^ 32 =
      if mn.toNat ≤ size.toNat then (size.toNat : Int) - mn.toNat
      else (size.toNat : Int) - mn.toNat + (2 : Int) ^ 32 := by
    split <;> omega
  have hi_wrap : integer false 32 (Arithmetic.sub.eval size.toNat mn.toNat) .wrapping =
      .ok (.int false 32 (((size.toNat : Int) - mn.toNat) % (2 : Int) ^ 32)) :=
    integer_wrapping_uint _
  have hv_wrap : (Value.int false 32 (((size.toNat : Int) - mn.toNat) % (2 : Int) ^ 32)).valid = true := by
    rw [hwrap_eq]; split <;> exact valid_uint (by omega) (by omega)
  have hv_0 : (Value.int false 8 0).valid = true := unsigned_nat_valid 0 8 (by omega)
  have hv_1 : (Value.int false 8 1).valid = true := unsigned_nat_valid 1 8 (by omega)
  have hv_2 : (Value.int false 8 2).valid = true := unsigned_nat_valid 2 8 (by omega)
  have ht_res : (Value.int false 8 (guardCode (GuillotineVerify.BasicBlock.blockStackGuardRef size mn mx 1024))).hasType (.int false 8) = true := by
    cases GuillotineVerify.BasicBlock.blockStackGuardRef size mn mx 1024
    · exact hasType_of_valid hv_0
    · exact hasType_of_valid hv_1
    · exact hasType_of_valid hv_2
  have hfallback : ∀ (envF : Env) (args : List Value),
      envF 0 = some (.int false 32 size.toNat) → envF 4 = some (.int false 32 mn.toNat) →
      Control.Code.eval controlSemantics
        (.block 19 (.int false 8)
          (.bind 20 .bool (.comparison .lt (.local 0) (.local 4))
            (.branch (.local 20) (.jump 19 (.constant (.int false 8 1))) (.jump 19 (.constant (.int false 8 2)))))
          (.jump 3 (.local 19))) args envF () =
      .jumped 3 (.int false 8 (if size.toNat < mn.toNat then 1 else 2))
        ((envF.set 20 (.bool (decide (size.toNat < mn.toNat)))).set 19
          (.int false 8 (if size.toNat < mn.toNat then 1 else 2))) () := by
    intro envF args h0 h4
    by_cases hlt : size.toNat < mn.toNat
    · have hb19 : Control.Code.eval controlSemantics
          (.bind 20 .bool (.comparison .lt (.local 0) (.local 4))
            (.branch (.local 20) (.jump 19 (.constant (.int false 8 1))) (.jump 19 (.constant (.int false 8 2)))))
          args envF () = .jumped 19 (.int false 8 1) (envF.set 20 (.bool true)) () := by
        rw [eval_bind_ok (cmp_eval (ref_local_eval h0 hv_s) (ref_local_eval h4 hv_mn32)
          (show Comparison.lt.eval size.toNat mn.toNat = true by simp [Comparison.eval, hlt])) (hasType_bool true)]
        rw [eval_branch_true (ref_local_eval (env_set_self ..) (valid_bool true))]
        exact eval_jump_ok (ref_const_eval hv_1)
      rw [eval_block_jump_hit hb19 (hasType_of_valid hv_1)]
      simp only [hlt, ↓reduceIte, decide_true]
      exact eval_jump_ok (ref_local_eval (env_set_self ..) hv_1)
    · have hb19 : Control.Code.eval controlSemantics
          (.bind 20 .bool (.comparison .lt (.local 0) (.local 4))
            (.branch (.local 20) (.jump 19 (.constant (.int false 8 1))) (.jump 19 (.constant (.int false 8 2)))))
          args envF () = .jumped 19 (.int false 8 2) (envF.set 20 (.bool false)) () := by
        rw [eval_bind_ok (cmp_eval (ref_local_eval h0 hv_s) (ref_local_eval h4 hv_mn32)
          (show Comparison.lt.eval size.toNat mn.toNat = false by simp [Comparison.eval, hlt])) (hasType_bool false)]
        rw [eval_branch_false (ref_local_eval (env_set_self ..) (valid_bool false))]
        exact eval_jump_ok (ref_const_eval hv_2)
      rw [eval_block_jump_hit hb19 (hasType_of_valid hv_2)]
      simp only [hlt, ↓reduceIte, decide_false]
      exact eval_jump_ok (ref_local_eval (env_set_self ..) hv_2)
  refine run_of_eval_three rfl rfl (hasType_of_valid hv_s) (hasType_of_valid hv_mn) (hasType_of_valid hv_mx) ?_ ht_res
  unfold Generated.fn_block_stack_guard_fast GuillotineVerify.BasicBlock.blockStackGuardRef
  dsimp only
  have h1024 : (1024 : BitVec 32).toNat = 1024 := by
    change (BitVec.ofNat 32 1024).toNat = 1024; rw [BitVec.toNat_ofNat]
  rw [h1024]
  rw [eval_bind_ok (arg_eval rfl hv_s) (hasType_of_valid hv_s)]
  rw [eval_bind_ok (arg_eval rfl hv_mn) (hasType_of_valid hv_mn)]
  rw [eval_bind_ok (arg_eval rfl hv_mx) (hasType_of_valid hv_mx)]
  let args := [Value.int false 32 size.toNat, .int false 16 mn.toNat, .int false 16 mx.toNat]
  let env0 : Env := ((Control.Env.set (fun _ => none) 0 (.int false 32 size.toNat)).set 1 (.int false 16 mn.toNat)).set 2 (.int false 16 mx.toNat)
  let env6 : Env := ((env0.set 4 (.int false 32 mn.toNat)).set 5 (.int false 32 mx.toNat)).set 6 (.int false 32 ↑(mn.toNat + mx.toNat))
  change Control.Code.eval controlSemantics _ args env0 () = _
  have he0_0 : env0 0 = some (.int false 32 size.toNat) := by
    simp only [env0]; rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self]
  have he0_1 : env0 1 = some (.int false 16 mn.toNat) := by
    simp only [env0]; rw [env_set_ne _ _ _ _ (by decide), env_set_self]
  have he0_2 : env0 2 = some (.int false 16 mx.toNat) := by
    simp only [env0]; rw [env_set_self]
  have he6_0 : env6 0 = some (.int false 32 size.toNat) := by
    simp only [env6, Env.set]; rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he0_0]
  have he6_4 : env6 4 = some (.int false 32 mn.toNat) := by
    simp only [env6, Env.set]; rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self]
  have he6_6 : env6 6 = some (.int false 32 ↑(mn.toNat + mx.toNat)) := by
    simp only [env6, Env.set]; rw [env_set_self]
  have hprefix : ∀ (rest : Code),
      Control.Code.eval controlSemantics
        (.bind 4 (.int false 32) (.cast .unchecked (.int false 32) (.local 1))
        (.bind 5 (.int false 32) (.cast .unchecked (.int false 32) (.local 2))
        (.bind 6 (.int false 32) (.arithmetic .add .unchecked (.local 4) (.local 5)) rest)))
        args env0 () = Control.Code.eval controlSemantics rest args env6 () := by
    intro rest
    rw [eval_bind_ok (cast_unchecked_eval (ref_local_eval he0_1 hv_mn) (integer_unchecked_of_valid hv_mn32)) (hasType_of_valid hv_mn32)]
    rw [eval_bind_ok (cast_unchecked_eval (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), he0_2]) hv_mx) (integer_unchecked_of_valid hv_mx32)) (hasType_of_valid hv_mx32)]
    rw [eval_bind_ok (arith_eval
      (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), env_set_self]) hv_mn32)
      (ref_local_eval (env_set_self ..) hv_mx32)
      hi_need) (hasType_of_valid hv_need)]
  by_cases hneed : mn.toNat + mx.toNat ≤ 1024
  · have hv_rem : (Value.int false 32 ↑(1024 - (mn.toNat + mx.toNat))).valid = true :=
      unsigned_nat_valid _ 32 (by omega)
    have hi_rem : integer false 32 (Arithmetic.sub.eval 1024 ↑(mn.toNat + mx.toNat)) .unchecked =
        .ok (.int false 32 ↑(1024 - (mn.toNat + mx.toNat))) := by
      change integer false 32 (1024 - ↑(mn.toNat + mx.toNat)) .unchecked = _
      rw [show (1024 : Int) - ↑(mn.toNat + mx.toNat) = ↑(1024 - (mn.toNat + mx.toNat)) by omega]
      exact integer_unchecked_of_valid hv_rem
    let env11 : Env := Control.Env.set (Control.Env.set (Control.Env.set env6 8 (.bool true)) 10 (.int false 32 (((size.toNat : Int) - mn.toNat) % (2 : Int) ^ 32))) 11 (.int false 32 ↑(1024 - (mn.toNat + mx.toNat)))
    have hpre9 : ∀ (rest : Code),
        Control.Code.eval controlSemantics
          (.bind 10 (.int false 32) (.arithmetic .sub .wrapping (.local 0) (.local 4))
          (.bind 11 (.int false 32) (.arithmetic .sub .unchecked (.constant (.int false 32 1024)) (.local 6)) rest))
          args (Control.Env.set env6 8 (.bool true)) () = Control.Code.eval controlSemantics rest args env11 () := by
      intro rest
      rw [eval_bind_ok (arith_eval
        (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), he6_0]) hv_s)
        (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), he6_4]) hv_mn32)
        hi_wrap) (hasType_of_valid hv_wrap)]
      rw [eval_bind_ok (arith_eval
        (ref_const_eval hv_1024)
        (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he6_6]) hv_need)
        hi_rem) (hasType_of_valid hv_rem)]
    have henv11_0 : env11 0 = some (.int false 32 size.toNat) := by
      simp only [env11]; rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he6_0]
    have henv11_4 : env11 4 = some (.int false 32 mn.toNat) := by
      simp only [env11]; rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he6_4]
    by_cases hlt : size.toNat < mn.toNat
    · have hge : ¬ (mn.toNat ≤ size.toNat) := by omega
      simp only [hge, ↓reduceIte] at hwrap_eq
      simp only [hlt, ↓reduceIte, guardCode]
      have hb9 : Control.Code.eval controlSemantics
          (.bind 10 (.int false 32) (.arithmetic .sub .wrapping (.local 0) (.local 4))
          (.bind 11 (.int false 32) (.arithmetic .sub .unchecked (.constant (.int false 32 1024)) (.local 6))
          (.bind 12 .bool (.comparison .le (.local 10) (.local 11))
          (.branch (.local 12) (.jump 3 (.constant (.int false 8 0))) (.jump 9 (.constant .unit))))))
          args (Control.Env.set env6 8 (.bool true)) () = .jumped 9 .unit (Control.Env.set env11 12 (.bool false)) () := by
        rw [hpre9]
        rw [eval_bind_ok (cmp_eval
          (ref_local_eval (by simp only [env11]; rw [env_set_ne _ _ _ _ (by decide), env_set_self]) hv_wrap)
          (ref_local_eval (by simp only [env11]; rw [env_set_self]) hv_rem)
          (show Comparison.le.eval (((size.toNat : Int) - mn.toNat) % (2 : Int) ^ 32) ↑(1024 - (mn.toNat + mx.toNat)) = false by
            simp only [Comparison.eval, decide_eq_false_iff_not]; rw [hwrap_eq]; omega)) (hasType_bool false)]
        rw [eval_branch_false (ref_local_eval (env_set_self ..) (valid_bool false))]
        exact eval_jump_ok (ref_const_eval valid_unit)
      rw [eval_block_jump_hit (by
        rw [hprefix]
        rw [eval_block_jump_hit (by
          rw [eval_bind_ok (cmp_eval (ref_local_eval he6_6 hv_need) (ref_const_eval hv_1024)
            (show Comparison.le.eval ↑(mn.toNat + mx.toNat) 1024 = true by simp [Comparison.eval]; omega)) (hasType_bool true)]
          rw [eval_branch_true (ref_local_eval (env_set_self ..) (valid_bool true))]
          rw [eval_block_jump_hit hb9 hasType_unit]
          exact eval_jump_ok (ref_const_eval valid_unit)) hasType_unit]
        simpa [hlt] using hfallback _ args
          (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), henv11_0])
          (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), henv11_4])) (hasType_of_valid hv_1)]
      exact eval_ret_ok (ref_local_eval (env_set_self ..) hv_1)
    · have hge : mn.toNat ≤ size.toNat := by omega
      simp only [hge, ↓reduceIte] at hwrap_eq
      simp only [hlt, ↓reduceIte]
      by_cases hov : size.toNat + mx.toNat > 1024
      · simp only [hov, ↓reduceIte, guardCode]
        have hb9 : Control.Code.eval controlSemantics
            (.bind 10 (.int false 32) (.arithmetic .sub .wrapping (.local 0) (.local 4))
            (.bind 11 (.int false 32) (.arithmetic .sub .unchecked (.constant (.int false 32 1024)) (.local 6))
            (.bind 12 .bool (.comparison .le (.local 10) (.local 11))
            (.branch (.local 12) (.jump 3 (.constant (.int false 8 0))) (.jump 9 (.constant .unit))))))
            args (Control.Env.set env6 8 (.bool true)) () = .jumped 9 .unit (Control.Env.set env11 12 (.bool false)) () := by
          rw [hpre9]
          rw [eval_bind_ok (cmp_eval
            (ref_local_eval (by simp only [env11]; rw [env_set_ne _ _ _ _ (by decide), env_set_self]) hv_wrap)
            (ref_local_eval (by simp only [env11]; rw [env_set_self]) hv_rem)
            (show Comparison.le.eval (((size.toNat : Int) - mn.toNat) % (2 : Int) ^ 32) ↑(1024 - (mn.toNat + mx.toNat)) = false by
              simp only [Comparison.eval, decide_eq_false_iff_not]; rw [hwrap_eq]; omega)) (hasType_bool false)]
          rw [eval_branch_false (ref_local_eval (env_set_self ..) (valid_bool false))]
          exact eval_jump_ok (ref_const_eval valid_unit)
        rw [eval_block_jump_hit (by
          rw [hprefix]
          rw [eval_block_jump_hit (by
            rw [eval_bind_ok (cmp_eval (ref_local_eval he6_6 hv_need) (ref_const_eval hv_1024)
              (show Comparison.le.eval ↑(mn.toNat + mx.toNat) 1024 = true by simp [Comparison.eval]; omega)) (hasType_bool true)]
            rw [eval_branch_true (ref_local_eval (env_set_self ..) (valid_bool true))]
            rw [eval_block_jump_hit hb9 hasType_unit]
            exact eval_jump_ok (ref_const_eval valid_unit)) hasType_unit]
          simpa [hlt] using hfallback _ args
            (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), henv11_0])
            (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), henv11_4])) (hasType_of_valid hv_2)]
        exact eval_ret_ok (ref_local_eval (env_set_self ..) hv_2)
      · simp only [hov, ↓reduceIte, guardCode]
        have hb9 : Control.Code.eval controlSemantics
            (.bind 10 (.int false 32) (.arithmetic .sub .wrapping (.local 0) (.local 4))
            (.bind 11 (.int false 32) (.arithmetic .sub .unchecked (.constant (.int false 32 1024)) (.local 6))
            (.bind 12 .bool (.comparison .le (.local 10) (.local 11))
            (.branch (.local 12) (.jump 3 (.constant (.int false 8 0))) (.jump 9 (.constant .unit))))))
            args (Control.Env.set env6 8 (.bool true)) () = .jumped 3 (.int false 8 0) (Control.Env.set env11 12 (.bool true)) () := by
          rw [hpre9]
          rw [eval_bind_ok (cmp_eval
            (ref_local_eval (by simp only [env11]; rw [env_set_ne _ _ _ _ (by decide), env_set_self]) hv_wrap)
            (ref_local_eval (by simp only [env11]; rw [env_set_self]) hv_rem)
            (show Comparison.le.eval (((size.toNat : Int) - mn.toNat) % (2 : Int) ^ 32) ↑(1024 - (mn.toNat + mx.toNat)) = true by
              simp only [Comparison.eval, decide_eq_true_eq]; rw [hwrap_eq]; omega)) (hasType_bool true)]
          rw [eval_branch_true (ref_local_eval (env_set_self ..) (valid_bool true))]
          exact eval_jump_ok (ref_const_eval hv_0)
        rw [eval_block_jump_hit (by
          rw [hprefix]
          exact eval_block_jump_miss (by
            rw [eval_bind_ok (cmp_eval (ref_local_eval he6_6 hv_need) (ref_const_eval hv_1024)
              (show Comparison.le.eval ↑(mn.toNat + mx.toNat) 1024 = true by simp [Comparison.eval]; omega)) (hasType_bool true)]
            rw [eval_branch_true (ref_local_eval (env_set_self ..) (valid_bool true))]
            exact eval_block_jump_miss hb9 (by decide)) (by decide)) (hasType_of_valid hv_0)]
        exact eval_ret_ok (ref_local_eval (env_set_self ..) hv_0)
  · by_cases hlt : size.toNat < mn.toNat
    · simp only [hlt, ↓reduceIte, guardCode]
      rw [eval_block_jump_hit (by
        rw [hprefix]
        rw [eval_block_jump_hit (by
          rw [eval_bind_ok (cmp_eval (ref_local_eval he6_6 hv_need) (ref_const_eval hv_1024)
            (show Comparison.le.eval ↑(mn.toNat + mx.toNat) 1024 = false by simp [Comparison.eval]; omega)) (hasType_bool false)]
          rw [eval_branch_false (ref_local_eval (env_set_self ..) (valid_bool false))]
          exact eval_jump_ok (ref_const_eval valid_unit)) hasType_unit]
        simpa [hlt] using hfallback _ args
          (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he6_0])
          (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he6_4])) (hasType_of_valid hv_1)]
      exact eval_ret_ok (ref_local_eval (env_set_self ..) hv_1)
    · have hov : size.toNat + mx.toNat > 1024 := by omega
      simp only [hlt, hov, ↓reduceIte, guardCode]
      rw [eval_block_jump_hit (by
        rw [hprefix]
        rw [eval_block_jump_hit (by
          rw [eval_bind_ok (cmp_eval (ref_local_eval he6_6 hv_need) (ref_const_eval hv_1024)
            (show Comparison.le.eval ↑(mn.toNat + mx.toNat) 1024 = false by simp [Comparison.eval]; omega)) (hasType_bool false)]
          rw [eval_branch_false (ref_local_eval (env_set_self ..) (valid_bool false))]
          exact eval_jump_ok (ref_const_eval valid_unit)) hasType_unit]
        simpa [hlt] using hfallback _ args
          (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he6_0])
          (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he6_4])) (hasType_of_valid hv_2)]
      exact eval_ret_ok (ref_local_eval (env_set_self ..) hv_2)

/-- Direct Zig AIR equivalence: the compiled Zig AIR of `blockStackGuardFastCode`
    returns the exact same result as `blockStackGuardRefCode` for ALL inputs! -/
theorem block_stack_guard_fast_eq_ref (size : BitVec 32) (mn mx : BitVec 16) :
    Generated.fn_block_stack_guard_fast.run
        [.int false 32 size.toNat, .int false 16 mn.toNat, .int false 16 mx.toNat] =
      Generated.fn_block_stack_guard_ref.run
        [.int false 32 size.toNat, .int false 16 mn.toNat, .int false 16 mx.toNat] := by
  rw [block_stack_guard_fast_correct, block_stack_guard_ref_correct]

end GuillotineZean.ScalarOps
