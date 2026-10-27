import copy
import json
import re
import unittest
from pathlib import Path

import jsonschema

ROOT = Path(__file__).resolve().parents[2]
SCHEMAS = ROOT / "docs" / "schema"
FIXTURES = ROOT / "tools" / "fixtures"
SWIFT = ROOT / "Packages" / "CoachKit" / "Sources" / "CoachKit"


def load(path):
    return json.loads(Path(path).read_text())


def validator(name):
    """Validator for docs/schema/<name>.schema.json with the sibling schemas resolvable by $id."""
    store = {s["$id"]: s for s in (load(p) for p in SCHEMAS.glob("*.schema.json"))}
    schema = store[next(i for i in store if i.endswith(f"/{name}.schema.json"))]
    try:
        from referencing import Registry, Resource
        registry = Registry().with_resources((i, Resource.from_contents(s)) for i, s in store.items())
        return jsonschema.Draft7Validator(schema, registry=registry)
    except ImportError:  # jsonschema < 4.18
        return jsonschema.Draft7Validator(schema, resolver=jsonschema.RefResolver.from_schema(schema, store=store))


def errors(name, doc):
    return sorted(e.message for e in validator(name).iter_errors(doc))


def swift_cases(path, enum_name):
    """Raw values of `enum <enum_name>`: `case a, b = "x"` lines, as the Swift source writes them."""
    text = Path(path).read_text()
    body = re.search(r"enum %s\b[^{]*\{(.*?)\n\}" % enum_name, text, re.S).group(1)
    out = []
    for line in body.splitlines():
        line = line.strip()
        # Declarations only: `case a, b = "x"`, not `case .a: return "..."` in a switch.
        if not re.fullmatch(r'case \w+(?: = "[^"]*")?(?:, \w+(?: = "[^"]*")?)*', line):
            continue
        for item in line[5:].split(","):
            m = re.match(r'\s*(\w+)(?:\s*=\s*"([^"]*)")?', item)
            if m:
                out.append(m.group(2) or m.group(1))
    return out


class FixtureTests(unittest.TestCase):
    def test_schemas_are_valid(self):
        for p in SCHEMAS.glob("*.schema.json"):
            with self.subTest(p.name):
                jsonschema.Draft7Validator.check_schema(load(p))

    def test_manifests_validate(self):
        found = list(FIXTURES.glob("*/manifest.json"))
        self.assertGreaterEqual(len(found), 2)
        for p in found:
            with self.subTest(str(p.relative_to(FIXTURES))):
                self.assertEqual(errors("manifest", load(p)), [])

    def test_coach_json_validates(self):
        found = list(FIXTURES.glob("*/coach.json"))
        self.assertGreaterEqual(len(found), 1)
        for p in found:
            with self.subTest(str(p.relative_to(FIXTURES))):
                self.assertEqual(errors("coach", load(p)), [])
                self.assertEqual(errors("plan", load(p)["plan"]), [])


CONTRACT = FIXTURES / "swift-contract"


class SwiftEncodedTests(unittest.TestCase):
    """tools/fixtures/swift-contract/*.json are compared with REAL encoded CoachKit structs by SchemaContractTests.swift
    (CI, apple job), so what validates here is what the Swift types write."""

    def test_each_validates(self):
        for name, schema in [("manifest-full", "manifest"), ("manifest-min", "manifest"), ("coach-full", "coach"),
                             ("coach-min", "coach"), ("coach-legacy-int", "coach"), ("plan", "plan"),
                             ("phone-correction", "phone-correction")]:
            with self.subTest(name):
                self.assertEqual(errors(schema, load(CONTRACT / f"{name}.json")), [])

    def test_full_variants_use_every_schema_property(self):
        # A schema property no real struct ever fills is dead (or the Swift type lost a field).
        manifest = load(SCHEMAS / "manifest.schema.json")["properties"]
        self.assertEqual(set(load(CONTRACT / "manifest-full.json")), set(manifest))
        coach = load(SCHEMAS / "coach.schema.json")["properties"]
        full = load(CONTRACT / "coach-full.json")
        self.assertEqual(set(full), set(coach))
        step = load(SCHEMAS / "plan.schema.json")["definitions"]["step"]["properties"]
        self.assertEqual(set().union(*(set(x) for x in full["plan"]["steps"])), set(step))
        self.assertEqual(set(full["splits"][1]) | set(full["splits"][0]), {"stepIndex", "startMs", "endMs", "skipped"})
        self.assertEqual(set(full["noReps"][0]), {"tMs", "setIndex", "stepIndex"})

    def test_min_variants_omit_nil_optionals(self):
        required = set(load(SCHEMAS / "manifest.schema.json")["required"])
        self.assertEqual(set(load(CONTRACT / "manifest-min.json")), required)

    def test_swift_test_exists_for_every_fixture(self):
        text = (ROOT / "Packages/CoachKit/Tests/CoachKitTests/SchemaContractTests.swift").read_text()
        for p in CONTRACT.glob("*.json"):
            self.assertIn(p.stem, text, f"{p.name} is not exercised by SchemaContractTests.swift")


class RejectionTests(unittest.TestCase):
    """The schemas must actually refuse things, or the green fixtures above prove nothing."""

    def setUp(self):
        self.coach = load(FIXTURES / "coached-fixture" / "coach.json")
        self.manifest = load(FIXTURES / "coached-fixture" / "manifest.json")

    def test_manifest_rejections(self):
        for label, mutate in [
            ("missing required", lambda m: m.pop("sessionId")),
            ("unknown key", lambda m: m.update(sesionId="typo")),
            ("bad wrist", lambda m: m.update(wrist="up")),
            ("athlete is a name", lambda m: m.update(athlete="Ricki")),
            ("wrong version", lambda m: m.update(formatVersion=2)),
            ("string hz", lambda m: m.update(storeHz="50")),
        ]:
            with self.subTest(label):
                m = copy.deepcopy(self.manifest)
                mutate(m)
                self.assertNotEqual(errors("manifest", m), [])

    def test_coach_rejections(self):
        for label, mutate in [
            ("missing splits", lambda c: c.pop("splits")),
            ("unknown activity", lambda c: c["plan"]["steps"][0].update(activity="burpees")),
            ("unknown division", lambda c: c["plan"].update(division="masters")),
            ("split without start", lambda c: c["splits"][0].pop("startMs")),
            ("rep time as string", lambda c: c.update(repTimesMs=["1"])),
            ("unknown key", lambda c: c.update(extra=1)),
            ("no-rep without set", lambda c: c.update(noReps=[{"tMs": 1}])),
            ("bad correction", lambda c: c.update(wallBallCorrection={"validReps": 1})),
        ]:
            with self.subTest(label):
                c = copy.deepcopy(self.coach)
                mutate(c)
                self.assertNotEqual(errors("coach", c), [])

    def test_accepted_variants(self):
        c = copy.deepcopy(self.coach)
        c["noReps"] = [{"tMs": 1, "setIndex": 0}, {"tMs": 2, "setIndex": 1, "stepIndex": 15}]
        c["wallBallCorrection"] = {"validReps": 18, "noReps": 2}
        self.assertEqual(errors("coach", c), [])
        c["wallBallCorrection"] = 20  # legacy bare Int
        self.assertEqual(errors("coach", c), [])
        c["splits"].append({"stepIndex": 16, "startMs": 1})  # a step not finished has no endMs
        self.assertEqual(errors("coach", c), [])
        m = copy.deepcopy(self.manifest)
        m.update(resumed=2, recovered=True, crownOrientation="right")
        m.pop("endedAtEpochMs"); m.pop("files")  # a session that never finished
        self.assertEqual(errors("manifest", m), [])


class SwiftAgreementTests(unittest.TestCase):
    """The schemas and the Swift sources must not drift apart."""

    def test_enums_match_swift(self):
        plan = load(SCHEMAS / "plan.schema.json")
        self.assertEqual(plan["properties"]["division"]["enum"], swift_cases(SWIFT / "Plan.swift", "Division"))
        self.assertEqual(plan["properties"]["type"]["enum"], swift_cases(SWIFT / "Plan.swift", "SessionType"))
        self.assertEqual(plan["definitions"]["step"]["properties"]["activity"]["enum"],
                         swift_cases(SWIFT / "Activity.swift", "Activity"))

    def test_property_sets_match_swift(self):
        schema = {n: load(SCHEMAS / f"{n}.schema.json") for n in ("coach", "plan", "phone-correction")}
        cases = [
            ("CoachResult.swift", "CoachResult", set(schema["coach"]["properties"])),
            ("SessionMachine.swift", "StepSplit", set(schema["coach"]["properties"]["splits"]["items"]["properties"])),
            ("CoachResult.swift", "NoRepEvent", set(schema["coach"]["properties"]["noReps"]["items"]["properties"])),
            ("CoachResult.swift", "WallBallCorrection", set(schema["phone-correction"]["properties"])),
            ("Plan.swift", "SessionPlan", set(schema["plan"]["properties"])),
            ("Plan.swift", "PlanStep", set(schema["plan"]["definitions"]["step"]["properties"])),
        ]
        for file, struct, props in cases:
            with self.subTest(struct):
                text = (SWIFT / file).read_text()
                body = re.search(r"struct %s\b[^{]*\{(.*?)\n\}" % struct, text, re.S).group(1)
                # Stored properties only (`public let|var name: Type`), not computed ones (`... { ... }`).
                names = {m.group(1) for m in re.finditer(r"^  public (?:let|var) (\w+): [^\n{]*$", body, re.M)}
                self.assertEqual(props, names)
        corr = schema["coach"]["properties"]["wallBallCorrection"]["oneOf"][0]["properties"]
        self.assertEqual(set(corr), set(schema["phone-correction"]["properties"]))

    def test_manifest_value_sets_match_swift(self):
        props = load(SCHEMAS / "manifest.schema.json")["properties"]
        self.assertEqual(props["audioMode"]["enum"], swift_cases(SWIFT / "CueLog.swift", "AudioMode"))
        recorder = (ROOT / "Watch" / "RecorderController.swift").read_text()
        m = re.search(r'labelSource: coach \? "(\w+)" : "(\w+)"', recorder)
        self.assertEqual(set(props["labelSource"]["enum"]), set(m.groups()))
        self.assertIn('["A1", "A2", "A3", "A4"]', recorder)
        self.assertRegex("A4", props["athlete"]["pattern"])

    def test_manifest_properties_match_swift(self):
        text = (SWIFT / "Session.swift").read_text()
        body = re.search(r"struct SessionManifest\b[^{]*\{(.*?)\n  public init", text, re.S).group(1)
        swift = set(re.findall(r"^  public var (\w+):", body, re.M))
        schema = set(load(SCHEMAS / "manifest.schema.json")["properties"])
        self.assertEqual(schema, swift)
        self.assertIn("resumed", schema)


if __name__ == "__main__":
    unittest.main()
