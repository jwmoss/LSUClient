﻿function Test-MachineSatisfiesDependency {
    [CmdletBinding()]
    [OutputType('System.Int32')]
    Param (
        [ValidateNotNullOrEmpty()]
        [System.Xml.XmlElement]$Dependency,
        [int]$DebugIndent = 0
    )

    #  0 SUCCESS, Dependency is met
    # -1 FAILRE, Dependency is not met
    # -2 Unknown dependency kind - status uncertain

    switch ($Dependency.SchemaInfo.Name) {
        '_Bios' {
            Write-Debug "$('- ' * $DebugIndent)[ Got: $($CachedHardwareTable['_Bios']) ]"
            foreach ($entry in $Dependency.Level) {
                if ($CachedHardwareTable['_Bios'] -like "$entry*") {
                    return 0
                }
            }
            return -1
        }
        '_CPUAddressWidth' {
            Write-Debug "$('- ' * $DebugIndent)[ Got: $($CachedHardwareTable['_CPUAddressWidth']), Expected: $($dependency.AddressWidth) ]"
            if ($CachedHardwareTable['_CPUAddressWidth'] -like "$($Dependency.AddressWidth)*") {
                return 0
            } else {
                return -1
            }
        }
        '_Driver' {
            [array]$SupportedDriverNodes = 'HardwareID', 'Version', 'Date', 'File'
            [array]$DriverChildNodes = $Dependency.ChildNodes.SchemaInfo.Name
            if (-not (Compare-Array $DriverChildNodes -in $SupportedDriverNodes)) {
                Write-Debug "$('- ' * $DebugIndent)_Driver node contained unknown element - skipping checks"
                return -2
            }

            if ($DriverChildNodes -contains 'HardwareID') {
                [bool]$HardwareFound = $false

                foreach ($HardwareInMachine in $CachedHardwareTable['_PnPID'].HardwareID) {
                    foreach ($HardwareID in $Dependency.HardwareID.'#cdata-section') {
                        # Lenovo HardwareIDs can contain wildcards (*) so we have to compare with "-like"
                        if ($HardwareInMachine -like "*$HardwareID*") {
                            Write-Debug "$('- ' * $DebugIndent)Matched device '$HardwareInMachine' with required '$HardwareID'"
                            $HardwareFound   = $true
                            $HardwareIDFound = $HardwareInMachine
                        }
                    }
                }

                if ($HardwareFound) {
                    [array]$DevicesWithHardwareID = $CachedHardwareTable['_PnPID'].Where{ $_.HardwareID -eq "$HardwareIDFound" }
                    if ($DevicesWithHardwareID.Count -ne 1) {
                        Write-Debug "$('- ' * $DebugIndent)$($DevicesWithHardwareID.Count) devices with HardwareID '$HardwareIDFound'"
                    }

                    $Device = $DevicesWithHardwareID[0]

                    # First, check if there is a driver installed for the device at all before proceeding (issue#24)
                    if ($Device.Problem -eq 'CM_PROB_FAILED_INSTALL') {
                        [string]$HexDeviceProblemStatus = '0x{0:X8}' -f ($Device | Get-PnpDeviceProperty -KeyName 'DEVPKEY_Device_ProblemStatus').Data
                        Write-Debug "$('- ' * $DebugIndent)Device '$HardwareIDFound' does not have any driver (ProblemStatus: $HexDeviceProblemStatus)"
                        return -1
                    }

                    $DriverVersion = ($Device | Get-PnpDeviceProperty -KeyName 'DEVPKEY_Device_DriverVersion').Data
                    $DriverDate    = ($Device | Get-PnpDeviceProperty -KeyName 'DEVPKEY_Device_DriverDate').Data.Date
                    $TestResults   = [System.Collections.Generic.List[bool]]::new()

                    # Documentation for this: https://docs.microsoft.com/en-us/windows-hardware/drivers/install/identifier-score--windows-vista-and-later-
                    # To be clear, this is a 'pretty good / best effort' approach, but it can detect false positives or miss generic drivers.
                    # AFAIK it is not possible to detect with 100% certainty that a driver is generic/inbox and even if - it's not always a problem.
                    # So this information should only be used for informaing the user or as an aid in making non-critical decisions,
                    # do not rely on this detection/boolean to be accurate!
                    [byte]$DriverMatchTypeScore = (Get-PnpDeviceProperty -InputObject $Device -KeyName 'DEVPKEY_Device_DriverRank').Data -shr 12 -band 0xF
                    if ($DriverMatchTypeScore -ge 2) {
                        Write-Verbose "Device '$($Device.Name)' may currently be using a generic or inbox driver"
                    }

                    if ($DriverChildNodes -contains 'Date') {
                        Write-Debug "$('- ' * $DebugIndent)Trying to match driver based on Date"
                        $LenovoDate = [DateTime]::new(0)
                        if ( [DateTime]::TryParseExact($Dependency.Date, 'yyyy-MM-dd', [CultureInfo]::InvariantCulture, 'None', [ref]$LenovoDate) ) {
                            Write-Debug "$('- ' * $DebugIndent)[Got: $DriverDate, Expected: $LenovoDate]"
                            if ($DriverDate -ge $LenovoDate) {
                                Write-Debug "$('- ' * $DebugIndent)Passed DriverDate test"
                                $TestResults.Add($true)
                            } else {
                                Write-Debug "$('- ' * $DebugIndent)Failed DriverDate test"
                                $TestResults.Add($false)
                            }
                        } else {
                            Write-Verbose "Got unsupported date format from Lenovo: '$($Dependency.Date)' (expected yyyy-MM-dd)"
                        }
                    }

                    if ($DriverChildNodes -contains 'Version') {
                        Write-Debug "$('- ' * $DebugIndent)Trying to match driver based on Version"
                        # Not all drivers tell us their versions via the OS API. I think later I can try to parse the INIs as an alternative, but it would get tricky
                        if ($DriverVersion) {
                            Write-Debug "$('- ' * $DebugIndent)[Got: $DriverVersion, Expected: $($Dependency.Version)]"
                            if ((Compare-VersionStrings -LenovoString $Dependency.Version -SystemString $DriverVersion) -eq 0) {
                                $TestResults.Add($true)
                            } else {
                                $TestResults.Add($false)
                            }
                        } else {
                            Write-Verbose "Device '$HardwareIDFound' does not report its driver version"
                        }
                    }

                    # If all HardwareID-tests were successful, return SUCCESS
                    if (-not ($TestResults -contains $false)) {
                        return 0 #SUCCESS
                    }

                    # If one or more HardwareID-tests were completed but failed (e.g. Date) continue in case there are further tests like FileVersion
                } else {
                    Write-Debug "$('- ' * $DebugIndent)No installed device matched the driver check"
                }
            }

            if (Compare-Array @('File', 'Version') -in $DriverChildNodes) {
                # This may not be 100% yet as Lenovo sometimes uses some non-system environment variables in their file paths
                [string]$Path = Resolve-CmdVariable -String $Dependency.File -ExtraVariables @{'WINDOWS' = $env:SystemRoot}
                if (Test-Path -LiteralPath $Path -PathType Leaf) {
                    $filProductVersion = (Get-Item -LiteralPath $Path).VersionInfo.ProductVersion
                    $FileVersionCompare = Compare-VersionStrings -LenovoString $Dependency.Version -SystemString $filProductVersion
                    if ($FileVersionCompare -eq -2) {
                        Write-Debug "$('- ' * $DebugIndent)Got unsupported with ProductVersion, trying comparison with FileVersion"
                        $filFileVersion = (Get-Item -LiteralPath $Path).VersionInfo.FileVersion
                        return (Compare-VersionStrings -LenovoString $Dependency.Version -SystemString $filFileVersion)
                    } else {
                        return $FileVersionCompare
                    }
                } else {
                    Write-Debug "$('- ' * $DebugIndent)The file '$Path' was not found."
                    return -1
                }
            }

            # If we have not hit a success condition before the end, return with failure
            return -1
        }
        '_EmbeddedControllerVersion' {
            if ($CachedHardwareTable['_EmbeddedControllerVersion']) {
                if ($CachedHardwareTable['_EmbeddedControllerVersion'] -eq '255.255') {
                    Write-Warning "This computers EC firmware is not upgradable but is being used to evaluate a package"
                }
                return (Compare-VersionStrings -LenovoString $Dependency.Version -SystemString $CachedHardwareTable['_EmbeddedControllerVersion'])
            }
            return -1
        }
        '_ExternalDetection' {
            $externalDetection = Invoke-PackageCommand -Command $Dependency.'#text' -Path $env:TEMP
            Write-Debug "$('- ' * $DebugIndent)[ Got ExitCode: $($externalDetection.ExitCode), Expected: $($Dependency.rc) ]"
            if ($externalDetection -and $externalDetection.ExitCode -in ($Dependency.rc -split ',')) {
                return 0
            } else {
                return -1
            }
        }
        '_FileExists' {
            # This may not be 100% yet as Lenovo sometimes uses some non-system environment variables in their file paths
            [string]$Path = Resolve-CmdVariable -String $Dependency -ExtraVariables @{'WINDOWS' = $env:SystemRoot}
            return (Test-Path -LiteralPath $Path -PathType Leaf)
        }
        '_FileVersion' {
            # This may not be 100% yet as Lenovo sometimes uses some non-system environment variables in their file paths
            [string]$Path = Resolve-CmdVariable -String $Dependency.File -ExtraVariables @{'WINDOWS' = $env:SystemRoot}
            if (Test-Path -LiteralPath $Path -PathType Leaf) {
                $filProductVersion = (Get-Item -LiteralPath $Path).VersionInfo.ProductVersion
                $FileVersionCompare = Compare-VersionStrings -LenovoString $Dependency.Version -SystemString $filProductVersion
                if ($FileVersionCompare -eq -2) {
                    Write-Debug "$('- ' * $DebugIndent)Got unsupported with ProductVersion, trying comparison with FileVersion"
                    $filFileVersion = (Get-Item -LiteralPath $Path).VersionInfo.FileVersion
                    return (Compare-VersionStrings -LenovoString $Dependency.Version -SystemString $filFileVersion)
                } else {
                    return $FileVersionCompare
                }
            } else {
                Write-Debug "$('- ' * $DebugIndent)The file '$Path' was not found."
                return -1
            }
        }
        '_OS' {
            foreach ($entry in $Dependency.OS) {
                if ("$entry" -like "${CachedHardwareTable['_OS']}*") {
                    return 0
                }
            }
            return -1
        }
        '_OSLang' {
            if ($Dependency.Lang -eq [CultureInfo]::CurrentUICulture.ThreeLetterWindowsLanguageName) {
                return 0
            } else {
                return -1
            }
        }
        '_PnPID' {
            foreach ($HardwareID in $CachedHardwareTable['_PnPID'].HardwareID) {
                if ($HardwareID -like "*$($Dependency.'#cdata-section')*") {
                    return 0
                }
            }
            return -1
        }
        '_RegistryKey' {
            if ($Dependency.Key) {
                if (Test-Path -LiteralPath ('Microsoft.PowerShell.Core\Registry::{0}' -f $Dependency.Key) -PathType Container) {
                    return 0
                }
            }
            return -1
        }
        '_RegistryKeyValue' {
            if ($Dependency.type -ne 'REG_SZ') {
                return -2
            }

            if (Test-Path -LiteralPath ('Microsoft.PowerShell.Core\Registry::{0}' -f $Dependency.Key) -PathType Container) {
                try {
                    $regVersion = Get-ItemPropertyValue -LiteralPath ('Microsoft.PowerShell.Core\Registry::{0}' -f $Dependency.Key) -Name $Dependency.KeyName -ErrorAction Stop
                }
                catch {
                    return -1
                }

                [string]$DependencyVersion = if ($Dependency.KeyValue) {
                    $Dependency.KeyValue
                } elseif ($Dependency.Version) {
                    $Dependency.Version
                } else {
                    Write-Verbose "Could not get LenovoString from _RegistryKeyValue dependency node"
                    return -2
                }

                return (Compare-VersionStrings -LenovoString $DependencyVersion -SystemString $regVersion)
            } else {
                return -1
            }

        }
        default {
            Write-Verbose "Unsupported dependency encountered: $_"
            return -2
        }
    }

    return -2
}
