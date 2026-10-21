# Ralph Wiggum Loop - Specification & Review Quality Checklist

## 1. Specification Readiness (Pre-Loop)
- [ ] Requirements are unambiguous, measurable, and testable
- [ ] Acceptance criteria define observable outcomes (no `[NEEDS CLARIFICATION]` placeholders)
- [ ] Edge cases, error conditions, and failure modes are explicitly listed
- [ ] `maxIterations` / `--max-iterations` escape hatch is configured (e.g., `5`-`20`)
- [ ] Worker and Reviewer models/providers are distinct (`crossModelReviewEnforced: true`)

---

## 2. Worker Submission Checklist (`ralph_loop_submit_work`)

Before calling `ralph_loop_submit_work`, verify:
- [ ] Current task (`ralph_loop_get_task`) and all prior Reviewer feedback (`ralph_loop_get_feedback`) have been addressed
- [ ] All unit, integration, and regression tests have been executed and pass
- [ ] Linter, typecheck, and build checks pass with zero errors
- [ ] No debug artifacts, hardcoded secrets, or unintended file edits remain
- [ ] `work` and `summary` clearly document all modified files and how each acceptance criterion was verified

### `ralph_loop_submit_work` Tool Call Contract
- **Tool Name:** `ralph_loop_submit_work`
- **Required Arguments:** `work` (string), `summary` (string), `iteration` (integer)
- **Optional Arguments:** `sessionId` / `session_id` (string, default: `"default"`)
- **Example Payload (`tools/call`):**
  ```json
  {
    "name": "ralph_loop_submit_work",
    "arguments": {
      "sessionId": "default",
      "iteration": 1,
      "summary": "Implemented JWT token refresh with concurrency lock and added unit tests.",
      "work": "Modified src/auth.ts and tests/auth.test.ts. All 18 tests passing."
    }
  }
  ```

---

## 3. Reviewer Verification Checklist (`ralph_loop_submit_review`)

Before calling `ralph_loop_submit_review`, retrieve the Worker submission via `ralph_loop_get_work` and verify:
- [ ] Every acceptance criterion in the task/specification is 100% satisfied
- [ ] Security, input validation, error handling, and boundary conditions are properly handled
- [ ] Automated tests cover both happy-path and failure/edge cases
- [ ] No regressions or architectural violations were introduced
- [ ] Decision is `SHIP` **only** if all criteria and tests pass; otherwise `REVISE` with specific, actionable file/line feedback

### `ralph_loop_submit_review` Tool Call Contract
- **Tool Name:** `ralph_loop_submit_review`
- **Required Arguments:** `decision` (`"SHIP"` or `"REVISE"`), `iteration` (integer)
- **Conditional Arguments:** `feedback` (string, required when `decision` is `"REVISE"`)
- **Optional Arguments:** `sessionId` / `session_id` (string, default: `"default"`)
- **Example Payload (`tools/call`):**
  ```json
  {
    "name": "ralph_loop_submit_review",
    "arguments": {
      "sessionId": "default",
      "iteration": 1,
      "decision": "SHIP",
      "feedback": "All acceptance criteria and unit tests verified."
    }
  }
  ```
