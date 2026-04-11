# Authors and Credits

## Darius_MiSTer core

**Author**: Umberto Parisi ([rmonic79](https://github.com/rmonic79))

The original RTL source files for the Darius-specific logic (under
`rtl/darius/` and the project wrapper `Template.sv`) are copyright
Umberto Parisi and distributed under GNU GPL v3 or later.

## Third-party components

This core builds on top of excellent open-source projects. All third-party
sources retain their original copyright and license. The core as a whole
is distributed under **GNU GPL v3 or later** to stay compatible with the
most restrictive upstream (JTFRAME / JTCORES).

| Component | Author | Project | License |
|-----------|--------|---------|---------|
| **FX68K** — M68000 cycle-accurate core | Jorge Cwik | [ijor/fx68k](https://github.com/ijor/fx68k) | GPL-3 |
| **JTFRAME / JTCORES** — framework, filters, dtack, tilemap, etc. | Jose Tejada ([@topapate](https://twitter.com/topapate)) | [jotego/jtcores](https://github.com/jotego/jtcores) | GPL-3 |
| **JT12** — YM2203 FM synthesizer | Jose Tejada | [jotego/jt12](https://github.com/jotego/jt12) | GPL-3 |
| **JT5205** — MSM5205 ADPCM decoder | Jose Tejada | [jotego/jt5205](https://github.com/jotego/jt5205) | GPL-3 |
| **T80** — Z80 core | Daniel Wallner, MikeJ | [MiSTer-devel/T80](https://github.com/MiSTer-devel/T80) | BSD / GPL |
| **sdram.sv** — Genesis SDRAM controller | Sorgelig ([sorgelig](https://github.com/sorgelig)) | [MiSTer-devel](https://github.com/MiSTer-devel) | GPL-3 |
| **sys/ framework** — MiSTer HPS/IO, OSD, video scaler, audio | Sorgelig / MiSTer-devel | [MiSTer-devel/Main_MiSTer](https://github.com/MiSTer-devel/Main_MiSTer) | GPL-3 |

## Reference

- **Darius arcade hardware** — Taito Corporation, 1986. This FPGA core is a
  reimplementation from hardware documentation, MAME source code, and
  observation of real hardware behavior. ROMs are **not** included and must
  be provided by the user.
- **MAME project** — invaluable reference for memory maps, timing,
  and driver behavior. [mamedev/mame](https://github.com/mamedev/mame)
