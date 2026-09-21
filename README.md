# ODNR Well Analysis

This is an automated analysis tool of my [Well Card Analyzer](https://asalimian.github.io/well_card_analyzer.html)
## Usage
> Prerequisites: [Powershell](https://aka.ms/powershell)
 1. Checkout, or download this repository to your computer and extract
 2. Find your wells on the [Oil & Gas Wells Viewer](https://experience.arcgis.com/experience/5fd9c17bc933417d9bd8d7c1dff404aa/)
 3. Use the Actions button (four squares in the circle) to filter wells to a granular level
 4. Use the Actions button to export to a json file, and save in the folder
 5. Run the `download-wells.ps1` - this will download the wellcards to a subfolder.
    If your file has more than 30 wells, it will wait 20 seconds between downloads to reduce traffic to the server
 6. Run `extract-production.ps1`


## Outputs

### download-wells output

| Path | Contents |
|---|---|
| `wellcards/<api>.html` | One well summary card per API number, as served by ODNR. Relative `href='/…'` links are rewritten to absolute `https://gis.ohiodnr.gov/…` so the saved copy stays clickable offline. These are the input to `extract-production.ps1`. |

### extract-production output


| File | Grain | Contents |
|---|---|---|
| `wells-extract.csv` | one row per well per reported period | Raw production history scraped from the cards: `Year`, `Quarter`, `Source` (e.g. `RBDMS`), `Oil (Barrels)`, `Gas (MCF)`, `Water (Barrels)`, `Remarks`, `API Well Number`. Cards can contain duplicate year rows; this file preserves them as-is. |
| `revenue-bywell.csv` | same as `wells-extract.csv` | The same rows with four revenue columns appended: `Oil Revenue ($)` and `Gas Revenue ($)` at the year's price, plus `Oil Revenue (2026 $)` and `Gas Revenue (2026 $)` inflation-adjusted to 2026 dollars. Oil prices cover 1986–2025, gas 1980–2025; years outside those ranges are clamped to the nearest end. |
| `revenue-annual.csv` | one row per year, plus a `Total` row | Portfolio revenue rolled up by year, in millions: nominal and 2026-dollar oil, gas and total. |
| `wells-flags.csv` | one row per well | The main analysis table — roughly 50 columns. Identity and location (`API`, `Well Name`, `Operator`, `County`, `Township`, `Lat`, `Lon`), card metadata (`Slant`, `Well Status`, `Orphan Status`, formations, permit and spud dates, `Driller TD (ft)`, `PB Depth (ft)`, initial potential), derived production history (`First`/`Last Report Year`, `Last Producing Year`, `Years Since Production`, `Max Consec Zero Years`, lifetime oil/gas/water, `Water:Oil Ratio`, `Decline From Peak Gas`, `Lifetime Revenue (2026 $)`), the `FLAG …` columns, a `Priority Score`, and a `Report Route`. Sorted by priority score descending. |
| `operator-summary.csv` | one row per operator | The `wells-flags.csv` grouped by operator: `Flagged Wells`, counts for the `(A)(1)` / `(A)(2)` / no-data tests, worst `Max Consec Zero Years`, `Mean Priority Score`, and the semicolon-joined `APIs`. Sorted by flagged-well count, so the operators worth batching under ORC 1509.224 come first. |
| `odnr-verification.csv` | one row per discrepancy | Wells whose status looks like it hasn't been updated. Usually these have a second permit for plugging and no reported production for years, but are classified by ODNR as "Producing"   |


