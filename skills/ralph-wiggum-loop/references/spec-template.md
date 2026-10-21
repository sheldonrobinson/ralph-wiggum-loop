# Specification: [FEATURE_NAME]

## Overview
[Brief description of the feature or fix — what it does and why it matters]

## User Stories
- As a [user type], I want to [action] so that [benefit]

---

## Functional Requirements

### FR-1: [Requirement Name]
[Description of the requirement]

**Acceptance Criteria:**
- [ ] [Specific, testable criterion]
- [ ] [Specific, testable criterion]

### FR-2: [Requirement Name]
[Description of the requirement]

**Acceptance Criteria:**
- [ ] [Specific, testable criterion]
- [ ] [Specific, testable criterion]

---

## Backpressure & Testing Requirements

The Worker MUST verify all applicable items before submitting work (`ralph_loop_submit_work`) or outputting the completion signal, and the Reviewer MUST verify them before issuing `SHIP` (`ralph_loop_submit_review`):

### Code Quality
- [ ] All existing unit and integration tests pass
- [ ] New tests added for new or fixed functionality
- [ ] Zero linter or static-analysis errors

### Functional Verification
- [ ] All acceptance criteria verified
- [ ] Edge cases and error conditions handled
- [ ] No regressions introduced

---

## Iteration & Completion Protocol

If ANY check fails during an iteration:
1. Identify the root cause from test output or Reviewer feedback (`ralph_loop_get_feedback`)
2. Implement the fix
3. Re-run the test suite and verification checks
4. Submit updated work (`ralph_loop_submit_work`)

**Completion Signal:**
- **MCP Reviewer Mode:** Reviewer submits `decision: "SHIP"` via `ralph_loop_submit_review`
- **In-Session Stop-Hook Mode:** Output `<promise>DONE</promise>` ONLY when every acceptance criterion and test requirement is 100% satisfied
