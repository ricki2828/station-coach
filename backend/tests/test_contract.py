"""openapi.yaml is the contract the phone codes against; keep it and the models from drifting."""
import pathlib
import re

import yaml

from coach_service.schema import CoachFacts, RegisterRequest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = yaml.safe_load((ROOT / "openapi.yaml").read_text())
SCHEMAS = SPEC["components"]["schemas"]


def test_facts_fields_and_required_match():
    model = CoachFacts.model_json_schema()
    spec = SCHEMAS["CoachFacts"]
    assert set(spec["properties"]) == set(model["properties"])
    assert set(spec["required"]) == set(model["required"])
    assert spec["additionalProperties"] is False


def test_enums_match():
    model = CoachFacts.model_json_schema()["$defs"]
    spec = SCHEMAS["CoachFacts"]["properties"]
    assert spec["sessionType"]["enum"] == model["SessionType"]["enum"]
    assert spec["division"]["enum"] == model["Division"]["enum"]
    assert spec["reference"]["enum"] == model["Reference"]["enum"]
    assert SCHEMAS["Activity"]["enum"] == model["Activity"]["enum"]


def test_nested_objects_match():
    model = CoachFacts.model_json_schema()["$defs"]
    for name in ("Step", "WallBalls"):
        assert set(SCHEMAS[name]["properties"]) == set(model[name]["properties"])
        assert set(SCHEMAS[name]["required"]) == set(model[name]["required"])
        assert SCHEMAS[name]["additionalProperties"] is False


def test_register_matches():
    assert set(SCHEMAS["RegisterRequest"]["properties"]) == set(RegisterRequest.model_json_schema()["properties"])


def test_paths_are_the_ones_the_app_serves():
    from coach_service.app import create_app
    from coach_service.config import Settings
    app = create_app(Settings(dev_mode=True))
    served = {(m, r.path) for r in app.routes if hasattr(r, "methods") for m in r.methods}
    declared = {(m.upper(), p) for p, ops in SPEC["paths"].items() for m in ops}
    assert declared <= served


def test_public_repo_hygiene():
    banned = "hy" + "rox"
    private = ["ric" + "ki", "run " + "supreme", "run" + "-solo", "companion" + "-server"]   # owner and sibling-app names
    for p in ROOT.rglob("*"):
        if p.is_file() and p.suffix in {".py", ".md", ".yaml", ".txt", ".ini"} and ".pytest_cache" not in p.parts:
            assert banned not in p.read_text(errors="ignore").lower(), p
            low = p.read_text(errors="ignore").lower()
            assert not any(n in low for n in private), p
            assert not re.search(r"sk-[A-Za-z0-9]{20,}", p.read_text(errors="ignore")), p
