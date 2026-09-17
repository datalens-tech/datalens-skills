# DataLens On-premises sizing (single-node)

Source: the spec calculator, "Presets" tab (snapshot 2026-08).

## How to use

1. Ask for the approximate number of users and the scenario:
   - **Basic** — viewing dashboards, basic functionality (→ basic install)
   - **All features** — export, file connectors, editor, etc. (→ full/custom)
2. Round the user count **up** to the nearest table row.
3. The table values are the minimum machine configuration.

## Pilot (the "skip the calculation" option)

**16 vCPU / 32 GiB RAM / 100 GiB SSD** — the minimum recommended config. Enough for a pilot with
all the main features; can be scaled up later.

## Table

| Users | Scenario | vCPU | RAM, GiB | SSD, GiB |
|---:|---|---:|---:|---:|
| 100 | Basic | 16 | 32 | 100 |
| 100 | All features | 32 | 64 | 100 |
| 250 | Basic | 32 | 64 | 100 |
| 250 | All features | 64 | 128 | 100 |
| 500 | Basic | 64 | 128 | 100 |
| 500 | All features | 96 | 192 | 100 |
| 1000 | Basic | 96 | 192 | 100 |
| 1000 | All features | 192 | 384 | 100 |
| 5000 | Basic | 448 | 896 | 100 |
| 5000 | All features | 640 | 1280 | 100 |
| 10000 | Basic | 768 | 1536 | 100 |
| 10000 | All features | 1216 | 2432 | 100 |

## Caveats

- The minimum is always 16 vCPU / 32 GiB, even for very small teams.
- 100 GiB SSD is the minimum for the system and the embedded databases; actual growth depends on
  the volume of file connectors and usage tracking.
- "All features" are calculated with an async factor of ×1. Under heavy background load (mass
  scheduled exports) budget ×2–×4 on CPU/RAM — the exact calculation is in the extended calculator,
  out of scope for this skill.
- The upper rows (5000+) on a single machine are already questionable, and >10,000 users means
  individual sizing and a multi-node cluster; suggest the engineer contact the DataLens team.
