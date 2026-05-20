$url = "https://storage.googleapis.com/jc_software_install/S1/SentinelOneInstaller_windows_64bit_v25_2_6_442.exe"
$dest   = "C:\Windows\Temp\SentinelOneInstaller_windows_64bit_v25_2_6_442.exe"
Write-host "Downloading SentialOne"
Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
