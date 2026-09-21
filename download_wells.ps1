
$files = Get-ChildItem Oil_And_Gas_Wells_-*.json
$i = 1
$select = 1

if ($files.count -eq 0) {
    throw "No Oil_And_Gas_Wells.json file found`nDownload from the ODNR map viewer"
}
if ($files.count -ne 1) {
    foreach ($file in $files)
    {
        if ($i -eq 1) {
            write-host "[$i] " -NoNewline
        } else {
            write-host "$i  " -NoNewline
        }
        write-host "$($file.name)"
        $i++
    }
}

$oil = get-content $files[$select-1] | ConvertFrom-Json 

$i = 1

if ($oil.layers.features.count -gt 30) {
    $rate_limited = $True
}
foreach ($well in $oil.layers.features) {
    $api = $well.attributes.API_NO
    if (test-path "wellcards/$api.html") {
        write-host "SKIP API_NO = $API ($i/$($oil.layers.features.count))"
    }
    else {
        write-host "GET API_NO = $API ($i/$($oil.layers.features.count))"
        $wellcard = $null
        $wellcard = Invoke-RestMethod "https://gis.ohiodnr.gov/MapViewer/WellSummaryCard.asp?api=$api" 

        if ($rate_limited) {
            $cooldown = get-random -minimum 10 -maximum 20 # Set your time here
            
            for ($j = $cooldown; $j -gt 0; $j--) {            
                Write-Host "`rCooldown: $j of $cooldown seconds " -NoNewLine -ForegroundColor Cyan
                Start-Sleep -Seconds 1
            }
            
            Write-Host "`rCooldown: 0 of $cooldown seconds " -ForegroundColor Cyan
        }

        if ($wellcard) {
            $wellcard = $wellcard -replace "href='/", "href='https://gis.ohiodnr.gov/"
            $wellcard | set-content "wellcards/$api.html"
            
        }
        else {
            throw "FAILED: https://gis.ohiodnr.gov/MapViewer/WellSummaryCard.asp?api=$api" 
        }
    }
    $i++
}
