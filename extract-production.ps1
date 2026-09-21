# extract-production.ps1
#
# 1. Parses ODNR well card HTML for production history and card metadata
# 2. Adds inflation-adjusted revenue
# 3. Applies ORC 1509.062 idle / marginal tests and condition flags
#
# Outputs:
#   wells-extract.csv     raw production rows
#   revenue-bywell.csv     production rows + revenue columns
#   revenue-annual.csv     revenue by year
#   wells-tests.csv       ONE ROW PER WELL with all test results  
#   operator-summary.csv  the same tests rolled up by operator
#   odnr-verification.csv records discrepancies to send to ODNR for checking

$CURRENT_YEAR = 2026

$wells = Get-ChildItem wellcards
$ODNR = (Get-Content Oil_And_Gas_Wells_-8877270792891369451.json | ConvertFrom-Json).layers.features.attributes

# Index the ODNR attributes by API so we aren't doing a linear scan per well
$ODNRByAPI = @{}
foreach ($a in $ODNR) { $ODNRByAPI[$a.API_NO] = $a }


#region ----- Well card field extraction -----

# Pull a labelled value out of the card. Cells on the card are inconsistent:
# some close with </td>, some run straight into </tr>. Stop at either.
function Get-CardField {
    param([string]$Html, [string]$Label)

    $pattern = ">$([regex]::Escape($Label))</td>\s*<td[^>]*>([\s\S]*?)</t[dr]"
    if ($Html -match $pattern) {
        return ($Matches[1] -replace '<[^>]*>', '' -replace '&nbsp;', ' ').Trim()
    }
    return ""
}

# IP AT reads like "140 MCF & 8 BO & 2 BW"
function Get-IPValue {
    param([string]$Text, [string]$Unit)

    if ($Text -match "([\d\.]+)\s*$Unit") { return [double]$Matches[1] }
    return $null
}

function ConvertTo-DateOrNull {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { return [datetime]::Parse($Text.Trim()) } catch { return $null }
}

#endregion


#region ----- Pass 1: production rows + card metadata -----

$header = "Year,Quarter,Source,Oil (Barrels),Gas (MCF),Water (Barrels),Remarks,API Well Number,Well Status"
$header | Set-Content wells-extract.csv

$cards = @{}
$productionRows = [System.Collections.Generic.List[object]]::new()

$prodTablePattern = @"
\s*<tr class="head">\s*<td>Year</td>\s*<td class="Quarters">Quarter</td>\s*<td class="Source">Source</td>\s*<td>Oil \(Barrels\)</td>\s*<td>Gas \(MCF\) </td>\s*<td>Water \(Barrels\) </td>\s*<td>Remarks</td>\s*</tr>([\s\S\n]*?)<table
"@

foreach ($well in $wells.Name) {

    $wellcard = Get-Content "wellcards/$well" -Raw
    $wellAPI = $well -replace "\.html$", ""
    $attr = $ODNRByAPI[$wellAPI]
    $status = $attr.WELL_STATUS_DESCRIPTION

    # --- card metadata ---
    $cards[$wellAPI] = [PSCustomObject]@{
        API                = $wellAPI
        WellName           = $attr.WELL_NAME
        Operator           = $attr.COMPANY_NAME
        CardOwner          = Get-CardField $wellcard "Owner"
        County             = $attr.COUNTY
        Township           = $attr.TOWNSHIP
        Lat                = $attr.LAT83
        Lon                = $attr.LONG83
        Slant              = $attr.SLANT
        Status             = $status
        OrphanStatusJSON   = $attr.OWPS_Description
        OrphanStatusCard   = Get-CardField $wellcard "Orphan Well Status"
        ProdFormation      = $attr.PRODFM1
        TDFormation        = Get-CardField $wellcard "TD Form."
        # The card shows the most recent permit's date, not the drilling permit's
        PermitIssued       = ConvertTo-DateOrNull (Get-CardField $wellcard "Permit Issued")
        DateCommenced      = ConvertTo-DateOrNull (Get-CardField $wellcard "Date Commenced")
        DateTDReached      = ConvertTo-DateOrNull (Get-CardField $wellcard "Date Total Depth Reached")
        DateAbandoned      = ConvertTo-DateOrNull (Get-CardField $wellcard "Date Abandoned")
        DatePluggedBack    = ConvertTo-DateOrNull (Get-CardField $wellcard "Date PB")
        GroundLevel        = Get-CardField $wellcard "GL"
        DrillerTD          = Get-CardField $wellcard "DTD"
        PlugBackDepth      = Get-CardField $wellcard "PB Depth"
        CasingRecord       = Get-CardField $wellcard "Casing Record"
        Perforations       = Get-CardField $wellcard "Perforations"
        Stimulations       = Get-CardField $wellcard "Stimulations"
        IPNatural          = Get-CardField $wellcard "IP Natural"
        IPAfterTreatment   = Get-CardField $wellcard "IP AT"
        InitialRockPressure = Get-CardField $wellcard "Initial Rock Pressure"
        LogTypes           = Get-CardField $wellcard "Log Types"
        # The card links each permit PDF but doesn't say what it was for.
        # Most plugged wells have two (drill + plug).
        PermitLinks        = @([regex]::Matches($wellcard, "href='([^']+)'[^>]*>\s*Permit\s*<") | ForEach-Object { $_.Groups[1].Value })
        WellCardLink       = [regex]::Match($wellcard, "href='([^']+)'[^>]*>\s*WELLCARD\s*<").Groups[1].Value
    }
    $cards[$wellAPI] | Add-Member PermitCount $cards[$wellAPI].PermitLinks.Count

    # --- production table ---
    # Parse row by row rather than with bulk string replaces. The old
    # -replace ",,,,," hack silently mangled rows with an empty Water cell
    # (e.g. 1998 on card 34153205410000).
    if ($wellcard -match $prodTablePattern) {
        $block = $Matches[1]

        foreach ($rowMatch in [regex]::Matches($block, '<tr>([\s\S]*?)</tr>')) {
            $cells = [regex]::Matches($rowMatch.Groups[1].Value, '<td[^>]*>([\s\S]*?)</td\s*>') |
                ForEach-Object { ($_.Groups[1].Value -replace '<[^>]*>', '' -replace '&nbsp;', ' ').Trim() }

            if ($cells.Count -lt 7) { continue }

            $row = [PSCustomObject]@{
                'Year'              = $cells[0]
                'Quarter'           = $cells[1]
                'Source'            = $cells[2]
                'Oil (Barrels)'     = $cells[3]
                'Gas (MCF)'         = $cells[4]
                'Water (Barrels)'   = $cells[5]
                'Remarks'           = $cells[6]
                'API Well Number'   = $wellAPI
                #'Well Status'       = $status
            }
            $productionRows.Add($row)
        }
    }
}

$productionRows | Export-Csv -Path wells-extract.csv -NoTypeInformation

#endregion


#region ----- Pass 2: revenue -----

$OIL_PRICES = @{1986 = 15.05; 1987 = 19.20; 1988 = 15.97; 1989 = 19.64; 1990 = 24.53; 1991 = 21.54; 1992 = 20.58; 1993 = 18.43; 1994 = 17.20; 1995 = 18.43; 1996 = 22.12; 1997 = 20.61; 1998 = 14.42; 1999 = 19.34; 2000 = 30.38; 2001 = 25.98; 2002 = 26.18; 2003 = 31.08; 2004 = 41.51; 2005 = 56.64; 2006 = 66.05; 2007 = 72.34; 2008 = 99.67; 2009 = 61.95; 2010 = 79.48; 2011 = 94.88; 2012 = 94.05; 2013 = 97.98; 2014 = 93.17; 2015 = 48.66; 2016 = 43.29; 2017 = 50.80; 2018 = 65.23; 2019 = 56.99; 2020 = 39.16; 2021 = 68.13; 2022 = 94.90; 2023 = 77.58; 2024 = 76.63; 2025 = 65.39 };

# 1984 - 1996: https://www.eia.gov/dnav/ng/hist/n9190us3a.htm
# 1997 - 2026: Henry Hub
$GAS_PRICES = @{1980 = 1.59; 1981 = 1.98; 1982 = 2.46; 1983 = 2.59; 1984 = 2.66; 1985 = 2.51; 1986 = 1.94; 1987 = 1.67; 1988 = 1.69; 1989 = 1.69; 1990 = 1.71; 1991 = 1.64; 1992 = 1.74; 1993 = 2.04; 1994 = 1.85; 1995 = 1.55; 1996 = 2.17; 1997 = 2.49; 1998 = 2.09; 1999 = 2.27; 2000 = 4.31; 2001 = 3.96; 2002 = 3.38; 2003 = 5.49; 2004 = 5.90; 2005 = 8.86; 2006 = 6.73; 2007 = 6.97; 2008 = 8.86; 2009 = 3.92; 2010 = 4.37; 2011 = 4.02; 2012 = 2.77; 2013 = 3.73; 2014 = 4.37; 2015 = 2.63; 2016 = 2.51; 2017 = 2.99; 2018 = 3.15; 2019 = 2.57; 2020 = 2.03; 2021 = 3.91; 2022 = 6.45; 2023 = 2.53; 2024 = 2.19; 2025 = 3.52 };

$inflation = @{1980 = 4.5563; 1981 = 4.0537; 1982 = 3.6718; 1983 = 3.4188; 1984 = 3.2873; 1985 = 3.1308; 1986 = 3.0017; 1987 = 2.8862; 1988 = 2.7726; 1989 = 2.6557; 1990 = 2.5414; 1991 = 2.4203; 1992 = 2.3073; 1993 = 2.225; 1994 = 2.1539; 1995 = 2.0952; 1996 = 2.0342; 1997 = 1.9807; 1998 = 1.9343; 1999 = 1.8908; 2000 = 1.8519; 2001 = 1.8085; 2002 = 1.7627; 2003 = 1.7214; 2004 = 1.6976; 2005 = 1.6676; 2006 = 1.6317; 2007 = 1.5919; 2008 = 1.5561; 2009 = 1.5211; 2010 = 1.4957; 2011 = 1.4809; 2012 = 1.4561; 2013 = 1.4262; 2014 = 1.401; 2015 = 1.3775; 2016 = 1.3532; 2017 = 1.3241; 2018 = 1.3006; 2019 = 1.2739; 2020 = 1.2465; 2021 = 1.2256; 2022 = 1.183; 2023 = 1.114; 2024 = 1.063; 2025 = 1.028; 2026 = 1 }

$data = Get-Content wells-extract.csv | ConvertFrom-Csv

foreach ($well in $data) {
    $year = [int]($well.Year)

    # Clamp at BOTH ends. The original only clamped the lower bound, so a
    # 2026 row produced a $null price and silently zeroed the revenue.
    $oil_year_clamped = [Math]::Min(2025, [Math]::Max(1986, $year))
    $gas_year_clamped = [Math]::Min(2025, [Math]::Max(1980, $year))
    $inf_year_clamped = [Math]::Min(2026, [Math]::Max(1980, $year))

    $oil_price = $OIL_PRICES.$oil_year_clamped
    $gas_price = $GAS_PRICES.$gas_year_clamped
    $inf       = $inflation.$inf_year_clamped

    $bbl = [float]($well.'Oil (Barrels)')
    $mcf = [float]($well.'Gas (MCF)')

    $well | Add-Member -NotePropertyName 'Oil Revenue ($)'       -NotePropertyValue ([Math]::Round($oil_price * $bbl, 2))
    $well | Add-Member -NotePropertyName 'Gas Revenue ($)'       -NotePropertyValue ([Math]::Round($gas_price * $mcf, 2))
    $well | Add-Member -NotePropertyName 'Oil Revenue (2026 $)'  -NotePropertyValue ([Math]::Round($oil_price * $bbl * $inf, 2))
    $well | Add-Member -NotePropertyName 'Gas Revenue (2026 $)'  -NotePropertyValue ([Math]::Round($gas_price * $mcf * $inf, 2))
}

$data | ConvertTo-Csv | Set-Content revenue-bywell.csv

$oilrev = ($data | Measure-Object -Property 'Oil Revenue (2026 $)' -Sum).Sum / 1e6
$gasrev = ($data | Measure-Object -Property 'Gas Revenue (2026 $)' -Sum).Sum / 1e6
$oilrev_nominal = ($data | Measure-Object -Property 'Oil Revenue ($)' -Sum).Sum / 1e6
$gasrev_nominal = ($data | Measure-Object -Property 'Gas Revenue ($)' -Sum).Sum / 1e6

Write-Host "Oil: `$$([Math]::Round($oilrev, 2))M (2026 `$)"
Write-Host "Gas: `$$([Math]::Round($gasrev, 2))M (2026 `$)"

$yearlyTable = $data | Group-Object -Property Year | ForEach-Object {
    $oNom  = ($_.Group | Measure-Object -Property 'Oil Revenue ($)'      -Sum).Sum / 1e6
    $gNom  = ($_.Group | Measure-Object -Property 'Gas Revenue ($)'      -Sum).Sum / 1e6
    $oReal = ($_.Group | Measure-Object -Property 'Oil Revenue (2026 $)' -Sum).Sum / 1e6
    $gReal = ($_.Group | Measure-Object -Property 'Gas Revenue (2026 $)' -Sum).Sum / 1e6
    [PSCustomObject]@{
        'Year'                    = [int]$_.Name
        'Oil Revenue ($M)'        = [Math]::Round($oNom, 2)
        'Gas Revenue ($M)'        = [Math]::Round($gNom, 2)
        'Total Revenue ($M)'      = [Math]::Round($oNom + $gNom, 2)
        'Oil Revenue (2026 $M)'   = [Math]::Round($oReal, 2)
        'Gas Revenue (2026 $M)'   = [Math]::Round($gReal, 2)
        'Total Revenue (2026 $M)' = [Math]::Round($oReal + $gReal, 2)
    }
} | Sort-Object Year | Where-Object Year -gt 0

$yearlyTable += [PSCustomObject]@{
    'Year'                    = "Total"
    'Oil Revenue ($M)'        = [Math]::Round($oilrev_nominal, 2)
    'Gas Revenue ($M)'        = [Math]::Round($gasrev_nominal, 2)
    'Total Revenue ($M)'      = [Math]::Round($oilrev_nominal + $gasrev_nominal, 2)
    'Oil Revenue (2026 $M)'   = [Math]::Round($oilrev, 2)
    'Gas Revenue (2026 $M)'   = [Math]::Round($gasrev, 2)
    'Total Revenue (2026 $M)' = [Math]::Round($oilrev + $gasrev, 2)
}

$yearlyTable | Format-Table -AutoSize
$yearlyTable | Export-Csv -Path "revenue-annual.csv" -NoTypeInformation

#endregion


#region ----- Pass 3: ORC 1509.062 tests -----

# Thresholds
$MARGINAL_GAS_MCF   = 100    # 1509.062(A)(2): 100,000 cf == 100 MCF
$MARGINAL_OIL_BBL   = 15     # 1509.062(A)(2)
$WATER_OIL_RATIO    = 5      # watered-out heuristic, not statutory

# 1509.062(A)(1) counts reporting periods, and 1509.11 sets the period:
# annual for non-horizontal wells, quarterly for horizontal wells. The
# production data here is annual, so convert both to years.
$IDLE_PERIODS_VERT  = 2      # 2 annual periods
$IDLE_PERIODS_HORIZ = 8      # 8 quarterly periods
$IDLE_YEARS_VERT    = $IDLE_PERIODS_VERT
$IDLE_YEARS_HORIZ   = [Math]::Ceiling($IDLE_PERIODS_HORIZ / 4)

# The current year's report isn't due until next year, so the most recent
# period that can be judged is last year.
$LAST_COMPLETE_YEAR = $CURRENT_YEAR - 1

$byWell = $data | Group-Object -Property 'API Well Number'
$wellIndex = @{}
foreach ($g in $byWell) { $wellIndex[$g.Name] = $g.Group }

$results = foreach ($api in $cards.Keys) {

    $card = $cards[$api]
    $rows = $wellIndex[$api]

    # --- collapse to one record per year (cards contain duplicate year rows) ---
    $years = @{}
    foreach ($r in $rows) {
        $y = 0
        if (-not [int]::TryParse($r.Year, [ref]$y)) { continue }
        if (-not $years.ContainsKey($y)) {
            $years[$y] = [PSCustomObject]@{ Oil = 0.0; Gas = 0.0; Water = 0.0 }
        }
        $years[$y].Oil   += [double]($r.'Oil (Barrels)'   -as [double])
        $years[$y].Gas   += [double]($r.'Gas (MCF)'       -as [double])
        $years[$y].Water += [double]($r.'Water (Barrels)' -as [double])
    }

    $reportedYears = $years.Keys | Sort-Object
    $hasProduction = $reportedYears.Count -gt 0

    $firstYear = if ($hasProduction) { $reportedYears[0] } else { $null }
    $lastYear  = if ($hasProduction) { $reportedYears[-1] } else { $null }

    # Longest run of consecutive years with zero oil AND zero gas, over the
    # well's whole history. Missing years inside the range count as "no
    # reported production". Informational only: a run that ended when the
    # well resumed production is no longer actionable, and card data can't
    # show whether the gap was covered by temporary inactive status.
    $maxConsecZero = 0
    $run = 0
    $lastProducingYear = $null

    if ($hasProduction) {
        for ($y = $firstYear; $y -le $lastYear; $y++) {
            $produced = $false
            if ($years.ContainsKey($y)) {
                $produced = ($years[$y].Oil -gt 0) -or ($years[$y].Gas -gt 0)
            }
            if ($produced) {
                $run = 0
                $lastProducingYear = $y
            }
            else {
                $run++
                if ($run -gt $maxConsecZero) { $maxConsecZero = $run }
            }
        }
    }

    # Completed reporting years since the last report / last production.
    # Silence since the last report counts as unreported periods. A well that
    # filed reports but never produced is idle from its first report year.
    $yearsSinceLastReport = if ($hasProduction) {
        [Math]::Max(0, $LAST_COMPLETE_YEAR - $lastYear)
    } else { $null }
    $yearsSinceProduction = if ($lastProducingYear) {
        [Math]::Max(0, $LAST_COMPLETE_YEAR - $lastProducingYear)
    } elseif ($hasProduction) {
        [Math]::Max(0, $LAST_COMPLETE_YEAR - $firstYear + 1)
    } else { $null }

    $isHorizontal = ($card.Slant -eq 'H')
    $idleThreshold = if ($isHorizontal) { $IDLE_YEARS_HORIZ } else { $IDLE_YEARS_VERT }

    # --- lifetime totals ---
    $lifeOil   = ($years.Values | Measure-Object -Property Oil   -Sum).Sum
    $lifeGas   = ($years.Values | Measure-Object -Property Gas   -Sum).Sum
    $lifeWater = ($years.Values | Measure-Object -Property Water -Sum).Sum
    $lifeRev   = ($rows | Measure-Object -Property 'Oil Revenue (2026 $)' -Sum).Sum +
                 ($rows | Measure-Object -Property 'Gas Revenue (2026 $)' -Sum).Sum

    $waterOilRatio = if ($lifeOil -gt 0) { [Math]::Round($lifeWater / $lifeOil, 2) } else { $null }

    # --- most recent complete reported year, for the marginal test ---
    $latestYear = $reportedYears | Where-Object { $_ -le $LAST_COMPLETE_YEAR } | Select-Object -Last 1
    $latestOil = if ($null -ne $latestYear) { $years[$latestYear].Oil } else { $null }
    $latestGas = if ($null -ne $latestYear) { $years[$latestYear].Gas } else { $null }

    # --- decline against initial potential ---
    $ipGas = Get-IPValue $card.IPAfterTreatment 'MCF'
    $ipOil = Get-IPValue $card.IPAfterTreatment 'BO'
    if ($null -eq $ipGas) { $ipGas = Get-IPValue $card.IPNatural 'MCF' }
    if ($null -eq $ipOil) { $ipOil = Get-IPValue $card.IPNatural 'BO' }

    $peakGas = if ($hasProduction) { ($years.Values | Measure-Object -Property Gas -Maximum).Maximum } else { $null }
    $declineFromPeak = if ($peakGas -gt 0 -and $null -ne $latestGas) {
        [Math]::Round(1 - ($latestGas / $peakGas), 3)
    } else { $null }

    # --- well age ---
    $spud = if ($card.DateCommenced) { $card.DateCommenced } else { $card.PermitIssued }
    $wellAge = if ($spud) { $CURRENT_YEAR - $spud.Year } else { $null }

    # --- flags ---
    # (A)(1) is judged on the well's current state: idle through the most
    # recent completed periods.
    $flagIdle = $hasProduction -and
                ($card.Status -eq 'Producing') -and
                ($null -ne $yearsSinceProduction) -and
                ($yearsSinceProduction -ge $idleThreshold)

    # Idle at some point in the past but has produced since. Not reportable.
    $flagPastIdle = $hasProduction -and
                    (-not $flagIdle) -and
                    ($maxConsecZero -ge $idleThreshold)

    $flagMarginal = ($null -ne $latestYear) -and
                    ($card.Status -eq 'Producing') -and
                    ($latestGas -lt $MARGINAL_GAS_MCF) -and
                    ($latestOil -lt $MARGINAL_OIL_BBL)

    $flagNoRecentReport = ($card.Status -eq 'Producing') -and
                          ($null -ne $yearsSinceLastReport) -and
                          ($yearsSinceLastReport -ge $idleThreshold)

    $flagNoProductionData = ($card.Status -eq 'Producing') -and (-not $hasProduction)

    $flagWaterDominant = ($null -ne $waterOilRatio) -and ($waterOilRatio -gt $WATER_OIL_RATIO)

    $flagNoCasingRecord = [string]::IsNullOrWhiteSpace($card.CasingRecord)

    $flagPluggedNoDate = ($card.Status -match 'Plugged') -and ($null -eq $card.DateAbandoned)

    $flagOrphanQueued = -not [string]::IsNullOrWhiteSpace($card.OrphanStatusJSON)

    # Listed as producing, stopped reporting, and has a second permit on file,
    # which on plugged wells is usually the plug permit. Suggests a plugging
    # ODNR never recorded, but the permit could also be for other work
    # (deepening, rework). Needs the permit checked before acting.
    $flagPossibleUnrecordedPlug = $flagNoRecentReport -and ($card.PermitCount -ge 2)

    # --- priority score (heuristic, tune to taste) ---
    $score = 0
    # Current idleness is scored once, plus a bump for long idle stretches.
    # A past idle period that has since ended is only a weak signal about
    # the operator.
    if ($flagIdle)             { $score += 5 }
    if ($flagIdle -and $yearsSinceProduction -ge 10) { $score += 2 }
    if ($flagPastIdle)         { $score += 1 }
    if ($flagNoProductionData) { $score += 4 }
    if ($flagNoRecentReport)   { $score += 2 }
    if ($flagMarginal)         { $score += 1 }
    if ($flagNoCasingRecord)   { $score += 2 }
    if ($flagPluggedNoDate)    { $score += 1 }
    if ($flagWaterDominant)    { $score += 1 }
    if ($wellAge -gt 50)       { $score += 1 }

    # --- report routing ---
    $route = if ($flagOrphanQueued) {
        'Already in Orphan Well Program - query tier, do not re-report'
    }
    elseif ($flagPossibleUnrecordedPlug) {
        'Records discrepancy - ask ODNR to verify plugging and update status'
    }
    elseif ($card.Status -eq 'Producing' -and ($flagIdle -or $flagNoProductionData)) {
        'Compliance complaint - ORC 1509.062(A)(1)'
    }
    elseif ($flagMarginal) {
        'Compliance complaint - ORC 1509.062(A)(2), discretionary'
    }
    elseif ($card.Status -match 'Plugged|Final Restoration') {
        'No action - verify plugging quality only if field evidence warrants'
    }
    else {
        'No action'
    }

    [PSCustomObject]@{
        'API'                        = $api
        'Well Name'                  = $card.WellName
        'Operator'                   = $card.Operator
        'Priority Score'             = $score
        'FLAG Idle 1509.062(A)(1)'   = $flagIdle
        'FLAG Past Idle (Resumed)'   = $flagPastIdle
        'FLAG Marginal 1509.062(A)(2)' = $flagMarginal
        'FLAG No Recent Report'      = $flagNoRecentReport
        'FLAG No Production Data'    = $flagNoProductionData
        'FLAG Water Dominant'        = $flagWaterDominant
        'FLAG No Casing Record'      = $flagNoCasingRecord
        'FLAG Plugged No Date'       = $flagPluggedNoDate
        'FLAG In Orphan Program'     = $flagOrphanQueued
        'FLAG Possible Unrecorded Plugging' = $flagPossibleUnrecordedPlug
        'Report Route'               = $route
        'Card Owner'                 = $card.CardOwner
        'County'                     = $card.County
        'Township'                   = $card.Township
        'Lat'                        = $card.Lat
        'Lon'                        = $card.Lon
        'Slant'                      = $card.Slant
        'Well Status'                = $card.Status
        'Orphan Status'              = $card.OrphanStatusJSON
        'Prod. Formation'            = $card.ProdFormation
        'TD Formation'               = $card.TDFormation
        'Last Permit Issued'         = if ($card.PermitIssued) { $card.PermitIssued.ToString('yyyy-MM-dd') } else { '' }
        'Date Commenced'             = if ($card.DateCommenced) { $card.DateCommenced.ToString('yyyy-MM-dd') } else { '' }
        'Date Abandoned'             = if ($card.DateAbandoned) { $card.DateAbandoned.ToString('yyyy-MM-dd') } else { '' }
        'Well Age (yrs)'             = $wellAge
        'Driller TD (ft)'            = $card.DrillerTD
        'PB Depth (ft)'              = $card.PlugBackDepth
        'Has Casing Record'          = -not $flagNoCasingRecord
        'Permit Count'               = $card.PermitCount
        'IP Gas (MCF)'               = $ipGas
        'IP Oil (BO)'                = $ipOil
        'First Report Year'          = $firstYear
        'Last Report Year'           = $lastYear
        'Last Producing Year'        = $lastProducingYear
        'Years Since Last Report'    = $yearsSinceLastReport
        'Years Since Production'     = $yearsSinceProduction
        'Max Consec Zero Years'      = $maxConsecZero
        'Idle Threshold (yrs)'       = $idleThreshold
        'Latest Complete Year'       = $latestYear
        'Latest Year Oil (bbl)'      = $latestOil
        'Latest Year Gas (MCF)'      = $latestGas
        'Lifetime Oil (bbl)'         = $lifeOil
        'Lifetime Gas (MCF)'         = $lifeGas
        'Lifetime Water (bbl)'       = $lifeWater
        'Water:Oil Ratio'            = $waterOilRatio
        'Decline From Peak Gas'      = $declineFromPeak
        'Lifetime Revenue (2026 $)'  = [Math]::Round($lifeRev, 2)
    }
}

$results = $results | Sort-Object 'Priority Score', 'Years Since Production' -Descending
$results | Export-Csv -Path wells-flags.csv -NoTypeInformation

#endregion


#region ----- Pass 4: operator roll-up -----

# Batch complaints by operator: a pattern across several wells carries more
# weight with ODNR than the same wells filed one at a time (ORC 1509.224).
$operatorSummary = $results |
    Where-Object { $_.'Report Route' -like 'Compliance complaint*' } |
    Group-Object Operator |
    ForEach-Object {
        [PSCustomObject]@{
            'Operator'              = $_.Name
            'Flagged Wells'         = $_.Count
            'Idle (A)(1)'           = ($_.Group | Where-Object { $_.'FLAG Idle 1509.062(A)(1)' }).Count
            'Marginal (A)(2)'       = ($_.Group | Where-Object { $_.'FLAG Marginal 1509.062(A)(2)' }).Count
            'No Production Data'    = ($_.Group | Where-Object { $_.'FLAG No Production Data' }).Count
            'Max Consec Zero Years' = ($_.Group | Measure-Object 'Max Consec Zero Years' -Maximum).Maximum
            'Mean Priority Score'   = [Math]::Round(($_.Group | Measure-Object 'Priority Score' -Average).Average, 1)
            'APIs'                  = ($_.Group.API -join '; ')
        }
    } | Sort-Object 'Flagged Wells' -Descending

$operatorSummary | Export-Csv -Path operator-summary.csv -NoTypeInformation

#endregion


#region ----- Pass 5: ODNR verification requests -----

# Wells whose records don't match what's likely on the ground. These go to
# ODNR as a request to check and correct, not as a complaint.
$verification = $results |
    Where-Object { $_.'Report Route' -like 'Records discrepancy*' } |
    ForEach-Object {
        $card = $cards[$_.API]
        [PSCustomObject]@{
            'API'                     = $_.API
            'Well Name'               = $_.'Well Name'
            'Operator'                = $_.Operator
            'County'                  = $_.County
            'Township'                = $_.Township
            'Lat'                     = $_.Lat
            'Lon'                     = $_.Lon
            'Listed Status'           = $_.'Well Status'
            'Issue'                   = 'Listed as producing but no production reported since {0}; {1} permits on file, second may be a plug permit' -f $_.'Last Report Year', $_.'Permit Count'
            'Request'                 = 'Verify whether well was plugged; update status or pursue as idle/orphan well'
            'Last Permit Issued'      = $_.'Last Permit Issued'
            'Date Commenced'          = $_.'Date Commenced'
            'Date Abandoned'          = $_.'Date Abandoned'
            'Last Report Year'        = $_.'Last Report Year'
            'Last Producing Year'     = $_.'Last Producing Year'
            'Years Since Last Report' = $_.'Years Since Last Report'
            'Permit Count'            = $_.'Permit Count'
            'Priority Score'          = $_.'Priority Score'
            'Well Card'               = $card.WellCardLink -replace "download.ashx?.*", "WellSummaryCard.asp?api=$($_.API)"
            'Permit Documents'        = $card.PermitLinks -join ' ; '
            'Map'                     = 'https://www.google.com/maps/search/?api=1&query={0},{1}' -f $_.Lat, $_.Lon
            'Permit Type Confirmed'   = ''
            'Field Notes'             = ''
        }
    } | Sort-Object { [int]$_.'Years Since Last Report' } -Descending

$verification | Export-Csv -Path odnr-verification.csv -NoTypeInformation

#endregion


#region ----- Console summary -----

Write-Host ""
Write-Host "Wells parsed:              $($cards.Count)"
Write-Host "Producing:                 $(($results | Where-Object 'Well Status' -eq 'Producing').Count)"
Write-Host "FLAG Idle (A)(1):          $(($results | Where-Object 'FLAG Idle 1509.062(A)(1)').Count)"
Write-Host "FLAG Past idle (resumed):  $(($results | Where-Object 'FLAG Past Idle (Resumed)').Count)"
Write-Host "FLAG Marginal (A)(2):      $(($results | Where-Object 'FLAG Marginal 1509.062(A)(2)').Count)"
Write-Host "FLAG No production data:   $(($results | Where-Object 'FLAG No Production Data').Count)"
Write-Host "FLAG No casing record:     $(($results | Where-Object 'FLAG No Casing Record').Count)"
Write-Host "FLAG Water dominant:       $(($results | Where-Object 'FLAG Water Dominant').Count)"
Write-Host "In orphan program:         $(($results | Where-Object 'FLAG In Orphan Program').Count)"
Write-Host "Possible unrecorded plug:  $(($results | Where-Object 'FLAG Possible Unrecorded Plugging').Count)"
Write-Host ""
Write-Host "Top 15 by priority score:"
$results | Select-Object -First 15 API, Operator, 'Well Status', 'Max Consec Zero Years', 'Years Since Production', 'Priority Score' | Format-Table -AutoSize

#endregion
