# Windows collection parity

This branch brings the Win32 Collection surface in line with the companion collection model:

- species-based Pokédex, including the currently raised Pokémon immediately
- individual Catch Log, distinguishing raising / released / graduated records
- released Pokémon remain in the Pokédex after buying a fresh egg
- rarity filtering
- 4 × 6 paged Pokédex (24 species per page)
- Catch Log scrolling

`Package.swift` excludes the shared `Core` directory from the Windows target, so the macOS collection semantics are forward-ported into `WindowsCore/CompanionModel.swift` and `WindowsCore/CompanionStore.swift`. `WindowsTray.swift` only maps those WindowsCore values into Win32 rendering snapshots. The implementation deliberately keeps the same semantics as shared Core (`dexSpecies`, `dexEntriesSorted`, `isActiveDexEntry`) so future consolidation remains straightforward.
