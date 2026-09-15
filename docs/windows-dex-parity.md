# Windows collection parity

This branch brings the Win32 Collection surface in line with the shared companion collection model:

- species-based Pokédex, including the currently raised Pokémon immediately
- individual Catch Log, distinguishing raising / released / graduated records
- released Pokémon remain in the Pokédex after buying a fresh egg
- rarity filtering
- 4 × 6 paged Pokédex (24 species per page)
- Catch Log scrolling

The source of truth remains `Core/CompanionStore.swift` (`dexSpecies`, `dexEntriesSorted`, `isActiveDexEntry`). Windows only maps those shared values into Win32 rendering snapshots.
