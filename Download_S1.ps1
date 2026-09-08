$url = "https://storage.googleapis.com/jc_software_install/S1/SentinelOneInstaller.exe"
$dest   = "C:\Windows\Temp\SentinelOneInstaller.exe"
Write-host "Downloading SentialOne"
Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
