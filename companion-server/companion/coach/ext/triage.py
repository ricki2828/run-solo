"""triage_check: the red / amber / green decision for a niggle, made here in code from structured answers, never by the model.
The model asks the runner, fills the answers, and words what comes back; it cannot lift or lower the level. Red carries no
training advice at all. See coach/references/injury-triage.md and the medical rules in the coach plan (section 4)."""
from __future__ import annotations

RULES = (
    "- MEDICAL. For any pain, injury, or worrying symptom, ask a couple of short questions, then call triage_check and follow its "
    "level: you never decide it. You never diagnose (say \"could be an overuse thing\", never \"you have ...\"). You never name or "
    "dose a medication, supplement, injection or scan, and never say to run through pain. On RED say to get this seen today, give "
    "its next_step, offer find_care(kind=urgent), name the emergency number when call_emergency is true, and give NO training, "
    "pace or plan advice in that reply. On AMBER say to stop the painful sessions, see a physio or GP if it persists, and offer "
    "find_care. On GREEN give only the general advice the result carries, and say what would change it. Cite only a source a tool "
    "returned.")

# Red flags: argument name -> (reason shown to the model, needs the emergency number now). Order is the order reasons come back.
RED: dict[str, tuple[str, bool]] = {
    "chest_breath_or_fainting": ("chest pain or pressure, trouble breathing, or fainting", True),
    "heat_illness_signs": ("possible heat illness: confusion, collapse, or hot skin after running in the heat", True),
    "cannot_bear_weight": ("cannot put weight on the leg", False),
    "deformity": ("the area looks out of shape", False),
    "numbness_tingling_weakness": ("numbness, tingling or weakness", False),
    "calf_swollen_hot_or_red": ("a swollen calf that is hot or red", False),
    "fever_with_joint_pain": ("fever together with joint pain", False),
    "severe_rest_or_night_pain": ("severe pain at rest or at night", False),
    "after_fall_or_impact": ("pain after a fall or a hard knock", False),
    "bone_pain_at_night": ("pain pinpointed on a bone that also wakes them at night (possible stress fracture)", False),
}
AMBER: dict[str, str] = {
    "swelling": "swelling",
    "changes_gait": "it changes how they run or makes them limp",
    "worsening": "it gets worse as they run",
    "sharp_or_stabbing": "the pain is sharp or stabbing",
    "bone_point_pain": "pain pinpointed on a bone (shin, foot or hip)",
}
AMBER_DAYS = 3        # lasting more than this many days is amber
AMBER_PAIN = 5        # pain of this many out of 10 or more is amber

NEXT_STEP = {
    "red": "Stop running. Get this seen by a doctor today, at urgent care or an emergency department. Do not train on it.",
    "amber": "Stop the painful sessions and keep easy movement pain-free. See a physio or GP if it has not settled in a few days.",
    "green": "Keep it easy and cut volume a little. Pain should stay at 3 out of 10 or below while you run and should not be worse the next morning. Check back in 48 hours.",
}
GREEN_CHANGES = "It would move to amber if it gets worse, swells, changes how you run, or hangs around past three days."


def call(name: str, args: dict, ctx) -> dict:
    if name != "triage_check":
        raise ValueError("unknown tool")
    red = [k for k in RED if args.get(k) is True]
    if red:
        emergency = any(RED[k][1] for k in red)
        out = {"level": "red", "reasons": [RED[k][0] for k in red], "next_step": NEXT_STEP["red"], "training_advice": "none",
               "find_care_kind": "urgent", "call_emergency": emergency}
        if emergency:
            out["next_step"] = ("Stop running now. If it is happening now or severe, call your local emergency number. "
                                "Otherwise get seen by a doctor today.")
        return out
    amber = [AMBER[k] for k in AMBER if args.get(k) is True]
    days, pain = args.get("days_present"), args.get("pain_0_10")
    if days is not None and days > AMBER_DAYS:
        amber.append(f"it has lasted more than {AMBER_DAYS} days")
    if pain is not None and pain >= AMBER_PAIN:
        amber.append(f"pain of {AMBER_PAIN} out of 10 or more")
    if amber:
        return {"level": "amber", "reasons": amber, "next_step": NEXT_STEP["amber"], "training_advice": "easy_pain_free_only",
                "find_care_kind": "physio", "call_emergency": False}
    return {"level": "green", "reasons": ["no warning signs reported"], "next_step": NEXT_STEP["green"],
            "training_advice": "general_load_management", "what_would_change_it": GREEN_CHANGES,
            "find_care_kind": None, "call_emergency": False, "check_back_hours": 48}
