Update Management - Turn On/Off VMs
===============================

These scripts are intended to be run as a part of Update Management Pre/Post scripts. They will ensure all Azure VMs in the Update Deployment are running so they recieve updates and then stop any that were orignally off.

It requires the ThreadJobs and Az modules from the PowerShell gallery.

It requires a system assigned identity.

They were modified from the original scripts from azureautomation to use a system assigned identity along with migrating from AzureRM to Az.

Originals:

https://github.com/azureautomation/update-management-turn-on-vms

https://github.com/azureautomation/update-management-turn-off-vms
