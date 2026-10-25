// Generated from src/core/contracts/{chat,probe}.ts — the single-sourced
// model-facing marker texts. Keep byte-identical with the TS.

public let HANDOFF_TEXT = "Next: plan the full teaching arc from my current understanding to the goal understanding. Apply the teaching methodology in your teaching instructions, and find the optimal way to teach me this. Find the unconditional truths, plan the motivated derivations/discoveries, so every reasoning step has to land as obviously true. Take your time here and really think this through. When it's genuinely reasoned out, call plan_init and present the plan; I'll accept it or ask for changes."
/// Leads the teach phase's system message (the phased handoff).
public let TEACH_PHASE_LEAD = "The probe phase is over: the probing instructions earlier in this conversation no longer apply. From here on you teach, by these instructions:"
public let THINKING_LABEL = "Your thinking"
public let CONCLUDE_ACK_TEXT = "Problem concluded. Say your closing words about the learner's work if useful, then END YOUR TURN — no further tool calls. The next problem is NEVER posed here: it waits for the learner's explicit go-ahead (a *Next problem* message, or their own words asking for the next one). Between problems, answer their questions about the concluded one."
public let NEXT_PROBLEM_TEXT = "[NEXT PROBLEM] — the learner's explicit go-ahead: pose the next problem now per the selection rules, or wrap the session in text if the arc is complete."
public let COMPACTED_HISTORY_HEADER = "[SESSION HISTORY COMPACTED] The transcript before this point was summarized to fit the context window; the summary below replaces it. Everything after this message is the verbatim recent transcript."
public let PROBE_DONE_ACK_TEXT = "Assessment recorded — it is shown to the learner now and the teacher plans from it. Say your closing sentence and end your turn; the teaching phase takes over from here."
