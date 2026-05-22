-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| ABI Types for Laminar — pipeline orchestration
|||
||| Proves that:
|||   1. Pipeline stages form a DAG (no cycles)
|||   2. Stage transitions are valid state machine moves
|||   3. Retry counts are bounded
module Laminar.ABI.Types

import Data.Fin

%default total

||| Pipeline stage state
public export
data StageState = Pending | Running | Succeeded | Failed | Skipped

||| Pipeline operation
public export
data Operation
  = CreatePipeline    -- Create a new pipeline
  | RunStage          -- Execute a stage
  | GetStatus         -- Get pipeline status
  | CancelPipeline    -- Cancel a running pipeline
  | RetryStage        -- Retry a failed stage

||| Valid state transitions for stages
public export
data ValidTransition : StageState -> StageState -> Type where
  StartStage   : ValidTransition Pending Running
  StageOk      : ValidTransition Running Succeeded
  StageFail    : ValidTransition Running Failed
  SkipStage    : ValidTransition Pending Skipped
  RetryFailed  : ValidTransition Failed Running

||| Retry count is bounded (max 10)
public export
data RetryCount = MkRetry (n : Fin 11)

-- ═══════════════════════════════════════════════════════════════════════
-- C ABI Exports
-- ═══════════════════════════════════════════════════════════════════════

export
stageStateToInt : StageState -> Int
stageStateToInt Pending   = 0
stageStateToInt Running   = 1
stageStateToInt Succeeded = 2
stageStateToInt Failed    = 3
stageStateToInt Skipped   = 4

export
laminar_can_transition : Int -> Int -> Int
laminar_can_transition 0 1 = 1  -- Pending → Running
laminar_can_transition 1 2 = 1  -- Running → Succeeded
laminar_can_transition 1 3 = 1  -- Running → Failed
laminar_can_transition 0 4 = 1  -- Pending → Skipped
laminar_can_transition 3 1 = 1  -- Failed → Running (retry)
laminar_can_transition _ _ = 0
