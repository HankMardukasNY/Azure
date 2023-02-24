
<#PSScriptInfo

.VERSION 1.2

.AUTHOR HankMardukasNY

.TAGS UpdateManagement, Automation 

.EXTERNALMODULEDEPENDENCIES ThreadJob

.RELEASENOTES
Updated to use system assigned identity and Az modules

.PRIVATEDATA 

#>

<#
.SYNOPSIS
 Stop VMs that were started as part of an Update Management deployment

.DESCRIPTION
 This script is intended to be run as a part of Update Management Pre/Post scripts.
 It requires a system assigned identity and the usage of the Turn On VMs script as a pre-deployment script.
 This script will ensure all Azure VMs in the Update Deployment are turned off after they recieve updates.
 This script reads the name of machines that were started by Update Management via the Turn On VMs script
 Requires the ThreadJob module

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
#This uses a system managed identity
# Ensures you do not inherit an AzContext in your runbook
Disable-AzContextAutosave -Scope Process

# Connect to Azure with system-assigned managed identity
$AzureContext = (Connect-AzAccount -Identity).context

# Set and store context
$AzureContext = Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext
#endregion BoilerplateAuthentication

#If you wish to use the run context, it must be converted from JSON
$context = ConvertFrom-Json $SoftwareUpdateConfigurationRunContext
$runId = "PrescriptContext" + $context.SoftwareUpdateConfigurationRunId

#Retrieve the automation variable, which we named using the runID from our run context. 
#See: https://docs.microsoft.com/en-us/azure/automation/automation-variables#activities
$variable = Get-AutomationVariable -Name $runId
if (!$variable) 
{
    Write-Output "No machines to turn off"
    return
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

$vmIds = $variable -split ","
$stoppableStates = "starting", "running"
$jobIDs= New-Object System.Collections.Generic.List[System.Object]

#This script can run across subscriptions, so we need unique identifiers for each VMs
#Azure VMs are expressed by:

$vmIds | ForEach-Object {
    $vmId =  $_
    
    $split = $vmId -split "/";
    $subscriptionId = $split[2]; 
    $rg = $split[4];
    $name = $split[8];
    Write-Output ("Subscription Id: " + $subscriptionId)
    $mute = Select-AzSubscription -Subscription $subscriptionId

    $vm = Get-AzVM -ResourceGroupName $rg -Name $name -Status -DefaultProfile $mute

    $state = ($vm.Statuses[1].DisplayStatus -split " ")[1]
    if($state -in $stoppableStates) {
        Write-Output "Stopping '$($name)' ..."
        $newJob = Start-ThreadJob -ScriptBlock { param($resource, $vmname, $sub) $context = Select-AzSubscription -Subscription $sub; Stop-AzVM -ResourceGroupName $resource -Name $vmname -Force -DefaultProfile $context} -ArgumentList $rg,$name,$subscriptionId
        $jobIDs.Add($newJob.Id)
    }else {
        Write-Output ($name + ": already stopped. State: " + $state) 
    }
}
#Wait for all machines to finish stopping so we can include the results as part of the Update Deployment
$jobsList = $jobIDs.ToArray()
if ($jobsList)
{
    Write-Output "Waiting for machines to finish stopping..."
    Wait-Job -Id $jobsList
}

foreach($id in $jobsList)
{
    $job = Get-Job -Id $id
    if ($job.Error)
    {
        Write-Output $job.Error
    }
}
#Clean up our variables:
Remove-AzAutomationVariable -AutomationAccountName $AutomationAccount -ResourceGroupName $ResourceGroup -name $runID
