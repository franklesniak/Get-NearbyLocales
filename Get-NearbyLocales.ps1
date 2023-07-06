param (
    [string[]]$Places = @('River Forest, IL'),
    [string]$GoogleMapsApiKey = $env:GOOGLE_MAPS_API_KEY,
    [string]$GeonamesUsername = $env:GEONAMES_USERNAME,
    [double]$MaxDrivingTime = 30,
    [string]$OutputFile = 'output.csv'
)

#region License ####################################################################
# Copyright (c) 2023 Frank Lesniak
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this
# software and associated documentation files (the "Software"), to deal in the Software
# without restriction, including without limitation the rights to use, copy, modify,
# merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to the following
# conditions:
#
# The above copyright notice and this permission notice shall be included in all copies
# or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
# PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
# CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
# OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#endregion License ####################################################################

$versionThisFunction = [version]('1.0.20230705.0')

function Get-Coordinates {
    param (
        [string]$place,
        [string]$apiKey
    )

    $url = 'https://maps.googleapis.com/maps/api/geocode/json'
    $response = Invoke-WebRequest -Uri ($url + '?address=' + $place + '&key=' + $apiKey)
    $json = ConvertFrom-Json $response.Content

    return $json.results[0].geometry.location
}

function Get-NearbyLocales {
    param (
        [float]$lat,
        [float]$lng,
        [float]$radius,
        [string]$username
    )

    $url = 'http://api.geonames.org/findNearbyPlaceName'
    $response = Invoke-WebRequest -Uri ($url + '?lat=' + $lat + '&lng=' + $lng + '&radius=' + $radius + '&style=FULL&maxRows=500&username=' + $username)

    $locales = @(([xml]($response.Content)).geonames.geoname | Where-Object { $_.fcodeName -ne 'section of populated place' } | Where-Object { $_.fcodename -ne 'abandoned populated place' } | Where-Object { $_.population -ne '' })

    return $locales
}

$allLocales = @()

$speed = 100 # km/h
$maxDrivingTimeInHours = $MaxDrivingTime / 60
$radius = $maxDrivingTimeInHours * $speed

foreach ($place in $Places) {
    $coordinates = Get-Coordinates -place $place -apiKey $GoogleMapsApiKey
    $locales = Get-NearbyLocales -lat $coordinates.lat -lng $coordinates.lng -radius $radius -username $GeonamesUsername
    $allLocales += $locales
}

$uniqueLocales = $allLocales | Group-Object toponymName | ForEach-Object {$_.Group[0]}

$finalLocales = @()

foreach ($locale in $uniqueLocales) {
    $isWithinMaxDrivingTime = $false
    foreach ($place in $Places) {
        $coordinates = Get-Coordinates -place $place -apiKey $GoogleMapsApiKey
        $origin = [string]$coordinates.lat + ',' + [string]$coordinates.lng
        $destination = [string]$locale.lat + ',' + [string]$locale.lng

        $url = 'https://maps.googleapis.com/maps/api/distancematrix/json'
        $response = Invoke-WebRequest -Uri ($url + '?origins=' + $origin + '&destinations=' + $destination + '&key=' + $GoogleMapsApiKey)
        $json = ConvertFrom-Json $response.Content

        if ($json.rows -and $json.rows[0].elements -and $json.rows[0].elements[0].duration) {
            # Assuming the duration is returned in seconds
            $durationInMinutes = $json.rows[0].elements[0].duration.value / 60
            if ($durationInMinutes -le $MaxDrivingTime) {
                $isWithinMaxDrivingTime = $true
                break
            }
        } else {
            Write-Host "Error fetching duration from Google API for destination $destination"
        }
    }

    if ($isWithinMaxDrivingTime) {
        $finalLocales += $locale
    }
}

foreach ($locale in $uniqueLocales) {
    $locale.distance = [double]$locale.distance
}

# Output to CSV
$finalLocales | Sort-Object @{ Expression={ [double]::Parse($_.Distance) }; Ascending=$true } | Export-Csv -Path $OutputFile -NoTypeInformation
