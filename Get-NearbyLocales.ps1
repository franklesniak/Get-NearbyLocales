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

$versionThisFunction = [version]('1.1.20230715.0')

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

    $url = 'http://api.geonames.org/findNearbyPlaceNameJSON'
    $response = Invoke-WebRequest -Uri ($url + '?lat=' + $lat + '&lng=' + $lng + '&radius=' + $radius + '&style=FULL&maxRows=500&username=' + $username)
    $json = ConvertFrom-Json $response.Content

    return $json.geonames
}

$speed = 100 # km/h
$maxDrivingTimeInHours = $MaxDrivingTime / 60
$radius = $maxDrivingTimeInHours * $speed

# Get the coordinates of each place of interest
$listPlacesOfInterestWithCoordinates = New-Object -TypeName 'System.Collections.Generic.List[PSCustomObject]'
$intCounterMax = $Places.Count
for ($intCounter = 0; $intCounter -lt $intCounterMax; $intCounter++) {
    $pscustomobjectCoordinates = Get-Coordinates -place $Places[$intCounter] -apiKey $GoogleMapsApiKey
    $pscustomobjectPlaceOfInterestWithCoordinates = New-Object -TypeName 'PSCustomObject'
    $pscustomobjectPlaceOfInterestWithCoordinates | Add-Member -MemberType NoteProperty -Name 'place' -Value $Places[$intCounter]
    $pscustomobjectPlaceOfInterestWithCoordinates | Add-Member -MemberType NoteProperty -Name 'lat' -Value $pscustomobjectCoordinates.lat
    $pscustomobjectPlaceOfInterestWithCoordinates | Add-Member -MemberType NoteProperty -Name 'lng' -Value $pscustomobjectCoordinates.lng
    $listPlacesOfInterestWithCoordinates.Add($pscustomobjectPlaceOfInterestWithCoordinates)
}

# Get the list of locales within the radius of each place of interest
$listAllLocales = New-Object -TypeName 'System.Collections.Generic.List[PSCustomObject]'
$intCounterMax = $listPlacesOfInterestWithCoordinates.Count
for ($intCounter = 0; $intCounter -lt $intCounterMax; $intCounter++) {
    $arrLocales = @(Get-NearbyLocales -lat ($listPlacesOfInterestWithCoordinates[$intCounter]).lat -lng ($listPlacesOfInterestWithCoordinates[$intCounter]).lng -radius $radius -username $GeonamesUsername)

    # Flatten results
    $intCounterBMax = $arrLocales.Count
    for ($intCounterB = 0; $intCounterB -lt $intCounterBMax; $intCounterB++) {
        # Flatten the adminCodes1 property
        ($arrLocales[$intCounterB]).adminCodes1 = ($arrLocales[$intCounterB]).adminCodes1.'ISO3166_2'

        # Flatten the alternateNames property
        $strLink = ''
        if ($null -ne ($arrLocales[$intCounterB]).alternateNames) {
            ($arrLocales[$intCounterB]).alternateNames = (@(($arrLocales[$intCounterB]).alternateNames) |
                    ForEach-Object {
                        if ($_.lang -eq 'link') {
                            $strLink = $_.name
                        }
                        $_.lang + '=' + $_.name
                    }) -join '; '
        }
        $arrLocales[$intCounterB] | Add-Member -MemberType NoteProperty -Name 'link' -Value $strLink

        # Flatten the timezone property
        $intGMTOffset = 0
        $intDSTOffset = 0
        if ($null -ne ($arrLocales[$intCounterB]).timezone.gmtOffset) {
            $intGMTOffset = ($arrLocales[$intCounterB]).timezone.gmtOffset
        }
        if ($null -ne ($arrLocales[$intCounterB]).timezone.dstOffset) {
            $intDSTOffset = ($arrLocales[$intCounterB]).timezone.dstOffset
        }
        ($arrLocales[$intCounterB]).timezone = ($arrLocales[$intCounterB]).timezone.timeZoneId
        $arrLocales[$intCounterB] | Add-Member -MemberType NoteProperty -Name 'gmtOffset' -Value $intGMTOffset
        $arrLocales[$intCounterB] | Add-Member -MemberType NoteProperty -Name 'dstOffset' -Value $intDSTOffset

        # Add the locale to the list
        $listAllLocales.Add($arrLocales[$intCounterB])
    }
}

# De-dupe the list of locales
$listUniqueLocales = New-Object -TypeName 'System.Collections.Generic.List[PSCustomObject]'
$listAllLocales | Group-Object toponymName | ForEach-Object {
    $listUniqueLocales.Add($_.Group[0])
}

# Get the list of locales within the max driving time of each place of interest
$listLocalesWithinDrivingTime = New-Object -TypeName 'System.Collections.Generic.List[PSCustomObject]'
$intCounterMax = $listUniqueLocales.Count
$intCounterBMax = $listPlacesOfInterestWithCoordinates.Count

#region Collect Stats/Objects Needed for Writing Progress ##########################
$intProgressReportingFrequency = 10
$intTotalItems = $intCounterMax + $intCounterBMax
$strProgressActivity = 'Getting nearby locales'
$strProgressStatus = 'Determining driving distance and time'
$strProgressCurrentOperationPrefix = 'Processing locale combination'
$timedateStartOfLoop = Get-Date
# Create a queue for storing lagging timestamps for ETA calculation
$queueLaggingTimestamps = New-Object System.Collections.Queue
$queueLaggingTimestamps.Enqueue($timedateStartOfLoop)
#endregion Collect Stats/Objects Needed for Writing Progress ##########################

for ($intCounter = 0; $intCounter -lt $intCounterMax; $intCounter++) {
    $boolWithinMaxDrivingTime = $false
    $listDrivingTimes = New-Object -TypeName 'System.Collections.Generic.List[double]'
    $listDistances = New-Object -TypeName 'System.Collections.Generic.List[double]'
    for ($intCounterB = 0; $intCounterB -lt $intCounterBMax; $intCounterB++) {
        #region Report Progress ########################################################
        $intCurrentItemNumber = $intCounter + $intCounterB + 1 # Forward direction for loop
        if ((($intCurrentItemNumber -ge 40) -and ($intCurrentItemNumber % $intProgressReportingFrequency -eq 0)) -or ($intCurrentItemNumber -eq $intTotalItems)) {
            # Create a progress bar after the first 40 items have been processed
            $timeDateLagging = $queueLaggingTimestamps.Dequeue()
            $datetimeNow = Get-Date
            $timespanTimeDelta = $datetimeNow - $timeDateLagging
            $intNumberOfItemsProcessedInTimespan = $intProgressReportingFrequency * ($queueLaggingTimestamps.Count + 1)
            $doublePercentageComplete = ($intCurrentItemNumber - 1) / $intTotalItems
            $intItemsRemaining = $intTotalItems - $intCurrentItemNumber + 1
            Write-Progress -Activity $strProgressActivity -Status $strProgressStatus -PercentComplete ($doublePercentageComplete * 100) -CurrentOperation ($strProgressCurrentOperationPrefix + ' ' + $intCurrentItemNumber + ' of ' + $intTotalItems + ' (' + [string]::Format('{0:0.00}', ($doublePercentageComplete * 100)) + '%)') -SecondsRemaining (($timespanTimeDelta.TotalSeconds / $intNumberOfItemsProcessedInTimespan) * $intItemsRemaining)
        }
        #endregion Report Progress ########################################################

        $origin = [string]($listPlacesOfInterestWithCoordinates[$intCounterB]).lat + ',' + [string]($listPlacesOfInterestWithCoordinates[$intCounterB]).lng
        $destination = [string]($listUniqueLocales[$intCounter]).lat + ',' + [string]($listUniqueLocales[$intCounter]).lng

        $url = 'https://maps.googleapis.com/maps/api/distancematrix/json'
        $response = Invoke-WebRequest -Uri ($url + '?origins=' + $origin + '&destinations=' + $destination + '&key=' + $GoogleMapsApiKey)
        $json = ConvertFrom-Json $response.Content

        $intDurationInSeconds = 0
        if ($json.rows -and $json.rows[0].elements -and $json.rows[0].elements[0].duration) {
            # Assuming the duration is returned in seconds
            $intDurationInSeconds = $json.rows[0].elements[0].duration.value
        } else {
            Write-Warning ('Error fetching driving duration from Google API from origin ' + $origin + ' to destination ' + $destination)
            $intDurationInSeconds = -1
        }

        $intDistanceInMeters = 0
        if ($json.rows -and $json.rows[0].elements -and $json.rows[0].elements[0].distance) {
            # Assuming the distance is returned in meters
            $intDistanceInMeters = $json.rows[0].elements[0].distance.value
        } else {
            Write-Warning ('Error fetching driving distance from Google API from origin ' + $origin + ' to destination ' + $destination)
            $intDistanceInMeters = -1
        }

        $doubleDurationInMinutes = $intDurationInSeconds / 60
        $doubleDrivingDistanceInKM = $intDistanceInMeters / 1000

        if ($origin -eq $destination) {
            $listDrivingTimes.Add($doubleDurationInMinutes)
            $listDistances.Add($doubleDrivingDistanceInKM)
            $boolWithinMaxDrivingTime = $true
        } else {
            if ($doubleDurationInMinutes -ge 0) {
                $listDrivingTimes.Add($doubleDurationInMinutes)
                if ($doubleDurationInMinutes -le $MaxDrivingTime) {
                    $boolWithinMaxDrivingTime = $true
                }
            }
            if ($doubleDrivingDistanceInKM -ge 0) {
                $listDistances.Add($doubleDrivingDistanceInKM)
            }
        }

        if ($intCurrentItemNumber -eq $intTotalItems) {
            Write-Progress -Activity $strProgressActivity -Status $strProgressStatus -PercentComplete 100
        }
        if ($intCounterLoop % $intProgressReportingFrequency -eq 0) {
            # Add lagging timestamp to queue
            $queueLaggingTimestamps.Enqueue((Get-Date))
        }
    }

    if ($boolWithinMaxDrivingTime) {
        $doubleMinDrivingTime = $listDrivingTimes | Measure-Object -Minimum | Select-Object -ExpandProperty Minimum
        $doubleMaxDrivingTime = $listDrivingTimes | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum
        $doubleAvgDrivingTime = $listDrivingTimes | Measure-Object -Average | Select-Object -ExpandProperty Average
        $doubleMinDistance = $listDistances | Measure-Object -Minimum | Select-Object -ExpandProperty Minimum
        $doubleMaxDistance = $listDistances | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum
        $doubleAvgDistance = $listDistances | Measure-Object -Average | Select-Object -ExpandProperty Average
        ($listUniqueLocales[$intCounter]).distance = $doubleAvgDistance
        ($listUniqueLocales[$intCounter]) | Add-Member -MemberType 'NoteProperty' -Name 'minDrivingTimeInMinutes' -Value $doubleMinDrivingTime
        ($listUniqueLocales[$intCounter]) | Add-Member -MemberType 'NoteProperty' -Name 'maxDrivingTimeInMinutes' -Value $doubleMaxDrivingTime
        ($listUniqueLocales[$intCounter]) | Add-Member -MemberType 'NoteProperty' -Name 'avgDrivingTimeInMinutes' -Value $doubleAvgDrivingTime
        ($listUniqueLocales[$intCounter]) | Add-Member -MemberType 'NoteProperty' -Name 'minDrivingDistanceInKM' -Value $doubleMinDistance
        ($listUniqueLocales[$intCounter]) | Add-Member -MemberType 'NoteProperty' -Name 'maxDrivingDistanceInKM' -Value $doubleMaxDistance
        ($listUniqueLocales[$intCounter]) | Add-Member -MemberType 'NoteProperty' -Name 'avgDrivingDistanceInKM' -Value $doubleAvgDistance
        $listLocalesWithinDrivingTime.Add($listUniqueLocales[$intCounter])
    }
}

# Output to CSV
$listLocalesWithinDrivingTime | Sort-Object @{ Expression = { [double]::Parse($_.minDrivingTimeInMinutes) }; Ascending=$true } | Export-Csv -Path $OutputFile -NoTypeInformation

# Recommended filter:
# fcodeName != section of populated place
# -and-
# fcodeName != abandoned populated place
# -and-
# (
#   population != 0
#   -or
#   link != ''
# )
