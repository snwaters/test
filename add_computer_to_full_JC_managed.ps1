# Requires the JumpCloud PowerShell Module: 
Install-Module -Name JumpCloud -Force
#Install-Module Microsoft.Graph.DeviceManagement

# 1. Connect to JumpCloud API
# Replace '<YOUR_API_KEY>' with your actual JumpCloud Admin API Key
$JCAPIKEY = 'jca_8LVjaQ6Wem5Zk7ody6zn41zsfxT6rZSjF8nA'
Connect-JCOnline $JCAPIKEY

$deviceName = "c22503"
$device = Get-JCSystem | Where-Object { $_.hostName -eq $deviceName }
$deviceID = $device.Id
Write-Host "The Device ID is: $deviceID"
Add-JCSystemGroupMember -GroupName "Full JC Managed" -SystemID $deviceId