/-
  GuillotineZean.LoopHelpers

  Kernel-fast O(1) structural WP step lemmas for Zean's `Control.Verification.pre`
  and `MemoryAir.Verify.Triple`, enabling fast (<3s), zero-`sorry`, zero-blowup
  loop-invariant proofs over arbitrary Zean `loops`-profile Zig AIR programs.
-/
import GuillotineZean.MemoryHelpers
import Compiler.ZigAir.Verify.Core
import Compiler.ZigAir.MemoryStackFrame

namespace GuillotineZean.LoopHelpers
open Compiler.ZigAir Compiler.ZigAir.Memory Compiler.ZigAir.MemoryAir MemoryAir.Verify
open Control.Verification Std.WP GuillotineZean.MemoryHelpers

abbrev u8Ty : Memory.Ty := .scalar (.int false 8)
abbrev u64Ty : Memory.Ty := .scalar (.int false 64)
abbrev boolTy : Memory.Ty := .scalar .bool
abbrev unitTy : Memory.Ty := .scalar .unit

macro "env_here" : tactic =>
  `(tactic| (repeat (first | exact env_set_self .. | rw [env_set_ne _ _ _ _ (by decide)])))

macro "env_use " h:ident : tactic =>
  `(tactic| (repeat rw [env_set_ne _ _ _ _ (by decide)]; exact $h))

/-- Irreducible wrapper around `Control.Verification.pre` so Lean never eagerly
    unfolds `pre` (or `Value.valid` / `2^64` integer checks) during `refine` or `rcases`. -/
def Pre (args : List Value) (inv : Invariants)
    (code : Control.Code Memory.Ty MemoryAir.Prim MemoryAir.Ref true)
    (post : Post Value State) (errors : Errors Fault State)
    (env : Env) (state : State) : Prop :=
  pre MemoryAir.semantics args inv code post errors env state

theorem triple_of_pre {prog : Program true} {args : List Value} {invariants : Invariants}
    {initial : State} {post : Postcondition} {errors : FaultCondition}
    (hacc : prog.accepts args initial = true)
    (hpre : Pre args invariants prog.body
      (finishPost prog.returnType initial.nextId post errors)
      (fun fault after => errors fault (Memory.cleanup initial.nextId after))
      (fun _ => none) initial) :
    Triple (Verify.Invocation.mk prog args invariants)
      (fun before => before = initial) post errors := by
  constructor
  intro before hb
  subst before
  change (if prog.accepts args initial then
    Pre args invariants prog.body
      (finishPost prog.returnType initial.nextId post errors)
      (fun fault after => errors fault (Memory.cleanup initial.nextId after))
      (fun _ => none) initial
    else errors .malformed initial)
  simp only [hacc, ↓reduceIte]
  exact hpre

theorem pre_bind_eq {args : List Value} {inv : Invariants}
    {id : Nat} {ty : Memory.Ty} {prim : MemoryAir.Prim} {next : Control.Code Memory.Ty MemoryAir.Prim MemoryAir.Ref true}
    {post : Post Value State} {errors : Errors Fault State}
    {env : Env} {state after : State} {v : Value}
    (hp : prim.eval args env state = (.ok v, after))
    (ht : v.hasType ty = true) :
    Pre args inv (.bind id ty prim next) post errors env state =
      Pre args inv next post errors (Control.Env.set env id v) after := by
  simp only [Pre, pre, MemoryAir.semantics, hp, ht, ↓reduceIte]

theorem pre_branch_true_eq {args : List Value} {inv : Invariants}
    {cond : MemoryAir.Ref} {yes no : Control.Code Memory.Ty MemoryAir.Prim MemoryAir.Ref true}
    {post : Post Value State} {errors : Errors Fault State}
    {env : Env} {state : State}
    (hc : cond.eval env = .ok (.scalar (.bool true))) :
    Pre args inv (.branch cond yes no) post errors env state =
      Pre args inv yes post errors env state := by
  simp only [Pre, pre, MemoryAir.semantics, hc, ↓reduceIte]

theorem pre_branch_false_eq {args : List Value} {inv : Invariants}
    {cond : MemoryAir.Ref} {yes no : Control.Code Memory.Ty MemoryAir.Prim MemoryAir.Ref true}
    {post : Post Value State} {errors : Errors Fault State}
    {env : Env} {state : State}
    (hc : cond.eval env = .ok (.scalar (.bool false))) :
    Pre args inv (.branch cond yes no) post errors env state =
      Pre args inv no post errors env state := by
  simp only [Pre, pre, MemoryAir.semantics, hc, Bool.false_eq_true, ↓reduceIte]

theorem pre_jump_eq {args : List Value} {inv : Invariants}
    {target : Nat} {ref : MemoryAir.Ref} {post : Post Value State} {errors : Errors Fault State}
    {env : Env} {state : State} {v : Value}
    (hr : ref.eval env = .ok v) :
    Pre args inv (.jump target ref) post errors env state =
      post (.jumped target v env) state := by
  simp only [Pre, pre, MemoryAir.semantics, hr]

theorem pre_ret_eq {args : List Value} {inv : Invariants}
    {ref : MemoryAir.Ref} {post : Post Value State} {errors : Errors Fault State}
    {env : Env} {state : State} {v : Value}
    (hr : ref.eval env = .ok v) :
    Pre args inv (.ret ref) post errors env state =
      post (.returned v) state := by
  simp only [Pre, pre, MemoryAir.semantics, hr]

theorem pre_block_eq {args : List Value} {inv : Invariants}
    {id : Nat} {ty : Memory.Ty} {body next : Control.Code Memory.Ty MemoryAir.Prim MemoryAir.Ref true}
    {post : Post Value State} {errors : Errors Fault State}
    {env : Env} {state : State} :
    Pre args inv (.block id ty body next) post errors env state =
      Pre args inv body (blockPost MemoryAir.semantics id ty (Pre args inv next post errors) post errors) errors env state := rfl

theorem pre_loop_eq {args : List Value} {inv : Invariants}
    {id : Nat} {body : Control.Code Memory.Ty MemoryAir.Prim MemoryAir.Ref true}
    {post : Post Value State} {errors : Errors Fault State}
    {env : Env} {state : State} :
    Pre args inv (.loop rfl id body) post errors env state =
      (inv id env state ∧ ∀ other heap, inv id other heap →
        Pre args inv body (loopPost MemoryAir.semantics id (inv id) post errors) errors other heap) := rfl

theorem pre_repeat_eq {args : List Value} {inv : Invariants}
    {id : Nat} {post : Post Value State} {errors : Errors Fault State}
    {env : Env} {state : State} :
    Pre args inv (.repeat rfl id) post errors env state =
      post (.repeated id env) state := rfl

theorem pre_bind_alloc {args : List Value} {inv : Invariants}
    {id : Nat} {child : Memory.Ty} {layout : Layout}
    {next : Control.Code Memory.Ty MemoryAir.Prim MemoryAir.Ref true}
    {post : Post Value State} {errors : Errors Fault State}
    {env : Env} {state : State}
    (hvalid : state.valid = true)
    (hlayout : child.layout = some layout)
    (hoom : errors .outOfMemory state)
    (hok : ∀ (after : State),
      Memory.allocate state child = .ok (Value.pointer (.pointer true false child) ⟨state.nextId, 0⟩, after) →
      after.valid = true →
      StackFrame state after →
      Pre args inv next post errors
        (Control.Env.set env id (Value.pointer (.pointer true false child) ⟨state.nextId, 0⟩)) after) :
    Pre args inv (.bind id (.pointer true false child) (.alloc child) next) post errors env state := by
  simp only [Pre, pre, MemoryAir.semantics, MemoryAir.Prim.eval, MemoryAir.Prim.transition]
  cases halloc : Memory.allocate state child with
  | error fault =>
    have hfault : fault = .outOfMemory := Memory.allocate_fault_of_layout state child layout fault hvalid hlayout halloc
    subst hfault
    exact hoom
  | ok res =>
    rcases res with ⟨ptr, after⟩
    have hptr : ptr = Value.pointer (.pointer true false child) ⟨state.nextId, 0⟩ := by
      unfold Memory.allocate at halloc
      simp only [hvalid, hlayout, Bool.not_true, Bool.false_eq_true, ↓reduceIte] at halloc
      split at halloc
      · cases halloc
      · cases halloc; rfl
    subst hptr
    have ht : (Value.pointer (.pointer true false child) ⟨state.nextId, 0⟩).hasType (.pointer true false child) = true := by
      simp [Memory.Value.hasType, Memory.Value.type, Memory.Value.valid]
    have hva : after.valid = true := Memory.allocate_preserves_valid state child _ after halloc
    have hsf : StackFrame state after := (StackFrame.refl state hvalid).allocate child _ after halloc
    simp only [ht, ↓reduceIte]
    exact hok after halloc hva hsf

attribute [irreducible] Pre

theorem blockPost_hit {id : Nat} {ty : Memory.Ty} {next : Assertion Value State}
    {post : Post Value State} {errors : Errors Fault State}
    {v : Value} {env : Env} {state : State}
    (ht : v.hasType ty = true) (hn : next (Control.Env.set env id v) state) :
    blockPost MemoryAir.semantics id ty next post errors (.jumped id v env) state := by
  simp only [blockPost, MemoryAir.semantics, ht, ↓reduceIte]
  exact hn

theorem blockPost_miss {id target : Nat} {ty : Memory.Ty} {next : Assertion Value State}
    {post : Post Value State} {errors : Errors Fault State}
    {v : Value} {env : Env} {state : State}
    (hne : target ≠ id) (hp : post (.jumped target v env) state) :
    blockPost MemoryAir.semantics id ty next post errors (.jumped target v env) state := by
  simp only [blockPost, hne, ↓reduceIte]
  exact hp

theorem loopPost_repeat_hit {id : Nat} {invA : Assertion Value State}
    {post : Post Value State} {errors : Errors Fault State}
    {env : Env} {state : State} (hi : invA env state) :
    loopPost MemoryAir.semantics id invA post errors (.repeated id env) state := by
  simp only [loopPost, ↓reduceIte]
  exact hi

theorem loopPost_jump_miss {id target : Nat} {invA : Assertion Value State}
    {post : Post Value State} {errors : Errors Fault State}
    {v : Value} {env : Env} {state : State}
    (hne : target ≠ id) (hp : post (.jumped target v env) state) :
    loopPost MemoryAir.semantics id invA post errors (.jumped target v env) state := by
  simp only [loopPost, hne, ↓reduceIte]
  exact hp

theorem finishPost_ret {ty : Memory.Ty} {mark : Nat} {post : Postcondition} {errors : FaultCondition}
    {v : Value} {state : State}
    (ht : v.hasType ty = true) (hp : post v (Memory.cleanup mark state)) :
    finishPost ty mark post errors (.returned v) state := by
  simp only [finishPost, ht, ↓reduceIte]
  exact hp

theorem scalar_bitcast_u64_eval {operand : Scalar.Ref} {args : List Scalar.Value} {env : Scalar.Env}
    {x : Nat} (hx : x < 2 ^ 64)
    (ho : operand.eval env = .ok (.int false 64 x)) :
    (Scalar.Prim.cast .bitcast (.int false 64) operand).eval args env = .ok (.int false 64 x) := by
  have hmod : (x : Int) % (2 : Int) ^ 64 = x := Int.emod_eq_of_lt (by omega) (by exact_mod_cast hx)
  simp only [Scalar.Prim.eval, ho, bind, Except.bind, ↓reduceIte, Scalar.integer, Scalar.normalize,
    Bool.false_and, Bool.false_eq_true, hmod]

theorem scalar_shiftRight64_one_eval {left : Scalar.Ref} {args : List Scalar.Value} {env : Scalar.Env}
    {x : Nat}
    (hx : left.eval env = .ok (.int false 64 x)) :
    (Scalar.Prim.shiftRight left (.constant (.int false 6 1))).eval args env =
      .ok (.int false 64 ↑(x / 2)) := by
  have hv1 : (Scalar.Value.int false 6 1).valid = true := Scalar.unsigned_nat_valid 1 6 (by omega)
  have h := Scalar.shiftRight_eval left (.constant (.int false 6 1)) args env x 1 64 hx
    (scalar_ref_const_eval hv1) (by omega)
  rwa [Scalar.shiftRight_one] at h

theorem ref_natural_local {id : Nat} {k : Nat} {env : Env}
    (hl : env id = some (.scalar (.int false 64 k))) (hk : k < 2 ^ 64) :
    (MemoryAir.Ref.local id).natural env = .ok k := by
  have hv := mem_scalar_valid (Scalar.unsigned_nat_valid k 64 hk)
  unfold MemoryAir.Ref.natural
  rw [ref_local_eval hl hv]
  rfl

theorem fresh_store_ok {state allocState : State} {child : Memory.Ty} {layout : Layout}
    {val : Value}
    (hlayout : child.layout = some layout)
    (hpos : 0 < layout.bytes)
    (hval_valid : val.valid = true)
    (hval_type : val.type = child)
    (halloc : Memory.allocate state child = .ok (.pointer (.pointer true false child) ⟨state.nextId, 0⟩, allocState)) :
    ∃ after, Memory.store allocState (.pointer (.pointer true false child) ⟨state.nextId, 0⟩) val = .ok after ∧
      after.valid = true ∧
      StackFrame state after ∧
      Memory.load after (.pointer (.pointer true false child) ⟨state.nextId, 0⟩) = .ok val := by
  have hva := Memory.allocate_preserves_valid state child _ allocState halloc
  have hv0 : state.valid = true := by
    unfold Memory.allocate at halloc
    cases h : state.valid <;> simp_all
  obtain ⟨after, hst⟩ := Memory.fresh_store_total state allocState val
    (.pointer (.pointer true false child) ⟨state.nextId, 0⟩) layout hval_valid (hval_type ▸ hlayout) hpos (hval_type ▸ halloc)
  have hsf0 : StackFrame state allocState := (StackFrame.refl state hv0).allocate child _ allocState halloc
  refine ⟨after, hst, Memory.store_preserves_valid allocState _ val after hva hst,
    hsf0.store_local true false child ⟨state.nextId, 0⟩ val after (Nat.le_refl _) hst,
    Memory.load_after_store allocState _ val after hst⟩

theorem root_cast_const_ok {state : State} {child : Memory.Ty} {layout : Layout} {id : Nat}
    (hvalid : state.valid = true)
    (hlayout : child.layout = some layout)
    (hpos : 0 < layout.bytes)
    (hcap : Memory.RootWritable state child id) :
    Memory.pointerCast state (.pointer false false child) (.pointer (.pointer true false child) ⟨id, 0⟩) =
      .ok (.pointer (.pointer false false child) ⟨id, 0⟩) := by
  obtain ⟨cell, hlu, hty, _⟩ := hcap
  obtain ⟨_, hbase, lay', hlay', halign, hbound, hlim⟩ := Memory.valid_lookup state id cell hvalid hlu
  rw [hty] at hlay'
  have hEq : lay' = layout := Option.some.inj (hlay'.symm.trans hlayout)
  subst lay'
  have hacc : Memory.access state ⟨id, 0⟩ ⟨layout.bytes, layout.alignment⟩ false = .ok cell := by
    simp only [Memory.access, hlu, hty, hlayout, Bool.false_and, Bool.false_eq_true, ↓reduceIte,
      Nat.add_zero, Nat.zero_add]
    have hchk : ¬(cell.base = 0 ∨ cell.base + layout.bytes > addressLimit ∨
        cell.base ≥ addressLimit ∨ layout.bytes > layout.bytes ∨ cell.base % layout.alignment ≠ 0) := by
      omega
    exact ite_eq_right hchk
  simp only [Memory.pointerCast, Memory.pointerCompatible, hlayout, Bool.false_and, Bool.true_or,
    Bool.not_true, Bool.false_or, Bool.false_eq_true, ↓reduceIte, hacc, bind, Except.bind, decide_true]

theorem root_load_const_of_mut {state : State} {child : Memory.Ty} {id : Nat} {v : Value}
    (h : Memory.load state (.pointer (.pointer true false child) ⟨id, 0⟩) = .ok v) :
    Memory.load state (.pointer (.pointer false false child) ⟨id, 0⟩) = .ok v := by
  simpa only [Memory.load] using h

theorem with_fresh_store {P : Prop} {state allocState : State} {child : Memory.Ty} {layout : Layout}
    {val : Value}
    (hlayout : child.layout = some layout)
    (hpos : 0 < layout.bytes)
    (hval_valid : val.valid = true)
    (hval_type : val.type = child)
    (halloc : Memory.allocate state child = .ok (.pointer (.pointer true false child) ⟨state.nextId, 0⟩, allocState))
    (k : ∀ after,
      Memory.store allocState (.pointer (.pointer true false child) ⟨state.nextId, 0⟩) val = .ok after →
      after.valid = true →
      StackFrame state after →
      Memory.load after (.pointer (.pointer true false child) ⟨state.nextId, 0⟩) = .ok val → P) : P := by
  obtain ⟨after, hst, hva, hsf, hld⟩ := fresh_store_ok hlayout hpos hval_valid hval_type halloc
  exact k after hst hva hsf hld

theorem with_root_store {P : Prop} {state : State} {type : Memory.Ty} {id : Nat}
    {value : Value} {layout : Layout}
    (valid : state.valid = true)
    (cap : Memory.RootWritable state type id)
    (typed : value.hasType type = true)
    (shaped : type.layout = some layout)
    (positive : 0 < layout.bytes)
    (k : ∀ after, Memory.store state (.pointer (.pointer true false type) ⟨id, 0⟩) value = .ok after → P) : P := by
  obtain ⟨after, hst⟩ := cap.store_total state type id value layout valid typed shaped positive
  exact k after hst

end GuillotineZean.LoopHelpers
