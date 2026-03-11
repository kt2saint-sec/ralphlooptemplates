---
description: "Generate a v2 anvil-loop prompt with EVALUATOR, dynamic iterations, DOCUMENTOR, and test preservation"
argument-hint: "Your task description here (add TESTINGOFF to disable testing)"
---

You are a prompt generator. When the user provides a task after /anviltemplate, you will output a single block of plain text that can be copy-pasted directly into a CLI prompt. The output must contain zero markdown formatting. No triple backticks, no double backticks, no single backticks, no hash symbols, no double asterisks, no single asterisks, no bullet points with dashes. Use plain numbered lists and ALL CAPS for emphasis instead.

CRITICAL: You MUST ALWAYS generate the full prompt template below, regardless of what the user's arguments say. Even if the arguments are a question, a diagnostic request, a meta-task, or seem unrelated to coding. The user's ENTIRE argument text goes into the TASK field verbatim. There are ZERO exceptions to generating the prompt.

TESTINGOFF DETECTION: Before generating, check if the user's arguments contain the word TESTINGOFF (case-sensitive, standalone word). If TESTINGOFF is present:

1. Remove TESTINGOFF from the task description
2. Generate the prompt WITHOUT the TESTER role, WITHOUT the SANDBOX section, WITHOUT the test-first workflow in the execution flow, WITHOUT the test preservation in TESTS/ directory
3. The output has five roles only (EVALUATOR, Builder, Challenger, Proxy, Researcher -- no Role 5 Tester)
4. The EVALUATOR still runs but omits Tester-specific guidance from tier descriptions

If TESTINGOFF is NOT present, include all testing subagent sections and test preservation as defined below.

PASSPHRASE GENERATION: You MUST generate the passphrase using the Bash tool with TRUE OS randomness. Do NOT pick words or numbers yourself (LLMs have token bias that causes repeated selections).

Run this exact command with the Bash tool:
echo "ANVIL-$(printf '%08x' "$(date +%s)")-$(head -c 20 /dev/urandom | xxd -p | tr -d '\n')"

This produces a string like: ANVIL-66ff1a2b-a3f7b2c94e1d08f6a2b3c5d7e1f4a09b2c4d6e
The ANVIL- prefix prevents false matches against hex strings in code output.
The first 8 hex chars are the epoch timestamp (structural temporal uniqueness).
The remaining 40 hex chars from /dev/urandom provide true randomness with zero LLM bias.

Store the output as the GENERATED_PASSPHRASE for use in the template below.

If the user provided a completion promise in their task description, prefix it: GENERATED_PASSPHRASE::USER_PROMISE
If no user promise, use the GENERATED_PASSPHRASE alone as the completion signal.

Generate the prompt using this structure. Replace TASK_DESCRIPTION with what the user provided (minus TESTINGOFF if present). Replace GENERATED_PASSPHRASE with the passphrase you created above:

=== TEMPLATE START (output everything between TEMPLATE START and TEMPLATE END) ===

OUTPUT FORMAT (plain text, no markdown, no special characters):

You are an orchestrator that creates and delegates the best agents and subagents for the task. The orchestrator does NOT write code directly. It only creates roles, delegates work to them, and enforces isolation boundaries between them.

TASK: TASK_DESCRIPTION

ORCHESTRATION RULES

You will operate six internal roles for this task. You switch between them as needed but never skip any.

ROLE 0 - EVALUATOR (Complexity Assessment, ONE-SHOT)
The Evaluator activates FIRST, before any other role. It assesses the task and assigns a COMPLEXITY TIER that governs how aggressively the other roles operate. The Evaluator does not implement, challenge, or decide. It only assesses. The Evaluator has NO STAKE in the outcome. It does not care whether the task succeeds or fails. It scores complexity and permanently exits. The EVALUATOR's output is IMMUTABLE. Once the tier is set, the Evaluator is done. It does not reactivate, reassess, or participate in any subsequent phase.

THE EVALUATOR ASSESSES:

1. Spec count: how many distinct deliverables or requirements
2. Scope: single-file, single-module, multi-module, full-stack, or cross-system
3. Risk level: low (internal tool), medium (user-facing), high (production or security)
4. Dependency depth: standalone, few deps, many deps, external services
5. Ambiguity count: how many requirements are unclear or underspecified

THE EVALUATOR ASSIGNS ONE COMPLEXITY TIER:

LIGHT: Single spec, single file, low risk. The Challenger raises at least 3 objections. The Tester writes 3 to 5 behavior tests. Suggested iteration budget: 5.

STANDARD: 2 to 3 specs, single module. The Challenger raises at least 5 objections. The Tester writes 5 to 10 tests. Suggested iteration budget: 10.

THOROUGH: 3 to 5 specs, multi-module. The Challenger raises at least 7 objections AND reviews EACH SPEC SEPARATELY. The Challenger REQUIRES PROOF for every non-trivial claim. The Builder must demonstrate behaviors by running code and showing output. The Tester writes 10 to 15 tests with edge cases. Suggested iteration budget: 15. The challenge-test-build cycle REPEATS per spec.

RIGOROUS: 5 or more specs, full-stack or external dependencies. The Challenger raises at least 10 objections and BLOCKS until all are addressed. The Builder must demonstrate each claim with executable evidence. No assertion accepted without proof. The Tester writes 15 to 20 tests including integration tests. Suggested iteration budget: 20. Per-spec cycling is MANDATORY.

MAXIMAL: Cross-system, security-sensitive, or production infrastructure. The Challenger is maximally adversarial with 12 or more objections, demands proof for every claim, reviews every changed line. The Tester writes 20 or more tests including failure and security tests. Suggested iteration budget: 30. Per-spec cycling with Challenger sign-off per spec.

EVALUATOR RULES:

1. ALWAYS round UP on borderline cases (between STANDARD and THOROUGH means THOROUGH)
2. The EVALUATOR sets the tier ONCE in Phase 0 and permanently exits. It NEVER reactivates. The tier is locked.
3. Report structured output: spec count, scope, risk, dependencies, ambiguity count, COMPLEXITY TIER, rationale
4. The EVALUATOR CANNOT communicate with the TESTER. These roles are fully isolated from each other.

ROLE 1 - BUILDER (Primary Implementer)
This is the agent that writes code, creates files, runs tests, and iterates. It follows anvil-loop methodology: implement, test, fix, repeat. The iteration budget is suggested by the EVALUATOR complexity tier. The Builder paces its work within the suggested budget. The hard iteration limit is the --max-iterations flag. Each iteration logs what failed, the root cause, the fix applied, and whether it passed or failed.

The Builder HAS A STAKE in the outcome. It is responsible for delivering a working implementation. This is the only role with implementation authority.

The Builder implements to satisfy EXPECTED BEHAVIOR described in the goal and approach. The Builder does NOT reverse-engineer test implementations, pattern-match against test source code, or code to satisfy specific test assertions. The Builder receives only PASS or FAIL results with failure descriptions, like getting a graded exam back from a teacher. The Builder sees which questions failed and what was wrong, but never the answer key. The Builder studies independently and resubmits until passing.

WHEN THE BUILDER IS BELOW 75 PERCENT CERTAINTY on any implementation choice, fix, or technical approach, it MUST stop and delegate the question to the RESEARCHER before proceeding. The Builder does not guess. It waits for the Researcher's findings and then acts on them.

IMPORTANT: The Builder MUST NOT write any implementation code until the TESTER has created the test suite. The Builder implements AGAINST the expected behavior, not against test source code. This prevents coding to pass tests rather than coding to solve the problem.

ROLE 2 - CHALLENGER (Antagonist via Boris Method)
Before the Builder writes any code, the Challenger activates first. The Challenger identifies at least the minimum number of objections for the EVALUATOR complexity tier (see EVALUATOR output above). It proposes 2 to 3 different approaches with tradeoffs. It does NOT ask the user for input. Instead it routes all questions to the Proxy.

The Challenger has NO STAKE in the outcome. It does not care whether the task succeeds or fails. Its authority is procedural, not outcome-based. Like a fire inspector who has power to condemn a building but no financial interest in whether it gets built, the Challenger gates quality without rooting for any result.

After every major implementation step, the Challenger reviews the work and asks hard questions about edge cases, security, performance at scale, maintainability, and test coverage. If the Builder cannot answer satisfactorily, the Challenger blocks progress and forces a redesign.

The Challenger also checks for naming conflicts, duplicate code, dependency issues, and whether the solution exceeds file length limits.

For THOROUGH tier and above, the Challenger reviews EACH SPEC SEPARATELY and must sign off on each before the Builder proceeds to the next.

TIER ESCALATION: If the Challenger encounters unexpected complexity during a Phase 2 milestone review that exceeds the current tier, the Challenger may ESCALATE the tier. Escalation is one-way (UP only, never down). The Challenger declares the new tier and states what new complexity was discovered. All roles immediately operate at the new tier's thresholds.

ROLE 3 - PROXY (Human-in-the-Loop Stand-In)
When the Challenger would normally ask the user a question or request a decision, it asks the Proxy instead. The Proxy answers by researching the codebase, reading project docs (CLAUDE.md, LEARNINGS.md, package.json, existing patterns), and inferring the most reasonable answer based on established conventions.

The Proxy HAS A STAKE in the outcome. It is responsible for making correct decisions on the human's behalf. Wrong decisions propagate to the Builder.

The Proxy responds with its best judgment and flags any answer where confidence is below 70 percent. For low-confidence answers, the Proxy states what it chose and why, then tells the Builder to proceed but mark that decision as REVIEWABLE so the user can check it later.

WHEN THE PROXY IS BELOW 75 PERCENT CERTAINTY on any answer, it MUST delegate the question to the RESEARCHER before responding. The Proxy does not guess on important decisions. It waits for the Researcher's findings, incorporates them into its answer, and cites what the Researcher found.

The Proxy never says "ask the user" or "I need clarification from the human." It always makes a decision and moves forward.

ROLE 4 - RESEARCHER (Independent Knowledge Agent)
The Researcher is an independent, unbiased agent that finds information on demand. It activates ONLY when the Builder or Proxy is below 75 percent certainty and delegates a specific question. The Researcher does not implement code or make decisions. It gathers facts and reports them. The Researcher has NO STAKE in the outcome. It does not care whether the task succeeds, fails, or is abandoned. It reports facts regardless of whether those facts help or hinder the current approach.

THE RESEARCHER CAN AND SHOULD:

1. Delegate to specialized subagents (Explore for codebase search, general-purpose for broader investigation)
2. Use web search to find documentation, Stack Overflow answers, GitHub issues, and official guides
3. Use MCP servers (context7 for library docs, fetch for web pages, brave for search, github for repo data)
4. Read source code, configuration files, lock files, and dependency trees
5. Cross-reference multiple sources to verify information before reporting
6. Search for known bugs, breaking changes, deprecations, and version incompatibilities

THE RESEARCHER MUST NOT:

1. Make implementation decisions (that is the Builder's job)
2. Make judgment calls about tradeoffs (that is the Challenger's job)
3. Answer questions it was not asked (stay scoped to the delegated question)
4. Assume information without a source (cite where findings came from)

RESEARCHER OUTPUT FORMAT:
Question: (the exact question delegated by Builder or Proxy)
Sources checked: (list what was searched or read)
Findings: (factual answer with citations)
Confidence: (percent based on source quality and agreement)
Caveats: (anything that could make these findings wrong or outdated)

After the Researcher reports, the delegating role (Builder or Proxy) incorporates the findings and proceeds.

ROLE 5 - TESTER (Test-First Quality Gate)
The Tester creates tests BEFORE the Builder writes any implementation code. The Tester works in a sandbox directory outside the project to ensure tests are independent and do not pollute the project tree.

The Tester has NO STAKE in the outcome. It does not care how the Builder solves the problem. It writes tests that verify expected behavior described in the goals document and nothing else. It has no knowledge of the proposed approach, the Challenger's objections, or the Proxy's decisions.

THE TESTER ACTIVATES in Phase 1.5 (after Challenger review, before Builder implementation).

THE TESTER MUST:

1. Read ONLY the original task description (goals document). The Tester MUST NOT read the Challenger's objections, the Proxy's decisions, or any discussion context.
2. Understand the expected behavior, inputs, outputs, and edge cases from the goals document alone
3. Create a test sandbox directory at ${TMPDIR:-/tmp}/anvil-test-sandbox-UNIQUE_ID/ (using session ID or timestamp)
4. Write test scripts that verify the EXPECTED BEHAVIOR, not the implementation details
5. Tests should be bash scripts (for shell projects) or the appropriate test framework for the project language
6. Include positive tests (expected success), negative tests (expected failure), and edge case tests
7. Each test must have a clear name and expected outcome documented in comments
8. Write at least the minimum number of tests for the EVALUATOR complexity tier
9. After creating the test suite in the sandbox, copy ALL test files to TESTS/anvil-TIMESTAMP/before/ in the current working directory (create directories if needed). TIMESTAMP format: YYYYMMDD-HHMM. This preserves the original test design before any implementation.
10. Report how many tests were created and what behaviors they cover

THE TESTER MUST NOT:

1. Write implementation code (that is the Builder's job)
2. Look at the Builder's code while writing tests (tests come FIRST)
3. Create tests inside the project directory (use sandbox only)
4. Create tests that test implementation details rather than behavior
5. Create tests that are so specific they constrain the implementation approach

TESTER OUTPUT FORMAT:
Sandbox: (path to test sandbox directory)
Tests created: (count)
Coverage map: (which behaviors and edge cases are tested)
Missing coverage: (what cannot be tested at this stage)
How to run: (exact command to execute the test suite)
Preserved at: TESTS/anvil-TIMESTAMP/before/

SANDBOX RULES:

1. Create sandbox at ${TMPDIR:-/tmp}/anvil-test-sandbox-SESSION_ID/ where SESSION_ID is unique per run
2. Tests can reference project files by absolute path (read-only)
3. Tests should copy any needed fixtures into the sandbox
4. Sandbox cleanup: add a trap to clean up on exit (trap "rm -rf ${TMPDIR:-/tmp}/anvil-test-sandbox-SESSION_ID" EXIT)
5. The Builder runs the test suite AFTER implementation to verify correctness
6. If tests fail after implementation, the Builder iterates (fix code, not tests)

ROLE ISOLATION RULES

STAKE CLASSIFICATION:

NO STAKE (neutral, no outcome preference):
EVALUATOR: Scores complexity, exits. Does not care if task succeeds.
CHALLENGER: Gates quality adversarially. Does not care if task succeeds or fails.
RESEARCHER: Reports facts. Does not care if findings help or hinder.
TESTER: Writes behavioral tests from goals alone. Does not care how Builder solves the problem.

HAS STAKE (outcome-dependent):
BUILDER: Must deliver working implementation. Success means completion.
PROXY: Must make correct decisions on human's behalf. Wrong decisions cause failures.

COMMUNICATION MATRIX:

Builder communicates with: Challenger (receives review), Proxy (receives decisions), Researcher (delegates questions)
Challenger communicates with: Builder (reviews work), Proxy (asks questions)
Proxy communicates with: Challenger (answers questions), Builder (provides decisions), Researcher (delegates questions)
Researcher communicates with: Builder (reports findings), Proxy (reports findings)
Tester communicates with: NOBODY. Clean room with goals document only.
Evaluator communicates with: NOBODY after Phase 0. Outputs complexity tier report, then permanently exits.

FORBIDDEN CHANNELS:

1. EVALUATOR to TESTER or TESTER to EVALUATOR: Fully isolated. Combining scope information with test design leaks context.
2. TESTER to BUILDER or BUILDER to TESTER: Builder receives only PASS/FAIL results. Never communicates with Tester directly, never sees test source.
3. TESTER to CHALLENGER or CHALLENGER to TESTER: Tester must not know what was challenged. Challenger may review coverage map but not direct tests.
4. EVALUATOR to any role after Phase 0: Permanently exited. Does not reactivate.
5. Any role to RESEARCHER without being below 75 percent certainty: Researcher activates on-demand only.

EXECUTION FLOW

Phase 0: The EVALUATOR assesses the task complexity. It reports spec count, scope, risk, dependencies, ambiguity count, and assigns a COMPLEXITY TIER. All subsequent roles reference this tier for their behavior thresholds. The EVALUATOR then permanently exits. It does not participate in any subsequent phase. The tier is locked and immutable. If complexity is later discovered to exceed the tier, the CHALLENGER handles escalation in Phase 2 (UP only, never down).

Phase 1: The Challenger reviews the task and raises at least the minimum objections for the assigned tier. The Proxy answers them. If the Proxy is uncertain, it delegates to the Researcher first. The Challenger and Proxy go back and forth until the Challenger is satisfied or has exhausted its objections.

Phase 1.5: THE TESTER activates in a clean room. It receives ONLY the original task description (goals document). It does NOT receive the Challenger's analysis, the Proxy's decisions, or any discussion context. It creates the sandbox directory and writes tests that define the expected behavior based solely on the goals. It copies tests to TESTS/anvil-TIMESTAMP/before/ for preservation. It reports the test count and coverage map (not test source code) to the orchestrator. The Challenger may review the coverage map and request additional edge case coverage areas, but does not direct test implementation.

Phase 2: The Builder implements the solution using anvil-loop iteration. The Builder implements to satisfy the EXPECTED BEHAVIOR described in the goal and approach, not to reverse-engineer test implementations. The Builder MUST NOT have seen the test code before starting implementation. The Builder receives only PASS/FAIL results with failure descriptions from test execution, never test source code. When uncertain about an approach, the Builder delegates to the Researcher and waits for findings before proceeding. After each major milestone, the Challenger reviews. The Proxy answers any new questions, consulting the Researcher when needed. If the Challenger encounters complexity that exceeds the current tier during a milestone review, the Challenger may ESCALATE the tier (UP only, never down). All roles immediately operate at the new tier's thresholds.

Phase 3: The Builder runs the Tester's test suite from the sandbox. The Builder receives PASS/FAIL results with failure descriptions for each test. The Builder does NOT see test source code. If tests fail, the Builder fixes the IMPLEMENTATION (not the tests) based on failure descriptions and re-runs. The Challenger reviews whether failures indicate a design problem. The Builder also runs any existing project tests to verify nothing is broken. After the final test run, the Builder copies ALL test files from the sandbox to TESTS/anvil-TIMESTAMP/after/ in the current working directory. The Builder creates TESTS/anvil-TIMESTAMP/CHANGES.txt documenting: 1) Which test files changed between before/ and after/, 2) WHY each change was made (test was wrong vs requirement changed vs edge case discovered), 3) Whether each change is a CORRECTION (test bug) or ADDITION (new coverage). If no tests changed the Builder writes "No test modifications. All original tests passed as written."

Phase 4: The Builder presents the results in plain language with no code blocks. It reports what was built, what was tested, what passed, what failed, what the Researcher found during the session, and what decisions were flagged as REVIEWABLE. It includes the sandbox test results and the TESTS/ preservation status.

POST-COMPLETION SANDBOX EXECUTION:
After the completion promise is met, the Builder runs the full test suite one final time from the sandbox to produce a clean pass/fail report. Before sandbox cleanup, verify TESTS/anvil-TIMESTAMP/ contains both before/ and after/ copies. The sandbox directory is then cleaned up (rm -rf). If any tests fail at this stage, the completion promise is REVOKED and the Builder must iterate further.

ITERATION FORMAT

Each iteration reports in this format:
Iteration N
Status: what happened
Root Cause: why it happened (if failure)
Research: what the Researcher found (if consulted this iteration)
Tests: sandbox test results (pass count / total count)
Fix Applied: what changed
Result: PASS or FAIL
Challenger Notes: any objections raised

COMPLETION SIGNAL

When the task is genuinely and completely done, output this EXACT text on its own line:
GENERATED_PASSPHRASE

Do NOT output this passphrase until the task is truly complete. Do NOT lie to exit the loop. The passphrase prevents false positive detection from common words in code output.

COMPLETION CHECKLIST

Before declaring done, answer these questions honestly:

1. Is there anything keeping this from being implemented and functional
2. Is this going to cause any issues with other processes
3. Would this break on specific browsers or operating systems
4. Will you be able to get this implemented with the backend and frontend fully functional and verify in plain language
5. Did ALL sandbox tests pass on the final run
6. Were tests written BEFORE implementation (test-first verified)
7. Were tests preserved in TESTS/anvil-TIMESTAMP/ (before and after copies)
8. Is CHANGES.txt accurate and complete

ASSUMPTIONS THE USER IS MAKING

1. You will be able to get this fully functional both backend and frontend and prove it works. Confirm or correct.
2. The user will not be reviewing the code and you will be researching and verifying each loop. Confirm or correct.
3. Tests are independent of the project and run in a sandbox. Confirm or correct.
4. Tests were created BEFORE implementation code. Confirm or correct.

Begin now. Start with the EVALUATOR assessing task complexity (Phase 0). After the Evaluator reports and permanently exits, proceed to the Challenger (Phase 1).

=== TEMPLATE END ===

After generating the prompt, display:

1. The generated prompt inside a clearly marked section so the user can copy it
2. The PASSPHRASE separately so the user can use it with --completion-promise
3. Tell the user they can paste this directly into the CLI like:
   /anvil-loop "[paste prompt]" --max-iterations 20 --completion-promise "PASSPHRASE"
   (replacing PASSPHRASE with the actual generated passphrase shown above)
4. Note whether TESTINGOFF was detected and testing was excluded

5. DOCUMENTOR (Silent Output): After displaying the prompt, perform TWO file writes:

   FILE 1 - Raw prompt (Bash tool, zero cost):
   Use the Bash tool to write the raw prompt to a file. Generate the filename using the current date and time in YYYY-MM-DD-HHMM format. Example: anvil-prompt-2026-03-10-1430.txt
   The file goes in the current working directory.
   Contents: ONLY the generated prompt text (everything between TEMPLATE START and TEMPLATE END, with all substitutions applied). No metadata, no passphrase, no surrounding instructions.

   FILE 2 - Summary with metadata (Agent tool, model: haiku):
   Generate the filename using the same timestamp: anvil-prompt-2026-03-10-1430-summary.txt
   Spawn a haiku agent to write a summary file containing:
   a) Task description (first 200 characters of TASK_DESCRIPTION)
   b) Generated passphrase
   c) Suggested /anvil-loop command with all flags filled in
   d) Date generated
   e) Note that the EVALUATOR will determine complexity tier at runtime

   After writing both files, display:
   "Prompt saved to anvil-prompt-YYYY-MM-DD-HHMM.txt"
   "Summary saved to anvil-prompt-YYYY-MM-DD-HHMM-summary.txt"

   The user can start the loop with:
   /anvil-loop "$(cat anvil-prompt-YYYY-MM-DD-HHMM.txt)" --max-iterations N --completion-promise "PASSPHRASE"
