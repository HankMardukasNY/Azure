
<#PSScriptInfo

.VERSION 1.4

.AUTHOR HankMardukasNY

.TAGS UpdateManagement, Automation 

.EXTERNALMODULEDEPENDENCIES ThreadJob

.RELEASENOTES
Updated to use system assigned identity and Az modules

.PRIVATEDATA 

#>

<#
.SYNOPSIS
 Start VMs as part of an Update Management deployment

.DESCRIPTION
 This script is intended to be run as a part of Update Management Pre/Post scripts.
 It requires a system assigned identity.
 This script will ensure all Azure VMs in the Update Deployment are running so they recieve updates.
 This script works with the Turn Off VMs script. It will store the names of machines that were started in an Automation variable so only those machines are turned back off when the deployment is finished.

.PARAMETER SoftwareUpdateConfigurationRunContext
  This is a system variable which is automatically passed in by Update Management during a deployment.

.MINIMUM PERMISSIONS
 Microsoft.Automation/automationAccounts/variables/write
 Microsoft.Automation/automationAccounts/read
 Microsoft.Automation/automationAccounts/modules/read
 Microsoft.Resources/subscriptions/resourceGroups/read
 Microsoft.Automation/automationAccounts/variables/read
 Microsoft.Automation/automationAccounts/variables/delete
 Microsoft.Compute/virtualMachines/deallocate/action
 Microsoft.Compute/virtualMachines/read
 Microsoft.Compute/virtualMachines/restart/action
 Microsoft.Compute/virtualMachines/start/action
 Microsoft.Automation/automationAccounts/softwareUpdateConfigurations/read
 Microsoft.Automation/automationAccounts/softwareUpdateConfigurationMachineRuns/read
 Microsoft.Automation/automationAccounts/softwareUpdateConfigurationRuns/read
 Microsoft.Automation/automationAccounts/jobs/read

#>

param(
    [string]$SoftwareUpdateConfigurationRunContext
)


#region BoilerplateAuthentication
# Ensures you do not inherit an AzContext in your runbook
Disable-AzContextAutosave -Scope Process

# Connect to Azure with system-assigned managed identity
$AzureContext = (Connect-AzAccount -Identity).context

# set and store context
$AzureContext = Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext
#endregion BoilerplateAuthentication

#If you wish to use the run context, it must be converted from JSON
$context = ConvertFrom-Json $SoftwareUpdateConfigurationRunContext
#Access the properties of the SoftwareUpdateConfigurationRunContext
$vmIds = $context.SoftwareUpdateConfigurationSettings.AzureVirtualMachines | Sort-Object -Unique
$runId = $context.SoftwareUpdateConfigurationRunId

if (!$vmIds) 
{
    #Workaround: Had to change JSON formatting
    $Settings = ConvertFrom-Json $context.SoftwareUpdateConfigurationSettings
    Write-Output "List of settings: $Settings"
    $VmIds = $Settings.AzureVirtualMachines
    Write-Output "Azure VMs: $VmIds"
    if (!$vmIds) 
    {
        Write-Output "No Azure VMs found"
        return
    }
}

#https://github.com/azureautomation/runbooks/blob/master/Utility/ARM/Find-WhoAmI
# In order to prevent asking for an Automation Account name and the resource group of that AA,
# search through all the automation accounts in the subscription 
# to find the one with a job which matches our job ID
$AutomationResource = Get-AzResource -ResourceType Microsoft.Automation/AutomationAccounts

foreach ($Automation in $AutomationResource)
{
    $Job = Get-AzAutomationJob -ResourceGroupName $Automation.ResourceGroupName -AutomationAccountName $Automation.Name -Id $PSPrivateMetadata.JobId.Guid -ErrorAction SilentlyContinue
    if (!([string]::IsNullOrEmpty($Job)))
    {
        $ResourceGroup = $Job.ResourceGroupName
        $AutomationAccount = $Job.AutomationAccountName
        break;
    }
}

#This is used to store the state of VMs
New-AzAutomationVariable -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccount -Name $runId -Value "" -Encrypted $false

$updatedMachines = @()
$startableStates = "stopped" , "stopping", "deallocated", "deallocating"
$jobIDs= New-Object System.Collections.Generic.List[System.Object]

#Parse the list of VMs and start those which are stopped
#Azure VMs are expressed by:
# subscription/$subscriptionID/resourcegroups/$resourceGroup/providers/microsoft.compute/virtualmachines/$name
$vmIds | ForEach-Object {
    $vmId =  $_
    
    $split = $vmId -split "/";
    $subscriptionId = $split[2]; 
    $rg = $split[4];
    $name = $split[8];
    Write-Output ("Subscription Id: " + $subscriptionId)
    $mute = Select-AzSubscription -Subscription $subscriptionId

    $vm = Get-AzVM -ResourceGroupName $rg -Name $name -Status -DefaultProfile $mute 

    #Query the state of the VM to see if it's already running or if it's already started
    $state = ($vm.Statuses[1].DisplayStatus -split " ")[1]
    if($state -in $startableStates) {
        Write-Output "Starting '$($name)' ..."
        #Store the VM we started so we remember to shut it down later
        $updatedMachines += $vmId
        $newJob = Start-ThreadJob -ScriptBlock { param($resource, $vmname, $sub) $context = Select-AzSubscription -Subscription $sub; Start-AzVM -ResourceGroupName $resource -Name $vmname -DefaultProfile $context} -ArgumentList $rg,$name,$subscriptionId
        $jobIDs.Add($newJob.Id)
    }else {
        Write-Output ($name + ": no action taken. State: " + $state) 
    }
}

$updatedMachinesCommaSeperated = $updatedMachines -join ","
#Wait until all machines have finished starting before proceeding to the Update Deployment
$jobsList = $jobIDs.ToArray()
if ($jobsList)
{
    Write-Output "Waiting for machines to finish starting..."
    Wait-Job -Id $jobsList
    #Wait 5 minutes for hybrid worker to start
    Start-Sleep -Seconds 300
}

foreach($id in $jobsList)
{
    $job = Get-Job -Id $id
    if ($job.Error)
    {
        Write-Output $job.Error
    }

}

Write-output $updatedMachinesCommaSeperated
#Store output in the automation variable
Set-AutomationVariable -Name $runId -Value $updatedMachinesCommaSeperated