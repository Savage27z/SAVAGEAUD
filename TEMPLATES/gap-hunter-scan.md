# Gap-Hunter Scan

Run after standard multi-agent passes. Each gap-hunter pass targets bugs at the SEAMS between lenses — bugs no single-lens scan can find.

**Key rule:** Do NOT report bugs a single-lens scan would catch (reentrancy, missing modifier, etc.). Only report bugs that REQUIRE 2-3 lenses to see.

---

## Pass 1: Flow Gap (execution × periphery × first-principles)

### Seam 1 — Execution × Periphery
A control path that is internally correct but whose downstream periphery call returns something that derails the trace.
