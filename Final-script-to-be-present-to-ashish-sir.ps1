
$RequiredModules = @('Az.Accounts','Az.Resources','Az.Compute')
foreach ($m in $RequiredModules) {
    if (-not (Get-Module -ListAvailable $m)) {
        Install-Module $m -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module $m -ErrorAction Stop | Out-Null
}

try { Get-AzContext -ErrorAction Stop | Out-Null }
catch { Connect-AzAccount -ErrorAction Stop | Out-Null }


function Normalize-Region([string]$region){
    if (-not $region) { return $null }
    return ($region -replace "[^A-Za-z0-9]", "").ToLower()
}

function Normalize-Os([string]$os){
    if (-not $os) { return "Linux" }
    $t = $os.ToLower()
    if ($t -like "win*") { return "Windows" }
    return "Linux"
}

function Normalize-ArmSku([string]$raw){
    if (-not $raw) { return $null }
    if ($raw -match "^Standard_") { return $raw }
    return "Standard_$raw"
}


function Get-InstanceSeries {
    param([string]$vmSize)

    if (-not $vmSize) { return $null }

    $name = $vmSize -replace '^Standard_', ''
    $parts = $name -split '_'
    $base = $parts[0]
    $letters = ($base -replace '\d+$','')
    $version = $parts | Where-Object { $_ -match '^v\d+$' } | Select-Object -First 1

    if ($version) {
        return "$letters$version"
    }
    else {
        return $letters
    }
}


function Simplify-PowerState($s){
    if (-not $s) { return $null }

    switch -Regex ($s.ToLower()) {
        'running'      { 'Running' }
        'starting'     { 'Starting' }
        'stopping'     { 'Stopping' }
        'stopped'      { 'Stopped' }
        'deallocating' { 'Deallocating' }
        'deallocated'  { 'Deallocated' }
        default        { $s }
    }
}


$RegionSkuCache = @{}

function Get-RegionSkuMap([string]$loc){

    if ($RegionSkuCache.ContainsKey($loc)) {
        return $RegionSkuCache[$loc]
    }

    $skus = Get-AzComputeResourceSku -Location $loc |
            Where-Object { $_.ResourceType -eq 'virtualMachines' }

    $map = @{}

    foreach ($sku in $skus) {

        $cap = @{}
        foreach ($c in $sku.Capabilities) {
            $cap[$c.Name] = $c.Value
        }

        $map[$sku.Name] = [PSCustomObject]@{
            Cores        = $cap['vCPUs']
            MemoryGB     = $cap['MemoryGB']
            TempStorage  = [math]::Round(($cap['MaxResourceVolumeMB'] / 1024),2)
            MaxDisks     = $cap['MaxDataDiskCount']
        }
    }

    $RegionSkuCache[$loc] = $map
    return $map
}


$VMList = New-Object System.Collections.Generic.List[object]
$AllSubs = Get-AzSubscription

foreach ($sub in $AllSubs) {

    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    $vms = Get-AzVM -Status -ErrorAction SilentlyContinue
    if (!$vms) { continue }

    foreach ($vm in $vms) {

        $loc   = $vm.Location
        $size  = $vm.HardwareProfile.VmSize
        $specs = Get-RegionSkuMap -loc $loc
        $hw    = $specs[$size]

        $os = $vm.StorageProfile.OSDisk.OsType
        if (-not $os) {
            if     ($vm.OsProfile.WindowsConfiguration) { $os = "Windows" }
            elseif ($vm.OsProfile.LinuxConfiguration)   { $os = "Linux" }
            else { $os = "Unknown" }
        }

        $VMList.Add([PSCustomObject]@{
            SubscriptionName = $sub.Name
            SubscriptionId   = $sub.Id
            ResourceGroup    = $vm.ResourceGroupName
            VMName           = $vm.Name
            Region           = $loc
            OperatingSystem  = $os
            VMSize           = $size
            Series           = Get-InstanceSeries $size
            vCPU             = $hw.Cores
            RAM_GB           = $hw.MemoryGB
            TempStorage_GB   = $hw.TempStorage
            MaxDataDisks     = $hw.MaxDisks
            PowerState       = Simplify-PowerState $vm.PowerState
            OSDiskType       = $vm.StorageProfile.OsDisk.ManagedDisk.StorageAccountType
        })
    }
}



function Is-SpotOrLowPriority($mn,$pn){
    $m = ($mn | Out-String).Trim()
    $p = ($pn | Out-String).Trim()
    return ($m -match 'spot|low priority') -or ($p -match 'spot|low priority')
}

function Is-DevTest($type,$mn,$pn){
    $t = ($type | Out-String).Trim()
    $m = ($mn | Out-String).Trim()
    $p = ($pn | Out-String).Trim()
    return ($t -eq 'DevTestConsumption') -or ($m -match 'DevTest') -or ($p -match 'DevTest')
}

$HaveSystemWeb = $true
try { Add-Type -AssemblyName System.Web -ErrorAction Stop }
catch { $HaveSystemWeb = $false }

function Build-PricesApiUrl {
    param(
        [string]$Filter,
        [string]$Currency = "USD",
        [string]$ApiVersion = "2023-01-01-preview"
    )

    $base = "https://prices.azure.com/api/retail/prices"

    if ($HaveSystemWeb) {

        $u = [System.UriBuilder]::new($base)
        $q = [System.Web.HttpUtility]::ParseQueryString("")
        $q["api-version"] = $ApiVersion
        $q["currencyCode"] = $Currency
        $q["meterRegion"] = "'primary'"
        $q["`$filter"] = $Filter
        $u.Query = $q.ToString()
        return $u.Uri.AbsoluteUri
    }

    $f = [System.Uri]::EscapeDataString($Filter)
    return "$base?api-version=$ApiVersion&currencyCode=$Currency&meterRegion='primary'&`$filter=$f"
}

function Get-PricesApiItems($Filter,$Currency="USD",$ApiVersion="2023-01-01-preview"){
    $url = Build-PricesApiUrl -Filter $Filter -Currency $Currency -ApiVersion $ApiVersion

    $all = New-Object System.Collections.Generic.List[object]

    while ($url) {
        try {
            $resp = Invoke-RestMethod -Uri $url -Method GET -TimeoutSec 60
            if ($resp.Items) { $all.AddRange($resp.Items) }
            $url = $resp.NextPageLink
        }
        catch { break }
    }

    return ,$all
}

function Select-VmItemForOs($Items,$Os){

    if (-not $Items) { return $null }

    $filtered = $Items | Where-Object {
        -not (Is-SpotOrLowPriority $_.meterName $_.productName) -and
        -not (Is-DevTest $_.type $_.meterName $_.productName)
    }

    if ($Os -eq "Windows") {
        $match = $filtered | Where-Object { $_.productName -match "Windows" } | Select-Object -First 1
        if ($match) { return $match }
        return ($filtered | Select-Object -First 1)
    }

    $linux = $filtered | Where-Object { $_.productName -notmatch "Windows" } | Select-Object -First 1
    if ($linux) { return $linux }
    return ($filtered | Select-Object -First 1)
}

function Find-PaygItem($region,$sku,$os,$currency,$apiVersion){

    $p = $sku -replace '^Standard_',''
    $patterns = @(
        "armSkuName eq '$sku'",
        "contains(armSkuName,'$p')",
        "contains(skuName,'$p')",
        "contains(meterName,'$p')"
    )

    foreach ($pt in @('Consumption','DevTestConsumption')) {
        foreach ($x in $patterns) {

            $f = "serviceName eq 'Virtual Machines' and armRegionName eq '$region' and $x and priceType eq '$pt'"

            $items = Get-PricesApiItems -Filter $f -Currency $currency -ApiVersion $apiVersion
            if ($items) {
                $hit = Select-VmItemForOs -Items $items -Os $os
                if ($hit) { return $hit }
            }
        }
    }

    return $null
}

function Find-SpSourceFromConsumption($region,$sku,$currency,$apiVersion){

    $p = $sku -replace '^Standard_',''
    $patterns = @(
        "armSkuName eq '$sku'",
        "contains(armSkuName,'$p')",
        "contains(skuName,'$p')",
        "contains(meterName,'$p')"
    )

    foreach ($x in $patterns) {

        $f = "serviceName eq 'Virtual Machines' and armRegionName eq '$region' and $x and priceType eq 'Consumption'"

        $items = Get-PricesApiItems -Filter $f -Currency $currency -ApiVersion $apiVersion

        if ($items) {

            $clean = $items | Where-Object { -not (Is-SpotOrLowPriority $_.meterName $_.productName) }
            $sp    = $clean | Where-Object { $_.savingsPlan }

            if ($sp)   { return ($sp | Select-Object -First 1) }
            if ($clean){ return ($clean | Select-Object -First 1) }
        }
    }

    return $null
}

function Find-RiItem($region,$sku,$os,$term,$currency,$apiVersion){

    $p = $sku -replace '^Standard_',''
    $patterns = @(
        "armSkuName eq '$sku'",
        "contains(armSkuName,'$p')",
        "contains(skuName,'$p')",
        "contains(meterName,'$p')"
    )

    foreach ($x in $patterns) {

        $f = "serviceName eq 'Virtual Machines' and armRegionName eq '$region' and $x and priceType eq 'Reservation' and reservationTerm eq '$term'"

        $items = Get-PricesApiItems -Filter $f -Currency $currency -ApiVersion $apiVersion

        if ($items) {

            $clean = $items | Where-Object { -not (Is-SpotOrLowPriority $_.meterName $_.productName) }
            $hit   = Select-VmItemForOs -Items $clean -Os $os

            if ($hit) { return $hit }
        }
    }

    return $null
}



function Resolve-VmPricing($Region,$ArmSkuName,$Os,$Currency="USD",$ApiVersion="2023-01-01-preview"){

    $out = [ordered]@{
        PAYG_Hourly               = $null
        PAYG_9h                   = $null
        PAYG_24h                  = $null
        PAYG_Monthly              = $null     
        SP_Monthly_1Yr            = $null
        SP_1Yr_Upfront            = $null
        SP_Monthly_3Yr            = $null
        SP_3Yr_Upfront            = $null
        #SavingsPlan1Y_Monthly    = $null
        #SavingsPlan3Y_Monthly    = $null
        RI1Y_Upfront              = $null
        RI1Y_Monthly              = $null
        RI3Y_Upfront              = $null
        RI3Y_Monthly              = $null
        Currency                  = $Currency
        MeterId                   = $null
        MeterName                 = $null
        ProductName               = $null
        UnitOfMeasure             = $null
        EffectiveStartDate        = $null
        Notes                     = $null
    }

    $region = Normalize-Region $Region
    $sku    = Normalize-ArmSku $ArmSkuName
    $os     = Normalize-Os $Os

    if (-not $region) { $out.Notes = "Missing region"; return [pscustomobject]$out }
    if (-not $sku)    { $out.Notes = "Missing SKU";    return [pscustomobject]$out }

    # PAYG
    try {
        $payg = Find-PaygItem $region $sku $os $Currency $ApiVersion

        if ($payg) {

            $r = [decimal]$payg.retailPrice

            $out.PAYG_Hourly        = [math]::Round($r,6)
            $out.PAYG_9h            = [math]::Round(($r*9),6)
            $out.PAYG_24h           = [math]::Round(($r*24),6)
            $out.PAYG_Monthly       = [math]::Round(($r*730),6)
            $out.MeterId            = $payg.meterId
            $out.MeterName          = $payg.meterName
            $out.ProductName        = $payg.productName
            $out.UnitOfMeasure      = $payg.unitOfMeasure
            $out.EffectiveStartDate = $payg.effectiveStartDate
        }
        else {
            $out.Notes = "PAYG not found"
        }
    }
    catch {
        $out.Notes = "PAYG error: $($_.Exception.Message)"
    }


# AHB PAYG (Windows only)

try {
    if ($os -eq "Windows") {

        # AHB = Linux PAYG compute price
        $ahbPayg = Find-PaygItem $region $sku "Linux" $Currency $ApiVersion

        if ($ahbPayg) {
            $ahbRate = [decimal]$ahbPayg.retailPrice

            $out.AHB_Hourly  = [math]::Round($ahbRate,6)
            $out.AHB_9h      = [math]::Round(($ahbRate*9),6)
            $out.AHB_24h     = [math]::Round(($ahbRate*24),6)
            $out.AHB_Monthly = [math]::Round(($ahbRate*730),6)
        }
        else {
            $out.AHB_Notes = "AHB price not found"
        }
    }
    else {
        
        $out.AHB_Hourly  = $out.PAYG_Hourly
        $out.AHB_9h      = $out.PAYG_9h
        $out.AHB_24h     = $out.PAYG_24h
        $out.AHB_Monthly = $out.PAYG_Monthly
    }
}
catch {
    $out.AHB_Notes = "AHB error: $($_.Exception.Message)"
}






    #Saving -Plan
    try {
        if ($payg -and $payg.savingsPlan) {
            $sp = $payg
        }
        else {
            $sp = Find-SpSourceFromConsumption $region $sku $Currency $ApiVersion
        }

        if ($sp -and $sp.savingsPlan) {

            foreach ($s in $sp.savingsPlan) {

                $unit = [decimal]$s.unitPrice

                if ($s.term -match "1 Year") {
                    $out.SP_Monthly_1Yr = [math]::Round(($unit*730),4)
                    $out.SP_1Yr_Upfront     = [math]::Round(($unit*8760),4)
                }
                elseif ($s.term -match "3 Years") {
                    $out.SP_Monthly_3Yr = [math]::Round(($unit*730),4)
                    $out.SP_3Yr_Upfront = [math]::Round(($unit*26280),4)
                }
            }
        }
    }
    catch {
        $out.Notes = "SP error: $($_.Exception.Message)"
    }
    #Reserved-Instance
    foreach ($term in @("1 Year","3 Years")) {

        try {
            $ri = Find-RiItem $region $sku $os $term $Currency $ApiVersion

            if ($ri) {
                $up = [decimal]$ri.unitPrice

                if ($term -eq "1 Year") {
                    $out.RI1Y_Monthly = [math]::Round(($up/12),6)
                    $out.RI1Y_Upfront = [math]::Round(($up),6)
                }
                else {
                    $out.RI3Y_Monthly = [math]::Round(($up/36),6)
                    $out.RI3Y_Upfront = [math]::Round(($up),6)
                }
            }
        }
        catch {
            $out.Notes = "RI $term error: $($_.Exception.Message)"
        }
    }

    return [pscustomobject]$out
}



$Final = New-Object System.Collections.Generic.List[object]
$i = 0

foreach ($vm in $VMList) {

    $i++

    $region = Normalize-Region $vm.Region
    $sku    = Normalize-ArmSku $vm.VMSize
    $os     = Normalize-Os $vm.OperatingSystem

    $pricing = Resolve-VmPricing $region $sku $os

    $row = [ordered]@{}

    foreach ($p in $vm.PSObject.Properties) {
        $row[$p.Name] = $p.Value
    }

    foreach ($p in $pricing.PSObject.Properties) {
        $row[$p.Name] = $p.Value
    }

    $Final.Add([pscustomobject]$row)

    if ($i % 10 -eq 0) {
        Write-Host "Processed $i VMs..." -ForegroundColor Green
    }
}

#output

$OutPath = Join-Path $env:USERPROFILE "Downloads\\AzureVM-FinalPricing-$(Get-Date -Format 'yyyy-MM-dd_HHmmss').csv"

$Final | Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath $OutPath

Write-Host " FINAL CSV GENERATED SUCCESSFULLY" -ForegroundColor Green
Write-Host " Location: $OutPath" -ForegroundColor Yellow