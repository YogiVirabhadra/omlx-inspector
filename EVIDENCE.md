# Evidence model

oMLX Inspector separates what the log shows from what the app infers. This document lists every inference rule: the evidence it requires, what happens when that evidence is missing or ambiguous, and the code that enforces it. When a rule cannot be satisfied, the app leaves records unassociated and says so; it never guesses.

The source log is observed evidence. Conversation grouping and associations between records are inferences. Source references retain offsets, lengths and SHA-256 digests; `LogSnapshot.verifiedText(of:)` rejects evidence whose file identity or record bytes changed. Structured and Source views retain original request fields. Tool results are agent-reported, not independent execution telemetry.

| Rule | Required evidence and conservative fallback | Enforcement |
| --- | --- | --- |
| History continuity | Exact message-hash prefix; longest candidates must share group, turn and model. Repeated rich history can replay within one origin. Identical opening prompts alone never merge. | `EvidenceBuilder.matchHistory` |
| Old checkpoint branch | Every descendant head must share exact messages until a fork at a user-message position on both histories. Otherwise keep separate. | `isUserBranch` |
| Possible reset | No matched prefix; exactly one current head with the same last user, a different chain and at least two shared message hashes. Offer comparison only; never merge. | `requestMetrics` |
| History suppression | Emit only messages after the matched checkpoint; retain full source. Retire the matched head's hashes but retain its compact checkpoint and children. | `appendMessageEvents`, `checkpointHistory` |
| Tool result link | Exactly one call with the explicit tool-call ID in the inferred group, and that call has no result yet. Otherwise leave unmatched. Raw generated tool syntax establishes intent only. | `appendMessageEvents`, `consume` |
| Scheduler admission | Exactly one pending incoming request and every earlier active scheduler UUID already attributed. Otherwise discard pending association candidates. | `consume` |
| Generated output | Explicit scheduler UUID associates output to that admission; unknown UUID creates unlinked output. | `consume` |
| Completion isolation | Exactly one open incoming lifetime, no overlap, no active or pending requests; window has scheduler UUID, finish time, output time and output event. | `consumeCompletion` |
| Completion agreement | Exact model and prompt/generated counts; output-to-summary delay in 0…5 seconds; output no earlier than finish; server duration no longer than incoming-to-summary + 0.02 seconds and no shorter than scheduler duration − 0.02 seconds. | `consumeCompletion` |
| Completion rejection | Preserve original INFO record as unattributed diagnostic with reason. Every summary closes at most one open lifetime, invalidates the window, and clears overlap only at zero open lifetimes. | `rejectCompletion`, `consumeCompletion` |
| Possible active completion | A malformed summary, or matching model/prompt count while a scheduler UUID is active, marks its lifetime uncertain to prevent later double retirement. | `observePossibleActiveCompletion` |
| Cancellation proof | Engine abort plus completed scheduler abort or orphan cleanup with the same active UUID. Orphan list count, uniqueness and ID syntax must agree. Deferred abort intent alone is insufficient. | `consumeCancellation` |
| Cancellation retirement | Remove active UUID once. Retire incoming lifetime only with engine abort evidence, attributed admission, no uncertain completion and positive open count. Never repair an overlapped window. Duplicate/late cleanup cannot retire again. Uncertain cleanup remains diagnostic evidence. | `retireCancelledRequest` |
| Fresh recovery | Once earlier lifetimes resolve, a later isolated incoming request can establish a new completion window. | `request`, `consumeCompletion`, `retireCancelledRequest` |
| Timing | Timestamp subtraction returns a signed interval or nil. Metrics and association callers reject negative spans where required. A terminal completion is required for completed turn duration. Log timestamps carry no time-zone offset, so a span that crosses the repeated hour at a daylight-saving change can be off by an hour. | `EvidenceBuilder.elapsedSeconds`, `TurnMetrics` |
| Clear Display | A presentation boundary hides unchanged old evidence without deleting canonical history; updates and a new source generation remain visible. | `DisplayBoundary`, `Workspace` |

Parsing accepts only supported syntax (`LogGrammar`), but does not add level restrictions where older parsing had none. The order of checks in `EvidenceBuilder.consume` is significant. Background notifications and title generation are explicitly labeled inferences. Missing or ambiguous evidence remains unavailable rather than guessed.

Regression anchors: `InferenceDecisionTests`, `CompletionTests`, `BranchHistoryTests`, `CoreBoundaryTests`, `DisplayBoundaryTests`, `StreamingTests`, and `LongTurnTests`. Update this policy and the relevant tests together when changing an inference rule.
