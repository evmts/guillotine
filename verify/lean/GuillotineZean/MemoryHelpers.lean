/-
  GuillotineZean.MemoryHelpers

  Reusable, kernel-fast O(1) symbolic evaluation lemmas for Zean's `MemoryAir`
  semantics, including native 256-bit EVM words (`BitVec 256` <-> `.scalar (.int false 256 _)`).
-/
import Compiler.ZigAir.MemoryAir
import Compiler.ZigAir.BitwiseProofs
import Compiler.ZigAir.MemoryEffects
import Compiler.ZigAir.MemoryInvariant

namespace GuillotineZean.MemoryHelpers
open Compiler.ZigAir Compiler.ZigAir.Memory Compiler.ZigAir.MemoryAir

abbrev u256Ty : Memory.Ty := .scalar (.int false 256)
abbrev u256Val (w : BitVec 256) : Memory.Value := .scalar (.int false 256 w.toNat)

theorem scalar_valid_of_nat {w : Nat} {x : Nat} (hx : x < 2 ^ w) :
    (Scalar.Value.int false w x).valid = true :=
  Scalar.unsigned_nat_valid x w hx

theorem scalar_hasType_of_valid {w : Nat} {x : Int}
    (hv : (Scalar.Value.int false w x).valid = true) :
    (Scalar.Value.int false w x).hasType (.int false w) = true := by
  simp only [Scalar.Value.hasType, Scalar.Value.type, hv, decide_true, Bool.and_self]

theorem mem_scalar_valid {sv : Scalar.Value} (hv : sv.valid = true) :
    (Memory.Value.scalar sv).valid = true := by
  simp only [Memory.Value.valid, hv]

theorem mem_scalar_hasType {sv : Scalar.Value} {st : Scalar.Ty}
    (ht : sv.hasType st = true) :
    (Memory.Value.scalar sv).hasType (.scalar st) = true := by
  simp only [Memory.Value.hasType, Memory.Value.type, Memory.Value.valid]
  simp only [Scalar.Value.hasType, Bool.and_eq_true, decide_eq_true_eq] at ht
  simp only [ht.1, ht.2, decide_true, Bool.and_self]

theorem u256_scalar_valid (w : BitVec 256) :
    (Scalar.Value.int false 256 w.toNat).valid = true :=
  Scalar.unsigned_nat_valid w.toNat 256 w.isLt

theorem u256_val_valid (w : BitVec 256) : (u256Val w).valid = true :=
  mem_scalar_valid (u256_scalar_valid w)

theorem u256_val_hasType (w : BitVec 256) : (u256Val w).hasType u256Ty = true :=
  mem_scalar_hasType (scalar_hasType_of_valid (u256_scalar_valid w))

theorem bool_val_valid (b : Bool) : (Memory.Value.scalar (.bool b)).valid = true := rfl
theorem bool_val_hasType (b : Bool) : (Memory.Value.scalar (.bool b)).hasType (.scalar .bool) = true := rfl
theorem unit_val_valid : (Memory.Value.scalar .unit).valid = true := rfl
theorem unit_val_hasType : (Memory.Value.scalar .unit).hasType (.scalar .unit) = true := rfl

theorem ptr_valid_of_hasType {p : Memory.Value} {ty : Memory.Ty}
    (ht : p.hasType ty = true) : p.valid = true := by
  simp only [Memory.Value.hasType, Bool.and_eq_true] at ht
  exact ht.2

theorem integer_unchecked_of_valid {w : Nat} {x : Int}
    (hv : (Scalar.Value.int false w x).valid = true) :
    Scalar.integer false w x .unchecked = .ok (.int false w x) := by
  simp only [Scalar.Value.valid] at hv
  simp only [Scalar.integer, hv, reduceCtorEq, ↓reduceIte]

theorem integer_wrapping_uint {w : Nat} (x : Int) :
    Scalar.integer false w x .wrapping = .ok (.int false w (x % (2 : Int) ^ w)) := by
  simp [Scalar.integer, Scalar.normalize]

theorem bv256_add_int_mod (a b : BitVec 256) :
    ((a.toNat : Int) + b.toNat) % (2 : Int) ^ 256 = ↑(a + b).toNat := by
  rw [BitVec.toNat_add]
  have h1 : (a.toNat : Int) + b.toNat = ↑(a.toNat + b.toNat) := by omega
  rw [h1]
  exact_mod_cast (rfl : (a.toNat + b.toNat) % 2 ^ 256 = (a.toNat + b.toNat) % 2 ^ 256)

theorem bv256_mul_int_mod (a b : BitVec 256) :
    ((a.toNat : Int) * b.toNat) % (2 : Int) ^ 256 = ↑(a * b).toNat := by
  rw [BitVec.toNat_mul, ← Int.natCast_mul]
  exact_mod_cast (rfl : (a.toNat * b.toNat) % 2 ^ 256 = (a.toNat * b.toNat) % 2 ^ 256)

theorem bv256_sub_int_mod (a b : BitVec 256) :
    ((a.toNat : Int) - b.toNat) % (2 : Int) ^ 256 = ↑(a - b).toNat := by
  have ha := a.isLt
  have hb := b.isLt
  rw [BitVec.toNat_sub]
  have hpow : ((2 ^ 256 : Nat) : Int) = (2 : Int) ^ 256 := by norm_cast
  by_cases hle : b.toNat ≤ a.toNat
  · have hnat : (2 ^ 256 - b.toNat + a.toNat) % 2 ^ 256 = a.toNat - b.toNat := by omega
    rw [hnat]
    have hge : 0 ≤ (a.toNat : Int) - b.toNat := by omega
    have hlt : (a.toNat : Int) - b.toNat < (2 : Int) ^ 256 := by omega
    rw [Int.emod_eq_of_lt hge hlt]
    omega
  · have hnat : (2 ^ 256 - b.toNat + a.toNat) % 2 ^ 256 = 2 ^ 256 - b.toNat + a.toNat := by omega
    rw [hnat]
    have hshift : (a.toNat : Int) - b.toNat =
        ((a.toNat : Int) - b.toNat + (2 : Int) ^ 256) + (-1 : Int) * (2 : Int) ^ 256 := by omega
    rw [hshift, Int.add_mul_emod_self_right]
    rw [Int.emod_eq_of_lt (by omega) (by omega)]
    omega

theorem bv256_and_nat (a b : BitVec 256) : a.toNat &&& b.toNat = (a &&& b).toNat :=
  (BitVec.toNat_and a b).symm

theorem bv256_xor_nat (a b : BitVec 256) : a.toNat ^^^ b.toNat = (a ^^^ b).toNat :=
  (BitVec.toNat_xor a b).symm

theorem bv256_shr_nat (a : BitVec 256) (k : Nat) : a.toNat >>> k = (a >>> k).toNat :=
  (BitVec.toNat_ushiftRight a k).symm

theorem env_set_self (env : Control.Env Memory.Value) (id : Nat) (v : Memory.Value) :
    (Control.Env.set env id v) id = some v := by
  simp only [Control.Env.set, ↓reduceIte]

theorem env_set_ne (env : Control.Env Memory.Value) (id q : Nat) (v : Memory.Value) (hne : q ≠ id) :
    (Control.Env.set env id v) q = env q :=
  Control.Env.set_ne env id q v hne

theorem scalarEnv_of_env {env : Env} {id : Nat} {sv : Scalar.Value}
    (h : env id = some (.scalar sv)) :
    scalarEnv env id = some sv := by
  simp only [scalarEnv, h]

theorem ref_const_eval {v : Memory.Value} {env : Env} (hv : v.valid = true) :
    (MemoryAir.Ref.constant v).eval env = .ok v := by
  simp only [MemoryAir.Ref.eval, bind, Except.bind, hv, ↓reduceIte]

theorem ref_local_eval {id : Nat} {v : Memory.Value} {env : Env}
    (hl : env id = some v) (hv : v.valid = true) :
    (MemoryAir.Ref.local id).eval env = .ok v := by
  simp only [MemoryAir.Ref.eval, bind, Except.bind, hl, hv, ↓reduceIte]

theorem scalar_ref_const_eval {sv : Scalar.Value} {env : Scalar.Env} (hv : sv.valid = true) :
    (Scalar.Ref.constant sv).eval env = .ok sv := by
  simp only [Scalar.Ref.eval, hv, ↓reduceIte]

theorem scalar_ref_local_eval {id : Nat} {sv : Scalar.Value} {env : Scalar.Env}
    (hl : env id = some sv) (hv : sv.valid = true) :
    (Scalar.Ref.local id).eval env = .ok sv := by
  simp only [Scalar.Ref.eval, hl, hv, ↓reduceIte]

theorem scalar_arith_eval {op : Scalar.Arithmetic} {mode : Scalar.Overflow} {left right : Scalar.Ref}
    {args : List Scalar.Value} {env : Scalar.Env} {s : Bool} {w : Nat} {x y : Int} {v : Scalar.Value}
    (hl : left.eval env = .ok (.int s w x))
    (hr : right.eval env = .ok (.int s w y))
    (hi : Scalar.integer s w (op.eval x y) mode = .ok v) :
    (Scalar.Prim.arithmetic op mode left right).eval args env = .ok v := by
  simp [Scalar.Prim.eval, hl, hr, hi, bind, Except.bind]

theorem scalar_cmp_eval {op : Scalar.Comparison} {left right : Scalar.Ref}
    {args : List Scalar.Value} {env : Scalar.Env} {s : Bool} {w : Nat} {x y : Int} {b : Bool}
    (hl : left.eval env = .ok (.int s w x))
    (hr : right.eval env = .ok (.int s w y))
    (hb : op.eval x y = b) :
    (Scalar.Prim.comparison op left right).eval args env = .ok (.bool b) := by
  simp [Scalar.Prim.eval, hl, hr, hb, bind, Except.bind]

theorem scalar_cast_unchecked_eval {operand : Scalar.Ref} {args : List Scalar.Value} {env : Scalar.Env}
    {s t : Bool} {n m : Nat} {x : Int} {v : Scalar.Value}
    (ho : operand.eval env = .ok (.int s n x))
    (hi : Scalar.integer t m x .unchecked = .ok v) :
    (Scalar.Prim.cast .unchecked (.int t m) operand).eval args env = .ok v := by
  simp [Scalar.Prim.eval, ho, hi, bind, Except.bind]

theorem scalar_extremum_eval {maximum : Bool} {left right : Scalar.Ref}
    {args : List Scalar.Value} {env : Scalar.Env} {s : Bool} {w : Nat} {x y : Int}
    (hl : left.eval env = .ok (.int s w x))
    (hr : right.eval env = .ok (.int s w y)) :
    (Scalar.Prim.extremum maximum left right).eval args env =
      .ok (.int s w (if maximum then max x y else min x y)) := by
  simp [Scalar.Prim.eval, hl, hr, bind, Except.bind]

theorem scalar_bitXor_eval {left right : Scalar.Ref} {args : List Scalar.Value} {env : Scalar.Env}
    {x y n : Nat}
    (hx : left.eval env = .ok (.int false n x))
    (hy : right.eval env = .ok (.int false n y)) :
    (Scalar.Prim.bitXor left right).eval args env = .ok (.int false n ↑(x ^^^ y)) := by
  simp [Scalar.Prim.eval, hx, hy, bind, Except.bind]

theorem scalar_bitXor256_eval {left right : Scalar.Ref} {args : List Scalar.Value} {env : Scalar.Env}
    {x y : BitVec 256}
    (hx : left.eval env = .ok (.int false 256 x.toNat))
    (hy : right.eval env = .ok (.int false 256 y.toNat)) :
    (Scalar.Prim.bitXor left right).eval args env = .ok (.int false 256 (x ^^^ y).toNat) := by
  have h := scalar_bitXor_eval (left := left) (right := right) (args := args) (env := env) hx hy
  rwa [bv256_xor_nat] at h

theorem scalar_bitAnd256_eval {left right : Scalar.Ref} {args : List Scalar.Value} {env : Scalar.Env}
    {x : BitVec 256} {y : Nat}
    (hx : left.eval env = .ok (.int false 256 x.toNat))
    (hy : right.eval env = .ok (.int false 256 y))
    (hy_lt : y < 2 ^ 256) :
    (Scalar.Prim.bitAnd left right).eval args env = .ok (.int false 256 (x &&& BitVec.ofNat 256 y).toNat) := by
  have h := Scalar.bitAnd_eval left right args env x.toNat y 256 hx hy
  have hbv : (x &&& BitVec.ofNat 256 y).toNat = x.toNat &&& y := by
    rw [BitVec.toNat_and, BitVec.toNat_ofNat, Nat.mod_eq_of_lt hy_lt]
  rwa [← hbv] at h

theorem scalar_bitAnd256_255_eval {left : Scalar.Ref} {args : List Scalar.Value} {env : Scalar.Env}
    {x : BitVec 256}
    (hx : left.eval env = .ok (.int false 256 x.toNat)) :
    (Scalar.Prim.bitAnd left (.constant (.int false 256 255))).eval args env =
      .ok (.int false 256 (x &&& 0xFF).toNat) := by
  have hv : (Scalar.Value.int false 256 255).valid = true := Scalar.unsigned_nat_valid 255 256 (by omega)
  have h := Scalar.bitAnd_eval left (.constant (.int false 256 255)) args env x.toNat 255 256 hx
    (scalar_ref_const_eval hv)
  have hbv : (x &&& (0xFF : BitVec 256)).toNat = x.toNat &&& 255 := by
    rw [BitVec.toNat_and]; rfl
  rwa [← hbv] at h

theorem scalar_shiftRight256_255_eval {left : Scalar.Ref} {args : List Scalar.Value} {env : Scalar.Env}
    {x : BitVec 256}
    (hx : left.eval env = .ok (.int false 256 x.toNat)) :
    (Scalar.Prim.shiftRight left (.constant (.int false 8 255))).eval args env =
      .ok (.int false 256 (x >>> 255).toNat) := by
  have hv : (Scalar.Value.int false 8 255).valid = true := Scalar.unsigned_nat_valid 255 8 (by omega)
  have h := Scalar.shiftRight_eval left (.constant (.int false 8 255)) args env x.toNat 255 256 hx
    (scalar_ref_const_eval hv) (by omega)
  rwa [bv256_shr_nat] at h

theorem scalar_shiftRight256_eval {left right : Scalar.Ref} {args : List Scalar.Value} {env : Scalar.Env}
    {x : BitVec 256} (k : Nat)
    (hx : left.eval env = .ok (.int false 256 x.toNat))
    (hk : right.eval env = .ok (.int false 8 k))
    (bound : k < 256) :
    (Scalar.Prim.shiftRight left right).eval args env = .ok (.int false 256 (x >>> k).toNat) := by
  have h := Scalar.shiftRight_eval left right args env x.toNat k 256 hx hk bound
  rwa [bv256_shr_nat] at h

theorem prim_arg_eval {i : Nat} {args : List Memory.Value} {env : Env} {state : State} {v : Memory.Value}
    (ha : args[i]? = some v) :
    (MemoryAir.Prim.argument i).eval args env state = (.ok v, state) := by
  simp only [MemoryAir.Prim.eval, MemoryAir.Prim.transition, ha, bind, Except.bind]

theorem prim_load_eval {ptr : MemoryAir.Ref} {args : List Memory.Value} {env : Env} {state : State}
    {pv v : Memory.Value}
    (hp : ptr.eval env = .ok pv)
    (hl : Memory.load state pv = .ok v) :
    (MemoryAir.Prim.load ptr).eval args env state = (.ok v, state) := by
  simp only [MemoryAir.Prim.eval, MemoryAir.Prim.transition, hp, hl, bind, Except.bind]

theorem prim_store_eval {ptr val : MemoryAir.Ref} {args : List Memory.Value} {env : Env}
    {state after : State} {pv vv : Memory.Value}
    (hp : ptr.eval env = .ok pv)
    (hv : val.eval env = .ok vv)
    (hs : Memory.store state pv vv = .ok after) :
    (MemoryAir.Prim.store ptr val).eval args env state = (.ok (.scalar .unit), after) := by
  simp only [MemoryAir.Prim.eval, MemoryAir.Prim.transition, hp, hv, hs, bind, Except.bind]

theorem prim_alloc_eval {child : Memory.Ty} {args : List Memory.Value} {env : Env}
    {state after : State} {pv : Memory.Value}
    (ha : Memory.allocate state child = .ok (pv, after)) :
    (MemoryAir.Prim.alloc child).eval args env state = (.ok pv, after) := by
  simp only [MemoryAir.Prim.eval, MemoryAir.Prim.transition, ha]

theorem prim_pointerCast_eval {target : Memory.Ty} {ptr : MemoryAir.Ref} {args : List Memory.Value}
    {env : Env} {state : State} {pv rv : Memory.Value}
    (hp : ptr.eval env = .ok pv)
    (hc : Memory.pointerCast state target pv = .ok rv) :
    (MemoryAir.Prim.pointerCast target ptr).eval args env state = (.ok rv, state) := by
  simp only [MemoryAir.Prim.eval, MemoryAir.Prim.transition, hp, hc, bind, Except.bind]

theorem prim_elementPointer_eval {ptr idx : MemoryAir.Ref} {args : List Memory.Value}
    {env : Env} {state : State} {pv rv : Memory.Value} {k : Nat}
    (hp : ptr.eval env = .ok pv)
    (hi : idx.natural env = .ok k)
    (he : Memory.elementPointer state pv k = .ok rv) :
    (MemoryAir.Prim.elementPointer ptr idx).eval args env state = (.ok rv, state) := by
  simp only [MemoryAir.Prim.eval, MemoryAir.Prim.transition, hp, hi, he, bind, Except.bind]

theorem ref_natural_const (k : Nat) {env : Env} (hk : k < 2 ^ 64) :
    (MemoryAir.Ref.constant (.scalar (.int false 64 k))).natural env = .ok k := by
  have hv := mem_scalar_valid (Scalar.unsigned_nat_valid k 64 hk)
  unfold MemoryAir.Ref.natural
  rw [ref_const_eval hv]
  rfl

theorem ref_natural_zero {env : Env} :
    (MemoryAir.Ref.constant (.scalar (.int false 64 0))).natural env = .ok 0 :=
  ref_natural_const 0 (by omega)

theorem ref_natural_one {env : Env} :
    (MemoryAir.Ref.constant (.scalar (.int false 64 1))).natural env = .ok 1 :=
  ref_natural_const 1 (by omega)

theorem prim_scalar_eval {op : Scalar.Prim} {args : List Memory.Value} {env : Env} {state : State}
    {sv : Scalar.Value}
    (hs : op.eval [] (scalarEnv env) = .ok sv) :
    (MemoryAir.Prim.scalar op).eval args env state = (.ok (.scalar sv), state) := by
  simp only [MemoryAir.Prim.eval, MemoryAir.Prim.transition, hs, bind, Except.bind]

theorem eval_bind_ok {id : Nat} {ty : Memory.Ty} {prim : MemoryAir.Prim} {next : MemoryAir.Code}
    {args : List Memory.Value} {env : Env} {state after : State} {v : Memory.Value}
    (hp : prim.eval args env state = (.ok v, after)) (ht : v.hasType ty = true) :
    Control.Code.eval MemoryAir.semantics (.bind id ty prim next) args env state =
      Control.Code.eval MemoryAir.semantics next args (Control.Env.set env id v) after := by
  simp [Control.Code.eval, MemoryAir.semantics, hp, ht]

theorem eval_ret_ok {ref : MemoryAir.Ref} {args : List Memory.Value} {env : Env} {state : State}
    {v : Memory.Value}
    (hr : ref.eval env = .ok v) :
    Control.Code.eval MemoryAir.semantics (.ret ref) args env state = .returned v state := by
  simp [Control.Code.eval, MemoryAir.semantics, hr]

theorem eval_jump_ok {target : Nat} {ref : MemoryAir.Ref} {args : List Memory.Value} {env : Env}
    {state : State} {v : Memory.Value}
    (hr : ref.eval env = .ok v) :
    Control.Code.eval MemoryAir.semantics (.jump target ref) args env state = .jumped target v env state := by
  simp [Control.Code.eval, MemoryAir.semantics, hr]

theorem eval_branch_true {cond : MemoryAir.Ref} {t f : MemoryAir.Code} {args : List Memory.Value}
    {env : Env} {state : State}
    (hc : cond.eval env = .ok (.scalar (.bool true))) :
    Control.Code.eval MemoryAir.semantics (.branch cond t f) args env state =
      Control.Code.eval MemoryAir.semantics t args env state := by
  simp [Control.Code.eval, MemoryAir.semantics, hc]

theorem eval_branch_false {cond : MemoryAir.Ref} {t f : MemoryAir.Code} {args : List Memory.Value}
    {env : Env} {state : State}
    (hc : cond.eval env = .ok (.scalar (.bool false))) :
    Control.Code.eval MemoryAir.semantics (.branch cond t f) args env state =
      Control.Code.eval MemoryAir.semantics f args env state := by
  simp [Control.Code.eval, MemoryAir.semantics, hc]

theorem eval_block_jump_hit {label : Nat} {ty : Memory.Ty} {body next : MemoryAir.Code}
    {args : List Memory.Value} {env env' : Env} {state after : State} {v : Memory.Value}
    (hb : Control.Code.eval MemoryAir.semantics body args env state = .jumped label v env' after)
    (ht : v.hasType ty = true) :
    Control.Code.eval MemoryAir.semantics (.block label ty body next) args env state =
      Control.Code.eval MemoryAir.semantics next args (Control.Env.set env' label v) after := by
  rw [Control.Code.eval, hb]
  simp [MemoryAir.semantics, ht]

theorem eval_block_jump_miss {label target : Nat} {ty : Memory.Ty} {body next : MemoryAir.Code}
    {args : List Memory.Value} {env env' : Env} {state after : State} {v : Memory.Value}
    (hb : Control.Code.eval MemoryAir.semantics body args env state = .jumped target v env' after)
    (hne : target ≠ label) :
    Control.Code.eval MemoryAir.semantics (.block label ty body next) args env state =
      .jumped target v env' after := by
  rw [Control.Code.eval, hb]
  simp [hne]

theorem program_run_ok {p : MemoryAir.Program} {args : List Memory.Value} {state after : State}
    {r : Memory.Value}
    (hacc : p.accepts args state = true)
    (he : Control.Code.eval MemoryAir.semantics p.body args (fun _ => none) state = .returned r after)
    (hr : r.hasType p.returnType = true) :
    p.run args state = (.ok r, Memory.cleanup state.nextId after) := by
  simp [MemoryAir.Program.run, MemoryAir.Program.finish, hacc, he, hr]

theorem cleanup_same_nextId (state : State) (valid : state.valid = true) :
    Memory.cleanup state.nextId state = state := by
  cases state with
  | mk heap nextId nextAddress =>
    simp only [Memory.cleanup]
    congr 1
    simp only [Memory.State.valid, Bool.and_eq_true] at valid
    have hall := List.all_eq_true.mp valid.1.2
    exact List.filter_eq_self.mpr fun item hmem => by
      have hi := hall item hmem
      simp only [Bool.and_eq_true, decide_eq_true_eq] at hi
      simp [hi.1.1]

theorem store_preserves_nextId (state after : State) (ptr val : Memory.Value)
    (hs : Memory.store state ptr val = .ok after) : after.nextId = state.nextId := by
  rcases Memory.store_success state ptr val after hs with
    ⟨_, _, _, _, _, _, _, _, _, _, _, hEq⟩
  rw [hEq]

theorem cleanup_after_store (state after : State) (ptr val : Memory.Value)
    (hvalid : state.valid = true) (hs : Memory.store state ptr val = .ok after) :
    Memory.cleanup state.nextId after = after := by
  have hva : after.valid = true := Memory.store_preserves_valid state ptr val after hvalid hs
  have hnid : after.nextId = state.nextId := store_preserves_nextId state after ptr val hs
  rw [← hnid]
  exact cleanup_same_nextId after hva

end GuillotineZean.MemoryHelpers
