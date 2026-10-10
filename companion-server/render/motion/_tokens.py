"""Brand tokens for motion renders.

Local copy of the single source in the plan (~/ai/plans/run-supreme-agent-12h.md). Switch to
`render/brand.py` (owned by rs-cards) once it is on main; keep the names stable so that is a
one-line change. Names ending _DARK are motion-only derivations for text on the zone floods
(the light-ground colours lose contrast on a dark flood).
"""

# Light ground
GROUND = "#FBFBF9"
INK = "#121417"
QUIET = "#6C747E"
HAIRLINE = "#E3E5E0"
BONE = "#EDEAE3"

# Score colours (light) and run-type names
SCORES = {
    "AEROBIC": "#3E9B1E",
    "SPEED": "#D81B7A",
    "MID": "#8A5CF0",
    "LONG": "#1F8FD6",
}
SCORES_DARK = {  # derived, for dark floods
    "AEROBIC": "#7BDB4F",
    "SPEED": "#FF5AAE",
    "MID": "#B79BFF",
    "LONG": "#5CC0FF",
}
MINT = "#1C8356"
VERMILLION = "#C8401E"
MINT_DARK = "#5BE0AE"
VERMILLION_DARK = "#FF7B54"
PB_CYAN = "#19E6FF"

# Zone chart ramp Z1..Z5 and the matching floods
ZONES = ["#2F6DB5", "#2E9E5B", "#D9A21B", "#E86A1C", "#D6283B"]
# Z2/Z3/Z4 darkened to 7:1 Bone contrast, same values as render/brand.py ZONE_FLOOD (rs-cards, #221)
FLOODS = ["#1C3F6E", "#155835", "#634907", "#863210", "#7D1222"]

MARK_INK = "#0F1114"
ARC_LIGHT = "#0098B2"
