# Gap-Hunter Scan

Run after standard multi-agent passes. Each gap-hunter pass targets bugs at the SEAMS between lenses — bugs no single-lens scan can find.

**Key rule:** Do NOT report bugs a single-lens scan would catch (reentrancy, missing modifier, etc.). Only report bugs that REQUIRE 2-3 lenses to see.
