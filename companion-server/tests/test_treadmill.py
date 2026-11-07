from datetime import datetime, timedelta, timezone

from companion.facts import comparable, infer_coach_type, run_label


def test_treadmill_has_training_type_and_keeps_indoor_identity():
    assert infer_coach_type('treadmill', distance_m=5000, duration_s=1800,
                            zone_min={'z2': 30}, pb=None, history=[]) == 'easy'
    assert run_label({'type': 'easy', 'app_type': 'treadmill'}) == 'treadmill run'


def test_manual_treadmill_pace_is_not_compared_with_road_pace():
    now = datetime(2026, 11, 2, tzinfo=timezone.utc)
    indoor = dict(type='easy', app_type='treadmill', distance_m=5000,
                  pace_s_per_km=360, start_utc=now)
    road = dict(indoor, app_type='free', start_utc=now-timedelta(days=1))
    previous = dict(indoor, start_utc=now-timedelta(days=2))
    assert comparable(indoor, [road]) is None
    assert comparable(dict(road, start_utc=now), [previous]) is None
    assert comparable(indoor, [road, previous]) is previous


def test_treadmill_wire_contract():
    from companion.service import RunIn
    # The app's distance and identity are accepted by the wire contract.
    run = RunIn(run_id='treadmill', type='treadmill', start_utc=datetime.now(timezone.utc),
                utc_offset_min=0, zone_id='UTC', duration_s=1800, distance_m=5000)
    assert run.type == 'treadmill' and run.distance_m == 5000
