from pathlib import Path

p = Path("Sources/PokeTokenBar/WindowsCore/CompanionModel.swift")
s = p.read_text(encoding="utf-8")
old = "    var representativeSpeciesID: Int?\n"
new = "    var representativeSpeciesID: Int? = nil\n"
if s.count(old) != 1:
    raise SystemExit(f"expected one representative field, found {s.count(old)}")
p.write_text(s.replace(old, new, 1), encoding="utf-8")
print("fixed representative default")
