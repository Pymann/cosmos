# 113 — Version incompatibility: a magenta step

Status: decided 2026-11-26.  The language side is aiml `spec/68` §7.2 (the pins and the
`version-mismatch` line) and aiml `spec/62` F62-47/F62-48 (magenta, the set of colours).  This
chapter says what cosmos does with them.

## 113.1 Why

A tool pins the aiml it is built with, and the neighbours it works with, in its build
configuration (aiml `spec/68` F68-95).  `aiml build` checks the pins before compiling and writes
one line per mismatch, then builds on (F68-99): a stale pin is information, not breakage.  In a
pipeline that line scrolls past in a log nobody reads while the step is green.  The person who
maintains the pin needs to see it in the run itself, without it turning the run red.

## 113.2 Where the signal comes from

- **F113-1** The signal is the line, not an exit code.  A step whose output — stdout or stderr —
  contains `aiml: version-mismatch ` is marked **magenta**.  The form of the line is aiml's
  (F68-99); cosmos only recognises it, so `exodus build` (F68-100) and any other tool that writes
  the same line count the same way.
- **F113-2** The server looks, not the agent.  The output is already in the run store (doc/spec/90
  §AP1.5a); when the step is reported (`report_step`), the server scans both streams of that step
  in windows (never the whole file in memory) for the line.  No field is added to the agent's
  report, so an agent that is older than the server marks correctly too (doc/spec/103 §103.4d).
- **F113-3** Only an accepted report marks.  A report the server refuses (expired lease, foreign
  step, F103-4) is not the step's outcome and leaves no mark.

## 113.3 Where it is kept

- **F113-4** Marks live **beside** the run, in their own KV (`stage_marks`: run id → the marks of
  that run's steps), for the reason the layers and times do (doc/spec/107 §107.1c): a new field on
  `PipelineRun` or `PipelineStage` would change the schema fingerprint and make every stored run
  unreadable (doc/spec/108 F108-2).
- **F113-5** A mark is a **set of colours per step**, keyed by `stage_id`.  Marking the same colour
  twice changes nothing.  A step that runs again (F101-7) keeps its marks until the new attempt is
  reported: the mark belongs to the step's last accepted outcome, and a new attempt that no longer
  writes the line clears magenta.
- **F113-6** The marks travel in the **same snapshot** as the runs (`ClusterView.marks`), like
  layers and times — a second read channel would be the second source doc/spec/104 §104.0 warns
  about.

## 113.4 How it is shown

- **F113-7** The step's own colour stays what it was (done, failed, running); magenta is shown
  **in addition**: in the pipeline scene as a small magenta ball above the step and `[version]`
  after its label.  A failed step with a version mismatch is red with a magenta badge: both facts
  are true, and neither may hide the other (aiml spec/62 F62-48).
- **F113-8** A run shows the set of colours its steps carry next to its outcome: a run that is
  green and had one magenta step is shown green **and** magenta (in the run list, a magenta ring
  around the outcome dot).  The aggregate outcome is
  unchanged — a version mismatch never fails a run by itself.

## 113.5 What this is not

- Not a gate.  Turning a mismatch into a failure is a decision of the pipeline (a step body may
  call `fail_lane`, aiml spec/62 F62-45), not of cosmos.
- Not a general colour model.  The other five colours of aiml spec/62 F62-42 are still open
  (§16 item 6); this chapter fixes magenta only, and the store of F113-4 is ready for more.

Tests: `test/test_stage_marks.aiml` — the scan finds the line across a window boundary and in
either stream, ignores a near miss, marking twice keeps one colour, a re-run without the line clears
it, the run's colour set is the union of its steps, the scene keeps the outcome colour and adds the
badge.
