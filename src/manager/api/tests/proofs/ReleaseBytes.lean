import ReleaseIR

/- [PACKAGE-HOSTED-PUBLISH-FLOW] Run the hosted API's compiled predicates on
   every possible byte. A fault, timeout, or wrong result falsifies the theorem. -/
namespace ReleaseBytes
open LlvmSubset

def result (symbol : Nat) (byte : Fin 256) : Option Val :=
  ((runFn ReleaseIR.module 16 symbol [.int byte.val] St.empty).toOption).map Prod.fst

def bit (p : Bool) : Option Val := some (.int (if p then 1 else 0))

set_option maxRecDepth 8192
set_option maxHeartbeats 4000000

theorem repositoryDigit : ∀ b : Fin 256,
    result ReleaseIR.«__osp_8x7265676973747279_5x4279746573_7x69734469676974(i64)» b =
      bit (48 ≤ b.val && b.val ≤ 57) := by decide +kernel

theorem commitHex : ∀ b : Fin 256,
    result ReleaseIR.«__osp_8x7265676973747279_5x4279746573_13x6c6f7765724865784469676974(i64)» b =
      bit ((48 ≤ b.val && b.val ≤ 57) || (97 ≤ b.val && b.val ≤ 102)) := by decide +kernel

def lower (b : Fin 256) := 97 ≤ b.val && b.val ≤ 122
def upper (b : Fin 256) := 65 ≤ b.val && b.val ≤ 90
def decimal (b : Fin 256) := 48 ≤ b.val && b.val ≤ 57

theorem lowercase : ∀ b : Fin 256,
    result ReleaseIR.«__osp_8x7265676973747279_5x4279746573_7x69734c6f776572(i64)» b =
      bit (lower b) := by decide +kernel

theorem letter : ∀ b : Fin 256,
    result ReleaseIR.«__osp_8x7265676973747279_5x4279746573_8x69734c6574746572(i64)» b =
      bit (lower b || upper b) := by decide +kernel

theorem subdirectoryAlphanumeric : ∀ b : Fin 256,
    result ReleaseIR.«__osp_8x7265676973747279_5x4279746573_12x69734c6f7765724469676974(i64)» b =
      bit (lower b || decimal b) := by decide +kernel

theorem branchAlphanumeric : ∀ b : Fin 256,
    result ReleaseIR.«__osp_8x7265676973747279_5x4279746573_7x6973416c6e756d(i64)» b =
      bit (lower b || upper b || decimal b) := by decide +kernel

end ReleaseBytes
